import Foundation
import os

/// Receives, deduplicates, and routes Android phone events into the
/// proactivity + conversation-context layers.
///
/// Wired by `JarvisController` immediately after the WebSocket bridge is
/// started. `AndroidBridgeManager` forwards decoded `AndroidPhoneEvent`
/// values here; this class handles all the business logic:
///
///  - **Deduplication** by `eventId` (cross-session, persisted to JSON).
///  - **Context continuity** — tracks latest caller/sender so follow-up
///    intents like "call him back" resolve without re-prompting the user.
///  - **ProactivitySignal** construction and ingestion.
///  - **Permission warnings** surfaced to the overlay.
///  - **Event history** for the Android overlay view.
@MainActor
final class AndroidEventReceiver {

    // MARK: - Wired by JarvisController

    weak var proactivity: ProactivityEngine?
    weak var context: ContextEngine?
    weak var state: AppState?

    // MARK: - Context continuity (for follow-up intents)

    /// Name of the most recent incoming/active caller.
    private(set) var latestCallerName: String? = nil
    /// Name of the most recently missed caller (for "call him back").
    private(set) var latestMissedCallerName: String? = nil
    /// Sender of the most recent SMS.
    private(set) var latestSMSSender: String? = nil
    /// Sender of the most recent WhatsApp message.
    private(set) var latestWhatsAppSender: String? = nil
    /// The app that sent the most recent notification.
    private(set) var latestNotificationApp: String? = nil
    /// The message body from the most recent SMS or WhatsApp.
    private(set) var latestMessageBody: String? = nil

    // MARK: - Recent event history (for the overlay)

    private(set) var recentEvents: [AndroidEventRecord] = []

    // MARK: - Pending permissions (for overlay + proactivity)

    private(set) var pendingPermissions: [(name: String, description: String)] = []

    // MARK: - Behaviour settings (synced from PreferencesStore by JarvisController)

    var speakCallerNames: Bool         = true
    var speakMessageSenders: Bool      = true
    var showMessagePreviews: Bool      = true
    var autoOpenOverlay: Bool          = true

    // MARK: - Dedupe state

    /// eventIds seen in this session or previous sessions (persisted).
    private var seenEventIds: Set<String> = []
    /// Body hashes — catches duplicate content from repeated WS delivers.
    private var seenBodyHashes: Set<String> = []

    // MARK: - Persistence

    private let historyURL: URL

    private struct PersistedHistory: Codable {
        var seenEventIds: [String]
        var recentEvents: [AndroidEventRecord]
    }

    // MARK: - Init

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("JarvisMac", isDirectory: true)
        historyURL = appSupport.appendingPathComponent("android-event-history.json")
        loadHistory()
    }

    // MARK: - Main entry point

    /// Called by `AndroidBridgeManager` for every inbound phone event frame.
    func receive(_ event: AndroidPhoneEvent) {
        // 1. Deduplicate by eventId
        guard !seenEventIds.contains(event.eventId) else {
            Log.android.debug("android-event dedupe: id=\(event.eventId, privacy: .public)")
            state?.androidEventDedupeSuppressed += 1
            return
        }
        // 2. Deduplicate by body hash (catches re-delivered WS frames)
        if let hash = event.bodyHash() {
            guard !seenBodyHashes.contains(hash) else {
                Log.android.debug("android-event dedupe: body-hash type=\(event.type.rawValue, privacy: .public)")
                state?.androidEventDedupeSuppressed += 1
                return
            }
            seenBodyHashes.insert(hash)
            if seenBodyHashes.count > 1000 { seenBodyHashes = Set(seenBodyHashes.prefix(800)) }
        }

        // 3. Mark seen
        seenEventIds.insert(event.eventId)
        if seenEventIds.count > 2000 { seenEventIds = Set(seenEventIds.prefix(1500)) }

        // 4. Persist to history
        let record = AndroidEventRecord(
            id: event.eventId,
            type: event.type,
            timestamp: event.timestamp,
            senderName: event.senderName,
            appName: event.appName,
            contentHash: event.bodyHash(),
            wasSpoken: false,
            wasOpened: false
        )
        recentEvents.insert(record, at: 0)
        if recentEvents.count > 50 { recentEvents = Array(recentEvents.prefix(50)) }
        saveHistory()

        // 5. Update AppState summary fields
        state?.androidEventCount = (state?.androidEventCount ?? 0) + 1
        state?.lastAndroidEventType = event.type.rawValue
        state?.lastAndroidTimestamp = event.timestamp

        // 6. Update conversation context
        updateContext(from: event)
        recordActiveContext(from: event)

        // 7. Handle special cases
        if event.type == .permissionRequired {
            let name = event.permissionName ?? "unknown"
            let desc = event.permissionDescription ?? name
            if !pendingPermissions.contains(where: { $0.name == name }) {
                pendingPermissions.append((name: name, description: desc))
            }
            state?.androidPermissionWarnings = pendingPermissions.map { $0.description }
        }

        if event.type == .batteryStatus, let level = event.batteryLevel {
            state?.androidBridgeBattery = level
        }

        // 8. Build and ingest ProactivitySignal
        if let signal = buildSignal(from: event) {
            guard let appState = state, let engine = proactivity else { return }
            engine.ingest(signal, appState: appState)
        }

        Log.android.info("""
            android-event type=\(event.type.rawValue, privacy: .public) \
            sender=\(event.senderName ?? "<nil>", privacy: .private) \
            app=\(event.appName ?? "<nil>", privacy: .public)
            """)
    }

    // MARK: - Daemon bridge entry point

    /// Called by the DaemonAppBridge `onAndroidEvent` callback when an
    /// `android.event` envelope arrives from the Android app via the daemon.
    ///
    /// `command` is the Android event type (e.g. "incoming_call").
    /// `data` is the JSON-serialised `data` sub-object from the envelope payload,
    /// which maps to the camelCase field layout that `AndroidPhoneEvent` accepts.
    ///
    /// We rebuild the event as the nested-payload wire format (format 2 of
    /// `AndroidBridge.routePhoneEvent`) so the existing decoder handles it:
    /// `{ "command": "<cmd>", "payload": { ...data fields... } }`
    func receiveRawData(command: String, data: Data, deviceId: String = "") {
        // Build a wrapper that matches the nested-native parsing path.
        guard var inner = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            Log.android.warning("androidEvent: could not parse event data for command=\(command, privacy: .public)")
            return
        }
        // Inject `type` if missing so the decoder maps to the right AndroidEventType case.
        if inner["type"] == nil { inner["type"] = command }
        if inner["event_type"] == nil { inner["event_type"] = command }
        // Synthesise a stable eventId from command + data hash to enable dedup.
        if inner["event_id"] == nil {
            let hashInput = command + (String(data: data, encoding: .utf8) ?? "")
            inner["event_id"] = "daemon:\(hashInput.hashValue)"
        }
        guard let reconstructed = try? JSONSerialization.data(withJSONObject: inner) else { return }
        if let event = try? JSONDecoder().decode(AndroidPhoneEvent.self, from: reconstructed),
           event.type != .unknown {
            receive(event)
        } else {
            Log.android.debug("androidEvent: no native decode for command=\(command, privacy: .public) — ignored")
        }
    }

    // MARK: - Context continuity update

    private func updateContext(from event: AndroidPhoneEvent) {
        switch event.type {

        case .incomingCall:
            let name = event.senderName ?? "Unknown caller"
            latestCallerName = event.senderName
            state?.latestCallerName = name
            state?.activeCallState = "ringing"
            state?.activeCallerName = name
            state?.activeCallContactId = event.contactId
            state?.activeCallStartTime = nil
            context?.recordAndroidEvent(event)

        case .callAnswered:
            let name = event.senderName ?? state?.activeCallerName ?? "Unknown caller"
            if let sn = event.senderName { latestCallerName = sn }
            state?.latestCallerName = name
            state?.activeCallState = "active"
            state?.activeCallerName = name
            if event.contactId != nil { state?.activeCallContactId = event.contactId }
            state?.activeCallStartTime = Date()
            context?.recordAndroidEvent(event)

        case .missedCall:
            let name = event.senderName ?? "Unknown caller"
            if let sn = event.senderName {
                latestMissedCallerName = sn
                latestCallerName = sn
                state?.latestMissedCallerName = sn
                state?.latestCallerName = sn
            }
            // Call is gone — clear active state
            state?.activeCallState = ""
            state?.activeCallStartTime = nil
            context?.recordAndroidEvent(event)

        case .callEnded:
            let name = event.senderName ?? state?.activeCallerName ?? ""
            if !name.isEmpty { state?.activeCallerName = name }
            state?.activeCallState = "ended"
            state?.activeCallStartTime = nil
            // Auto-clear "ended" state after 5 seconds
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                // Only clear if still "ended" (not replaced by a new incoming call)
                if self?.state?.activeCallState == "ended" {
                    self?.state?.activeCallState = ""
                    self?.state?.activeCallerName = ""
                    self?.state?.activeCallContactId = nil
                }
            }
            context?.recordAndroidEvent(event)

        case .smsReceived:
            if let name = event.senderName {
                latestSMSSender = name
                state?.latestSMSSender = name
            }
            latestMessageBody = event.messageBody
            context?.recordAndroidEvent(event)

        case .whatsAppReceived:
            if let name = event.senderName {
                latestWhatsAppSender = name
                state?.latestWhatsAppSender = name
            }
            latestMessageBody = event.messageBody
            context?.recordAndroidEvent(event)

        case .notificationReceived:
            latestNotificationApp = event.appName
            context?.recordAndroidEvent(event)

        default:
            break
        }
    }

    // MARK: - Signal construction

    private func buildSignal(from event: AndroidPhoneEvent) -> ProactivitySignal? {
        // Respect speak settings — anonymise if turned off
        let sender = speakCallerNames ? event.displaySender : "someone"
        let msgSender = speakMessageSenders ? event.displaySender : "someone"

        switch event.type {

        // ── Incoming call — critical, bypass quiet hours + cooldown ──────
        case .incomingCall:
            return ProactivitySignal(
                source: .android,
                title: "Incoming call from \(sender)",
                body: "",
                category: AndroidSignalCategory.incomingCall,
                priority: .critical,
                dedupeKey: "android.call.incoming.\(event.eventId)",
                suggestedAction: "open_phone_overlay",
                spokenText: "\(sender) is calling.",
                requiresAttention: true
            )

        // ── Missed call — high priority ──────────────────────────────────
        case .missedCall:
            return ProactivitySignal(
                source: .android,
                title: "Missed call from \(sender)",
                body: "",
                category: AndroidSignalCategory.missedCall,
                priority: .high,
                dedupeKey: "android.call.missed.\(event.eventId)",
                suggestedAction: "open_phone_overlay",
                spokenText: "You missed a call from \(sender).",
                requiresAttention: true
            )

        // ── SMS ──────────────────────────────────────────────────────────
        case .smsReceived:
            let spokenText: String
            if showMessagePreviews,
               event.messagePreviewEnabled,
               let body = event.messageBody, !body.isEmpty {
                let preview = String(body.prefix(80))
                spokenText = "Text from \(msgSender): \(preview)"
            } else {
                spokenText = "You've got a text from \(msgSender)."
            }
            return ProactivitySignal(
                source: .android,
                title: "SMS from \(msgSender)",
                body: event.messageBody ?? "",
                category: AndroidSignalCategory.sms,
                priority: .high,
                dedupeKey: "android.sms.\(event.eventId)",
                suggestedAction: "open_android_overlay",
                spokenText: spokenText
            )

        // ── WhatsApp ─────────────────────────────────────────────────────
        // Speech shapes (in order of preference):
        //   * group + named sender + preview ON
        //       → "WhatsApp in {group} from {sender}: {preview}"
        //   * group + named sender, preview OFF
        //       → "You've had a WhatsApp in {group} from {sender}."
        //   * direct + named sender + preview ON
        //       → "WhatsApp from {sender}: {preview}"
        //   * direct + named sender, preview OFF
        //       → "You've had a WhatsApp from {sender}."
        //   * no name resolved (Android side gave up)
        //       → "You've had a WhatsApp message."
        case .whatsAppReceived:
            let hasName  = event.senderName != nil
                && !(event.senderName?.isEmpty ?? true)
                && (event.senderName ?? "").lowercased() != "someone"
            let hasGroup = (event.groupName ?? "").isEmpty == false
            let hasPreview = showMessagePreviews
                && event.messagePreviewEnabled
                && !(event.messageBody ?? "").isEmpty
            let spokenText: String
            switch (hasName, hasGroup, hasPreview) {
            case (true,  true,  true):
                spokenText = "WhatsApp in \(event.groupName!) from \(msgSender): \(String(event.messageBody!.prefix(80)))"
            case (true,  true,  false):
                spokenText = "You've had a WhatsApp in \(event.groupName!) from \(msgSender)."
            case (true,  false, true):
                spokenText = "WhatsApp from \(msgSender): \(String(event.messageBody!.prefix(80)))"
            case (true,  false, false):
                spokenText = "You've had a WhatsApp from \(msgSender)."
            case (false, _,     _):
                // Final fallback — sender extraction genuinely failed on
                // the Android side.  Don't claim a fake "someone" name.
                spokenText = "You've had a WhatsApp message."
            }
            let titleText = hasName
                ? (hasGroup ? "WhatsApp in \(event.groupName!) — \(msgSender)"
                             : "WhatsApp from \(msgSender)")
                : "WhatsApp message"
            return ProactivitySignal(
                source: .android,
                title: titleText,
                body: event.messageBody ?? "",
                category: AndroidSignalCategory.whatsApp,
                priority: .high,
                dedupeKey: "android.whatsapp.\(event.eventId)",
                suggestedAction: "open_android_overlay",
                spokenText: spokenText
            )

        // ── App notification ─────────────────────────────────────────────
        case .notificationReceived:
            let app = event.appName ?? "an app"
            let titleText = event.notificationTitle ?? ""
            let spoken = titleText.isEmpty
                ? "New notification from \(app)."
                : "Notification from \(app): \(String(titleText.prefix(60)))"
            return ProactivitySignal(
                source: .android,
                title: "Notification: \(app)",
                body: titleText,
                category: AndroidSignalCategory.notification,
                priority: .normal,
                dedupeKey: "android.notification.\(event.eventId)",
                spokenText: spoken
            )

        // ── Low battery ──────────────────────────────────────────────────
        case .batteryStatus:
            guard let level = event.batteryLevel,
                  level <= 20,
                  event.isCharging != true else { return nil }
            // Dedupe per 10% band so it only fires once per band
            return ProactivitySignal(
                source: .android,
                title: "Phone battery \(level)%",
                body: "Low battery",
                category: AndroidSignalCategory.batteryLow,
                priority: .high,
                dedupeKey: "android.battery.low.\(level / 10)0pct",
                spokenText: "Phone battery is at \(level) percent."
            )

        // ── Permission needed ────────────────────────────────────────────
        case .permissionRequired:
            let desc = event.permissionDescription
                ?? event.permissionName
                ?? "a system permission"
            return ProactivitySignal(
                source: .android,
                title: "Android permission needed",
                body: desc,
                category: AndroidSignalCategory.permission,
                priority: .high,
                dedupeKey: "android.permission.\(event.permissionName ?? "unknown")",
                spokenText: "Your phone needs \(desc). Open the Jarvis app on your phone to grant it.",
                requiresAttention: true
            )

        // ── Not converted to signals ─────────────────────────────────────
        case .callAnswered, .callEnded, .heartbeat, .unknown:
            return nil
        }
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let history = try? JSONDecoder().decode(PersistedHistory.self, from: data)
        else { return }
        seenEventIds = Set(history.seenEventIds)
        recentEvents = history.recentEvents
    }

    private func saveHistory() {
        let history = PersistedHistory(
            seenEventIds: Array(seenEventIds.prefix(2000)),
            recentEvents: recentEvents
        )
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    // MARK: - ActiveContextRegistry push

    /// Pushes the event into `ActiveContextRegistry` so a follow-up like
    /// "call him back" / "reply saying yes" / "open it" can resolve to
    /// the correct contact + intent at conversational time.
    /// Pronouns like "him" / "her" / "they" are added so gendered or
    /// neutral follow-ups all resolve to the most recent call.
    private func recordActiveContext(from event: AndroidPhoneEvent) {
        let senderName = event.senderName ?? "Unknown caller"
        switch event.type {
        case .incomingCall, .callAnswered:
            ActiveContextRegistry.shared.record(
                source: .androidCall,
                title: senderName,
                summary: "Incoming call from \(senderName).",
                entities: [senderName],
                externalIdentifier: event.senderNumber ?? senderName,
                pronouns: ["him", "her", "they", "them"],
                priority: 3,
                suggestedActions: [.call, .open])
        case .missedCall:
            ActiveContextRegistry.shared.record(
                source: .androidCall,
                title: senderName,
                summary: "Missed call from \(senderName).",
                entities: [senderName],
                externalIdentifier: event.senderNumber ?? senderName,
                pronouns: ["him", "her", "they", "them"],
                priority: 3,
                suggestedActions: [.call, .open])
        case .smsReceived:
            ActiveContextRegistry.shared.record(
                source: .androidSMS,
                title: senderName,
                summary: "Text from \(senderName).",
                entities: [senderName],
                externalIdentifier: senderName,
                pronouns: ["him", "her", "they", "them"],
                priority: 2,
                suggestedActions: [.reply, .open])
        case .whatsAppReceived:
            ActiveContextRegistry.shared.record(
                source: .androidWhatsApp,
                title: senderName,
                summary: "WhatsApp from \(senderName).",
                entities: [senderName],
                externalIdentifier: senderName,
                pronouns: ["him", "her", "they", "them"],
                priority: 2,
                suggestedActions: [.reply, .open])
        default:
            break
        }
    }
}

// MARK: - Signal category constants

/// String constants for Android-sourced `ProactivitySignal.category`.
/// Used in `ProactivityEngine.decide()` for per-category muting.
enum AndroidSignalCategory {
    static let incomingCall = "phone.incoming_call"
    static let missedCall   = "phone.missed_call"
    static let sms          = "phone.sms"
    static let whatsApp     = "phone.whatsapp"
    static let notification = "phone.notification"
    static let batteryLow   = "phone.battery_low"
    static let permission   = "phone.permission"
}
