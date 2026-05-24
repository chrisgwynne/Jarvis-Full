import Foundation

// MARK: - Pure auth-validation helper

/// Pure (no side effects) helper that classifies an inbound frame's auth
/// state.  Lives at the file root rather than as a private method on the
/// bridge so it can be exercised in unit tests without standing up the
/// entire `AndroidBridgeManager` + `JarvisController` graph.
enum AndroidBridgeAuth {

    /// Why a frame was rejected.  Raw values are the strings used in
    /// telemetry / diagnostics so they're stable across the codebase.
    enum FailureReason: String, Sendable, Equatable {
        case serverTokenMissing  = "server_token_missing"
        case clientTokenMissing  = "client_token_missing"
        case clientTokenMismatch = "client_token_mismatch"
    }

    /// Outcome of an auth check.  The three states map cleanly to the
    /// bridge's three behaviours: pass through to routing, accept, or
    /// silently drop with a recorded failure.
    enum Validation: Sendable, Equatable {
        case passthrough              // requireAuth == false → never reject
        case ok
        case rejected(FailureReason)
    }

    /// Classify whether a frame should be admitted.  Inputs:
    ///   - `envelopeAuth`: the `auth` field on the inbound envelope.
    ///   - `expectedToken`: the server's configured `webSocketAuthToken`.
    ///   - `requireAuth`: the server's `requireWebSocketAuth` toggle.
    ///
    /// Returns one of `.passthrough` / `.ok` / `.rejected(reason)`.
    static func validate(envelopeAuth: String?,
                         expectedToken: String?,
                         requireAuth: Bool) -> Validation {
        guard requireAuth else { return .passthrough }
        guard let expected = expectedToken, !expected.isEmpty else {
            return .rejected(.serverTokenMissing)
        }
        guard let provided = envelopeAuth, !provided.isEmpty else {
            return .rejected(.clientTokenMissing)
        }
        guard provided == expected else {
            return .rejected(.clientTokenMismatch)
        }
        return .ok
    }
}

// MARK: - Bridge Diagnostics

/// Snapshot of the current Android bridge connection state.
/// Stored on AndroidBridgeManager and surfaced to AppState for the overlay.
struct AndroidBridgeDiagnostics: Equatable {
    var isConnected: Bool = false
    var deviceName: String = ""
    var batteryLevel: Int = -1          // -1 = unknown
    /// True when the phone is plugged in / on a wireless charger.  -1
    /// in the legacy "battery only" int is replaced here by a tri-state:
    /// nil = unknown, true = charging, false = on battery.
    var isCharging: Bool? = nil
    /// "wifi" / "cellular" / "ethernet" / "none" / "unknown".  Free-form
    /// short string so older Android builds that don't yet send this field
    /// still parse — we just keep `unknown`.
    var network: String = "unknown"
    var lastHeartbeat: Date? = nil
    var lastCommandId: String = ""
    var lastCommandStatus: String = ""
    var roundtripLatencyMs: Int = -1    // -1 = no measurement yet
    var authFailures: Int = 0
    var timeouts: Int = 0
    var capabilities: [String] = []
    var capabilitiesLastSync: Date? = nil

    /// Human-friendly "X minutes ago" suffix.  Used by the
    /// phone-status / phone-battery responses when the device is offline.
    func lastSeenDescription(now: Date = Date()) -> String {
        guard let hb = lastHeartbeat else { return "never seen" }
        let secs = Int(now.timeIntervalSince(hb))
        if secs < 60       { return "\(secs) seconds ago" }
        let mins = secs / 60
        if mins < 60       { return "\(mins) minute\(mins == 1 ? "" : "s") ago" }
        let hrs = mins / 60
        if hrs < 24        { return "\(hrs) hour\(hrs == 1 ? "" : "s") ago" }
        let days = hrs / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}

// MARK: - AndroidBridgeManager

/// Manages the Mac ↔ Android WebSocket bridge.
///
/// **Inbound (Android → Mac) — three message classes:**
///
///  1. `type: "response"` — correlated reply to a Mac-initiated command.
///     Resolved via `pendingRequests[id]` continuation.
///
///  2. `type: "event" | "phone_event" | "notification_event" | "heartbeat"` — unsolicited
///     push event from Android.  Routed to `handleAndroidEvent` → `AndroidEventReceiver`
///     → `ProactivityEngine`.  No reply sent.
///
///  3. `default` — legacy Android→Mac commands (`ping`, `speak`, etc.) that expect a
///     `WSResponse` reply.
///
/// **Auth model:** when `requireWebSocketAuth` is enabled, every inbound frame
/// (of every class above) must carry the shared `auth` token in its top-level
/// JSON.  The gate is applied **once** at the top of `server(_:didReceive:)`
/// before any routing, decode, side effect, signal dispatch, speech, or
/// notification handling.  Failed-auth attempts are silently rejected (no reply
/// sent — avoids confirming token shape to attackers) and counted; a
/// connection that produces too many failures inside the rate-limit window is
/// cancelled.
///
/// **Outbound (Mac → Android):** Mac pushes `AndroidCommand` via `broadcast()`.
/// Android must respond with `AndroidResponse` whose `id` matches the request.
/// Responses are correlated by UUID via `CheckedContinuation` with a 15-second timeout.
@MainActor
final class AndroidBridgeManager: WebSocketServer.Delegate {

    private weak var controller: JarvisController?
    private weak var state: AppState?
    private let prefs: PreferencesStore

    /// Injected by JarvisController. Receives decoded AndroidPhoneEvent values.
    weak var eventReceiver: AndroidEventReceiver?

    /// Pending outbound requests awaiting a correlated response from Android.
    private var pendingRequests: [String: CheckedContinuation<AndroidResponse, Never>] = [:]

    /// Live diagnostics surfaced to the UI.
    private(set) var diagnostics = AndroidBridgeDiagnostics()

    /// Sliding window of recent auth-failure timestamps.  Used to suppress
    /// log spam and (when too many fail) cancel the underlying connection.
    private var recentAuthFailures: [Date] = []
    /// More than this many failures inside `authRateLimitWindow` → cancel
    /// the bridge connection (mitigates brute-force token guessing).
    private let authRateLimitMax: Int = 10
    /// Sliding window length for the failure counter.
    private let authRateLimitWindow: TimeInterval = 60

    // MARK: - Init

    init(controller: JarvisController, state: AppState, prefs: PreferencesStore) {
        self.controller = controller
        self.state = state
        self.prefs = prefs
    }

    // MARK: - Auth gate

    /// Validates the shared `auth` token on a freshly-received envelope.
    /// Delegates the pure decision to `AndroidBridgeAuth.validate` so the
    /// logic is independently testable; this wrapper applies the side
    /// effects (failure logging + rate-limit counter).
    ///
    /// - Parameter envelope: peeked envelope (or `nil` if JSON didn't parse).
    /// - Returns: `true` if the frame may proceed.  `false` means it must be
    ///   dropped silently — no response is sent so an attacker can't probe
    ///   for the expected token shape from observable replies.
    private func validateInboundAuth(envelope: BridgeEnvelope?) -> Bool {
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  envelope?.auth,
            expectedToken: prefs.webSocketAuthToken,
            requireAuth:   prefs.current.requireWebSocketAuth)
        switch result {
        case .passthrough, .ok:
            return true
        case .rejected(let reason):
            recordAuthFailure(reason: reason.rawValue)
            return false
        }
    }

    /// Records a failed auth attempt and, when the sliding-window threshold
    /// is exceeded, asks the underlying WebSocket to drop the connection.
    private func recordAuthFailure(reason: String) {
        diagnostics.authFailures += 1
        state?.androidBridgeAuthFailures = diagnostics.authFailures

        let now = Date()
        recentAuthFailures.append(now)
        recentAuthFailures.removeAll { now.timeIntervalSince($0) > authRateLimitWindow }

        // Only log first failure in each window to avoid flooding diagnostics.
        if recentAuthFailures.count == 1 {
            state?.log("net", .warn, "Rejected unauthenticated WS frame (reason=\(reason))")
            Log.net.warning("ws: auth rejected reason=\(reason, privacy: .public)")
        }
        // Per-failure telemetry event (no token value, just the reason class).
        JarvisTelemetry.shared.record(.bridgeAuthFailed, ["reason": reason])

        if recentAuthFailures.count >= authRateLimitMax {
            state?.log("net", .warn,
                       "auth_rate_limit_tripped: \(recentAuthFailures.count) failures in \(Int(authRateLimitWindow))s — closing connection")
            Log.net.error("ws: auth rate limit tripped; closing connection")
            controller?.wsServer.stop()
            // Server will be re-started by the controller's lifecycle next tick.
            recentAuthFailures.removeAll()
        }
    }

    // MARK: - WebSocketServer.Delegate

    nonisolated func server(_ server: WebSocketServer, didChangeStatus status: DeviceStatus) {
        Task { @MainActor [weak self] in
            self?.state?.androidServerStatus = status
            self?.state?.log("net", .info, "WebSocket status: \(status.label)")
            if case .ready = status {
                // nothing extra needed
            } else {
                self?.diagnostics.isConnected = false
                self?.state?.androidBridgeConnected = false
            }
        }
    }

    nonisolated func server(_ server: WebSocketServer, didChangeClients count: Int) {
        Task { @MainActor [weak self] in
            self?.state?.connectedClients = count
            let connected = count > 0
            self?.diagnostics.isConnected = connected
            self?.state?.androidBridgeConnected = connected
            if !connected {
                // Cancel all pending requests — device disconnected
                for (_, cont) in self?.pendingRequests ?? [:] {
                    cont.resume(returning: AndroidResponse(
                        id: "", type: "response", ok: false,
                        status: "disconnected", message: "Android disconnected",
                        payload: nil))
                }
                self?.pendingRequests.removeAll()
            }
        }
    }

    nonisolated func server(_ server: WebSocketServer,
                            didReceive data: Data,
                            respond: @escaping (Data) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            // ── Pre-parse raw logging (fires before ANY decode attempt) ──────────
            let payloadPreview = String(data: data, encoding: .utf8).map { String($0.prefix(300)) }
                               ?? "<non-UTF8 \(data.count)B>"
            Log.net.debug("WS recv \(data.count, privacy: .public)B: \(payloadPreview, privacy: .public)")
            state?.androidBridgeRawMessagesReceived += 1
            state?.androidBridgeLastRawPayload = payloadPreview

            // ── Envelope peek ────────────────────────────────────────────────────
            let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: data)
            let msgType  = envelope?.type ?? "<nil>"
            let msgCmd   = envelope?.commandOrEvent ?? "<nil>"
            state?.log("bridge", .debug,
                       "recv envelope type=\(msgType) cmd=\(msgCmd) id=\(envelope?.id ?? "-")")

            // ── CENTRAL AUTH GATE ────────────────────────────────────────────────
            //
            // EVERY inbound frame must pass auth when `requireWebSocketAuth` is on.
            // This is the single chokepoint — no routing, no signal dispatch, no
            // speech, no command handling happens before this check.
            //
            // Failed frames are dropped silently (no `respond()` callback invoked)
            // to avoid leaking timing/shape information to an attacker.
            guard self.validateInboundAuth(envelope: envelope) else { return }

            switch envelope?.type {

            // ── Correlated reply to a Mac-initiated command ───────────────
            case "response":
                await self.handleAndroidResponse(data)

            // ── Unsolicited push events from Android ─────────────────────
            //
            // Android apps use multiple type spellings:
            //   "event"              — canonical Jarvis protocol
            //   "phone_event"        — Android-native envelope format
            //   "notification_event" — notification push
            //   "heartbeat"          — periodic keepalive
            //
            // (Auth already validated above — this path is safe to enter.)
            case "event",
                 "phone_event",
                 "notification_event",
                 "heartbeat":
                await self.handleAndroidEvent(data)

            // ── Unknown frame type — log and drop with no reply ──────────
            case .some(let unknown) where !unknown.isEmpty:
                self.state?.androidBridgeUnsupportedMessages += 1
                self.state?.log("bridge", .warn,
                                "unknown_frame_type type=\(unknown) cmd=\(msgCmd)")
                Log.net.warning("ws: unknown frame type=\(unknown, privacy: .public) cmd=\(msgCmd, privacy: .public)")
                JarvisTelemetry.shared.record(.bridgeFrameRejected,
                                              ["type": unknown, "cmd": msgCmd])

            default:
                // Legacy path — Android-initiated command that expects a WSResponse reply
                // (ping, speak, show_command_centre, continue_on_mac, etc.)
                let response = await self.handle(data)
                if let response {
                    if let encoded = try? JSONEncoder().encode(response) {
                        respond(encoded)
                    }
                }
            }
        }
    }

    // MARK: - Outbound: Mac → Android

    /// Push a command to the connected Android device and await a correlated response.
    /// Times out after 15 seconds, returning a failed `AndroidResponse`.
    ///
    /// - Parameters:
    ///   - command: Command name (e.g. `"call_contact"`, `"send_sms"`).
    ///   - payload: Optional structured parameters.
    ///   - transcript: Raw user transcript that triggered this command — attached as
    ///     context so the Android app knows what was said (useful for logging / display).
    ///   - sessionId: Mac session UUID for cross-device correlation.
    func sendToAndroid(command: String,
                       payload: AndroidCommandPayload? = nil,
                       transcript: String = "",
                       sessionId: String = "") async -> AndroidResponse {
        let id = UUID().uuidString
        let auth: String? = prefs.current.requireWebSocketAuth ? prefs.webSocketAuthToken : nil
        let ctx = AndroidCommandContext(
            transcript: transcript.isEmpty ? nil : transcript,
            sessionId: sessionId.isEmpty ? nil : sessionId
        )
        let cmd = AndroidCommand(id: id, command: command, payload: payload, context: ctx, auth: auth)
        guard let data = try? JSONEncoder().encode(cmd) else {
            return AndroidResponse(id: id, type: "response", ok: false,
                                   status: "error", message: "Encode failed", payload: nil)
        }

        // Update diagnostics
        diagnostics.lastCommandId = id

        // Measure round-trip latency
        let sendAt = Date()

        // Push to all connected clients (only one Android device expected)
        guard let controller else {
            return AndroidResponse(id: id, type: "response", ok: false,
                                   status: "error", message: "Controller unavailable", payload: nil)
        }
        controller.wsServer.broadcast(data)

        // Wait for correlated response with 15s timeout
        let response: AndroidResponse = await withCheckedContinuation { continuation in
            pendingRequests[id] = continuation
            state?.androidBridgePendingRequestCount = pendingRequests.count

            Task {
                // 15s timeout — generous enough for cross-region Tailscale latency
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if let cont = self.pendingRequests.removeValue(forKey: id) {
                    self.state?.androidBridgePendingRequestCount = self.pendingRequests.count
                    self.diagnostics.timeouts += 1
                    self.state?.androidBridgeTimeouts = self.diagnostics.timeouts
                    cont.resume(returning: AndroidResponse(
                        id: id, type: "response", ok: false,
                        status: "timeout", message: "No response from Android", payload: nil))
                }
            }
        }

        // Record latency
        let ms = Int(Date().timeIntervalSince(sendAt) * 1000)
        diagnostics.roundtripLatencyMs = ms
        diagnostics.lastCommandStatus = response.status ?? (response.ok ? "ok" : "error")
        state?.androidBridgeLatencyMs = ms
        state?.androidBridgeLastStatus = diagnostics.lastCommandStatus

        return response
    }

    // MARK: - Inbound: Android → Mac (response correlation)

    private func handleAndroidResponse(_ data: Data) async {
        guard let response = try? JSONDecoder().decode(AndroidResponse.self, from: data) else {
            Log.net.warning("handleAndroidResponse: decode failed")
            state?.androidBridgeParseFailures += 1
            return
        }
        if let continuation = pendingRequests.removeValue(forKey: response.id) {
            state?.androidBridgePendingRequestCount = pendingRequests.count
            continuation.resume(returning: response)
        } else {
            // No pending request matched — might be a late response; log and ignore
            Log.net.debug("handleAndroidResponse: no pending request for id=\(response.id, privacy: .public)")
        }
    }

    // MARK: - Inbound: Android → Mac (events / heartbeats)

    private func handleAndroidEvent(_ data: Data) async {
        state?.androidBridgeUnsolicitedEvents += 1

        guard let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: data) else {
            Log.net.warning("handleAndroidEvent: envelope decode failed")
            state?.androidBridgeParseFailures += 1
            return
        }

        // Determine the effective command/event name.
        //
        // Priority:
        //  1. envelope.commandOrEvent  — explicit "command"/"event" sub-type field
        //  2. envelope.type itself     — when the type IS the action (e.g. "heartbeat")
        let envelopeType = envelope.type ?? ""
        let effectiveCmd = envelope.commandOrEvent ?? envelopeType

        Log.net.info("handleAndroidEvent: type=\(envelopeType, privacy: .public) cmd=\(effectiveCmd, privacy: .public)")
        state?.log("bridge", .info,
                   "push event: type=\(envelopeType) cmd=\(effectiveCmd)")

        switch effectiveCmd {

        // ── Heartbeat ─────────────────────────────────────────────────────
        case "heartbeat":
            handleHeartbeat(data: data)
            state?.androidBridgeHeartbeatCount += 1
            state?.androidBridgeLastEventRouted = "heartbeat"

        // ── Capabilities report ───────────────────────────────────────────
        case "capabilities_report":
            if let response = try? JSONDecoder().decode(AndroidResponse.self, from: data),
               let caps = response.payload?.capabilities {
                diagnostics.capabilities = caps
                diagnostics.capabilitiesLastSync = Date()
                state?.androidBridgeCapabilities = caps
                state?.log("bridge", .info, "capabilities synced: \(caps.count) entries")
            }

        // ── Phone events ──────────────────────────────────────────────────
        // Accept both the generic envelope ("phone_event") and direct event names
        // ("incoming_call" etc.). routePhoneEvent handles further decode branching.
        case "phone_event",
             "incoming_call", "missed_call", "call_answered", "call_ended",
             "sms_received", "whatsapp_received", "notification_received",
             "battery_status", "permission_required":
            routePhoneEvent(data: data, commandHint: effectiveCmd)
            state?.androidBridgePhoneEventCount += 1
            state?.androidBridgeLastEventRouted = effectiveCmd

        default:
            Log.net.debug("handleAndroidEvent: unhandled cmd=\(effectiveCmd, privacy: .public)")
            state?.androidBridgeUnsupportedMessages += 1
            state?.log("bridge", .debug, "unhandled push event: \(effectiveCmd)")
        }
    }

    // MARK: - Heartbeat helper

    private func handleHeartbeat(data: Data) {
        diagnostics.lastHeartbeat = Date()
        state?.androidBridgeLastHeartbeat = diagnostics.lastHeartbeat

        // Try AndroidResponse shape first (battery/deviceName in payload)
        if let response = try? JSONDecoder().decode(AndroidResponse.self, from: data) {
            if let battery = response.payload?.battery {
                diagnostics.batteryLevel = battery
                state?.androidBridgeBattery = battery
            }
            if let name = response.payload?.deviceName, !name.isEmpty {
                diagnostics.deviceName = name
                state?.androidBridgeDeviceName = name
            }
            if let charging = response.payload?.charging {
                diagnostics.isCharging = charging
            }
            if let network = response.payload?.network, !network.isEmpty {
                diagnostics.network = network
            }
            return
        }
        // Fallback: try a flat heartbeat shape:
        // { "battery": 85, "batteryPercent": 85, "charging": true,
        //   "network": "wifi", "deviceName": "Galaxy Fold 6" }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let battery = json["battery"] as? Int
                          ?? json["batteryLevel"] as? Int
                          ?? json["battery_level"] as? Int
                          ?? json["batteryPercent"] as? Int
                          ?? json["battery_percent"] as? Int {
                diagnostics.batteryLevel = battery
                state?.androidBridgeBattery = battery
            }
            if let name = json["deviceName"] as? String
                       ?? json["device_name"] as? String,
               !name.isEmpty {
                diagnostics.deviceName = name
                state?.androidBridgeDeviceName = name
            }
            if let charging = json["charging"] as? Bool
                           ?? json["isCharging"] as? Bool
                           ?? json["is_charging"] as? Bool {
                diagnostics.isCharging = charging
            }
            if let network = json["network"] as? String
                          ?? json["networkType"] as? String
                          ?? json["network_type"] as? String,
               !network.isEmpty {
                diagnostics.network = network
            }
        }
    }

    /// Decode an `AndroidPhoneEvent` and forward to the event receiver.
    ///
    /// Four wire formats are tried in priority order:
    ///
    ///  1. **Native format** — top-level fields match `AndroidPhoneEvent` CodingKeys exactly
    ///     (e.g. `event_id`, `type: "incoming_call"`, `sender_name`).
    ///
    ///  2. **Nested payload, native fields** — event fields nested under a `payload` key
    ///     but still using our field names.
    ///
    ///  3. **Android-native envelope** — `type: "phone_event"`, `event: "incoming_call"`,
    ///     `payload: { contactName, phoneNumber, … }` (camelCase or snake_case).
    ///
    ///  4. **Fabricated minimal** — only the event type is known from `commandHint`;
    ///     a bare synthetic event is created as last resort.
    private func routePhoneEvent(data: Data, commandHint: String?) {
        let preview = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
        Log.net.debug("routePhoneEvent hint=\(commandHint ?? "nil", privacy: .public): \(preview, privacy: .public)")

        // ── Attempt 1: native top-level format ───────────────────────────
        // e.g. {"event_id":"xxx","type":"incoming_call","sender_name":"Alice"}
        if let event = try? JSONDecoder().decode(AndroidPhoneEvent.self, from: data),
           event.type != .unknown {
            Log.net.info("routePhoneEvent: matched native format type=\(event.type.rawValue, privacy: .public)")
            state?.log("bridge", .info, "phone event [native] type=\(event.type.rawValue) sender=\(event.senderName ?? "-")")
            eventReceiver?.receive(event)
            return
        }

        // ── Attempt 2: nested payload with native fields ─────────────────
        // e.g. {"command":"incoming_call","payload":{"event_id":"xxx","type":"incoming_call",...}}
        if let wrapper = try? JSONDecoder().decode(PhoneEventWrapper.self, from: data),
           let event = wrapper.payload,
           event.type != .unknown {
            Log.net.info("routePhoneEvent: matched nested-native format type=\(event.type.rawValue, privacy: .public)")
            state?.log("bridge", .info, "phone event [nested] type=\(event.type.rawValue) sender=\(event.senderName ?? "-")")
            eventReceiver?.receive(event)
            return
        }

        // ── Attempt 3: Android-native envelope ───────────────────────────
        // e.g. {"type":"phone_event","event":"incoming_call","payload":{"contactName":"Alice"}}
        if let env = try? JSONDecoder().decode(AndroidNativePhoneEnvelope.self, from: data) {
            // Determine the true event sub-type
            let subtypeStr = env.eventSubtype
                          ?? (env.type != "phone_event" ? env.type : nil)
                          ?? commandHint
            if let subtypeStr, let eventType = AndroidEventType(rawValue: subtypeStr) {
                let p = env.payload
                let resolvedName = p?.contactName ?? p?.senderName ?? p?.callerName

                var dict: [String: Any] = [
                    "event_id": env.id ?? UUID().uuidString,
                    "type":     eventType.rawValue
                ]
                if let n  = resolvedName                          { dict["sender_name"]            = n  }
                if let ph = p?.phoneNumber                        { dict["sender_number"]           = ph }
                if let b  = p?.messageBody                        { dict["message_body"]            = b  }
                if let a  = p?.appName                            { dict["app_name"]                = a  }
                if let lv = p?.batteryLevel                       { dict["battery_level"]           = lv }
                if let ch = p?.isCharging                         { dict["is_charging"]             = ch }
                if let pn = p?.permissionName                     { dict["permission_name"]         = pn }
                if let pd = p?.permissionDescription              { dict["permission_description"]  = pd }

                if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                   let event = try? JSONDecoder().decode(AndroidPhoneEvent.self, from: jsonData) {
                    Log.net.info("routePhoneEvent: matched Android-envelope format type=\(event.type.rawValue, privacy: .public)")
                    state?.log("bridge", .info,
                               "phone event [Android-env] type=\(event.type.rawValue) sender=\(resolvedName ?? "-")")
                    eventReceiver?.receive(event)
                    return
                }
            }
        }

        // ── Attempt 4: fabricate minimal event from commandHint ──────────
        if let cmd = commandHint, let eventType = AndroidEventType(rawValue: cmd) {
            let jsonStr = #"{"event_id":"\#(UUID().uuidString)","type":"\#(eventType.rawValue)"}"#
            let jsonData = Data(jsonStr.utf8)
            if let event = try? JSONDecoder().decode(AndroidPhoneEvent.self, from: jsonData) {
                Log.net.info("routePhoneEvent: fabricated minimal event type=\(eventType.rawValue, privacy: .public)")
                state?.log("bridge", .info, "phone event [fabricated] type=\(eventType.rawValue)")
                eventReceiver?.receive(event)
                return
            }
        }

        // All attempts failed
        Log.net.warning("routePhoneEvent: all decode attempts failed for hint=\(commandHint ?? "nil", privacy: .public)")
        state?.log("bridge", .warn, "phone event decode failed for hint=\(commandHint ?? "nil")")
        state?.androidBridgeParseFailures += 1
    }

    // MARK: - Wire format helpers

    private struct PhoneEventWrapper: Decodable {
        let payload: AndroidPhoneEvent?
    }

    // MARK: - Inbound: Android → Mac (commands)

    /// Handle a command sent *from* Android to Mac. Returns a `WSResponse` to send back,
    /// or `nil` if the frame is a response/event that should not generate a reply.
    private func handle(_ data: Data) async -> WSResponse? {
        let cmd: WSCommand
        do {
            cmd = try JSONDecoder().decode(WSCommand.self, from: data)
        } catch {
            return WSResponse(id: UUID().uuidString, ok: false,
                              message: "Invalid JSON: \(error.localizedDescription)")
        }

        // Belt-and-braces auth check.  The central gate in
        // `server(_:didReceive:respond:)` already validated `auth`; this
        // mirrors that check on the WSCommand-shape payload so a refactor
        // that ever bypasses the gate still can't reach side effects.
        if prefs.current.requireWebSocketAuth {
            guard let expected = prefs.webSocketAuthToken,
                  !expected.isEmpty,
                  let provided = cmd.auth,
                  provided == expected else {
                recordAuthFailure(reason: "wscommand_token_mismatch")
                return WSResponse(id: cmd.id, ok: false, message: "Unauthorized")
            }
        }

        guard let controller else {
            return WSResponse(id: cmd.id, ok: false, message: "Controller not ready")
        }

        switch cmd.command {

        // Phase-1 commands
        case "ping":
            return WSResponse(id: cmd.id, ok: true, message: "pong")

        case "show_command_centre":
            controller.showCommandCentre()
            return WSResponse(id: cmd.id, ok: true, message: "Showing")

        case "hide_command_centre":
            controller.hideCommandCentre()
            return WSResponse(id: cmd.id, ok: true, message: "Hiding")

        case "speak":
            guard let text = cmd.payload?.text, !text.isEmpty else {
                return WSResponse(id: cmd.id, ok: false, message: "Missing payload.text")
            }
            controller.speak(text)
            return WSResponse(id: cmd.id, ok: true, message: "Speaking")

        case "stop_speaking":
            controller.stopSpeaking()
            return WSResponse(id: cmd.id, ok: true, message: "Stopped")

        case "capture_camera":
            let summary = await controller.captureCameraAndDescribe()
            return WSResponse(id: cmd.id, ok: true, message: summary)

        case "status":
            let snapshot = controller.statusSnapshot()
            return WSResponse(id: cmd.id, ok: true, message: "Status", data: snapshot)

        case "open_app":
            guard let name = cmd.payload?.name, !name.isEmpty else {
                return WSResponse(id: cmd.id, ok: false, message: "Missing payload.name")
            }
            do {
                try await controller.openApp(named: name)
                return WSResponse(id: cmd.id, ok: true, message: "Opening \(name)")
            } catch {
                return WSResponse(id: cmd.id, ok: false, message: error.localizedDescription)
            }

        // Phase-2 Android handoff
        case "continue_on_mac":
            let text = cmd.payload?.context ?? cmd.payload?.text ?? ""
            controller.continueFromAndroid(context: text, sourceID: cmd.source)
            return WSResponse(id: cmd.id, ok: true, message: "Continued")

        case "send_context":
            let text = cmd.payload?.context ?? ""
            controller.receiveAndroidContext(text, sourceID: cmd.source)
            return WSResponse(id: cmd.id, ok: true, message: "Context stored")

        case "get_context":
            let snap = controller.contextSnapshot()
            return WSResponse(id: cmd.id, ok: true, message: "Context", data: snap)

        case "show_context":
            controller.showContext()
            return WSResponse(id: cmd.id, ok: true, message: "Showing")

        case "capture_and_describe":
            let summary = await controller.captureCameraAndDescribe()
            return WSResponse(id: cmd.id, ok: true, message: summary)

        case "speak_and_show":
            let text = cmd.payload?.text ?? ""
            if !text.isEmpty {
                controller.speak(text)
                controller.showCommandCentre()
            }
            return WSResponse(id: cmd.id, ok: true, message: "Spoken & shown")

        // Phase-2 Home Assistant pass-through
        case "home_status":
            let snap = await controller.homeStatusSummary()
            return WSResponse(id: cmd.id, ok: true, message: snap)

        case "home_turn_on":
            guard let entity = cmd.payload?.entity, !entity.isEmpty else {
                return WSResponse(id: cmd.id, ok: false, message: "Missing payload.entity")
            }
            do {
                try await controller.smartHome.turnOn(entity)
                return WSResponse(id: cmd.id, ok: true, message: "On: \(entity)")
            } catch {
                return WSResponse(id: cmd.id, ok: false, message: error.localizedDescription)
            }

        case "home_turn_off":
            guard let entity = cmd.payload?.entity, !entity.isEmpty else {
                return WSResponse(id: cmd.id, ok: false, message: "Missing payload.entity")
            }
            do {
                try await controller.smartHome.turnOff(entity)
                return WSResponse(id: cmd.id, ok: true, message: "Off: \(entity)")
            } catch {
                return WSResponse(id: cmd.id, ok: false, message: error.localizedDescription)
            }

        default:
            return WSResponse(id: cmd.id, ok: false, message: "Unknown command: \(cmd.command)")
        }
    }

    // MARK: - Debug: test event injection

    /// Fabricates an `AndroidPhoneEvent` locally and routes it through the normal
    /// event pipeline — bypassing the WebSocket entirely.
    ///
    /// Used to verify that Mac-side routing, proactivity, and speech all work
    /// **independently** of the Android transport layer.  If this works but real
    /// Android events don't, the bug is in the wire format / transport.
    ///
    /// - Parameters:
    ///   - type: The event type to inject (default: `.incomingCall`).
    ///   - senderName: Optional contact name to include (default: "Test Caller").
    func injectTestAndroidEvent(type eventType: AndroidEventType = .incomingCall,
                                senderName: String = "Test Caller") {
        let id = UUID().uuidString
        var dict: [String: Any] = [
            "event_id": id,
            "type":     eventType.rawValue
        ]
        if eventType.hasSender { dict["sender_name"] = senderName }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let event = try? JSONDecoder().decode(AndroidPhoneEvent.self, from: jsonData)
        else {
            state?.log("bridge", .warn, "injectTestAndroidEvent: fabrication failed for \(eventType.rawValue)")
            return
        }

        state?.log("bridge", .info,
                   "🧪 injecting test event: type=\(eventType.rawValue) sender=\(senderName)")
        state?.androidBridgeUnsolicitedEvents += 1
        state?.androidBridgePhoneEventCount  += 1
        state?.androidBridgeLastEventRouted   = eventType.rawValue
        eventReceiver?.receive(event)
    }

    // MARK: - Capability helpers

    /// True if the Android device is currently connected.
    var isPhoneOnline: Bool { diagnostics.isConnected }

    /// True if the given capability is in the last synced capabilities list.
    /// Returns `true` when no capabilities have been synced yet (nil-safe) so
    /// commands always flow through on first connection.
    func hasCapability(_ capability: String) -> Bool {
        if diagnostics.capabilities.isEmpty { return true }  // not synced yet — allow through
        return diagnostics.capabilities.contains(capability)
    }

    func requestCapabilities() async {
        _ = await sendToAndroid(command: "get_capabilities")
    }
}
