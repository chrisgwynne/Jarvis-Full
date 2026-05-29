import Foundation

/// Listens to the Home Assistant WebSocket API and emits `ProactivitySignal`
/// values for notable state changes (door/lock left open, motion, safety
/// sensors, device going offline, alarm state).
///
/// Unlike polling providers this one keeps a persistent WebSocket connection
/// and reacts to events in real-time. A reconnect watchdog retries every
/// 5 minutes if the connection drops.
@MainActor
final class HomeAssistantProactivityProvider: ProactivitySignalProvider {

    // MARK: - ProactivitySignalProvider

    var source: SignalSource { .homeAssistant }

    // MARK: - Private

    private weak var engine: ProactivityEngine?
    private weak var appState: AppState?
    private let prefs: PreferencesStore

    /// Injected after construction by JarvisController; allows motion→camera mapping.
    weak var motionMapper: HAMotionCameraMapper?
    /// Injected after construction by JarvisController; resolves entity metadata.
    weak var entityRegistry: HAEntityRegistry?

    private var wsClient: HomeAssistantWebSocketClient?
    private var reconnectTask: Task<Void, Never>?
    private var isConnected = false

    /// Tracks when a door/lock/window first opened/unlocked
    private var openSince: [String: Date] = [:]
    /// Prevents the same "left open" alert from firing more than once per session
    private var emittedOpenAlerts: Set<String> = []
    /// Deferred Tasks that fire after a 10-minute delay if the sensor hasn't closed.
    /// Cancelled immediately when the sensor returns to closed/locked state.
    private var openAlertTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Init

    init(engine: ProactivityEngine, appState: AppState, prefs: PreferencesStore) {
        self.engine   = engine
        self.appState = appState
        self.prefs    = prefs
    }

    // MARK: - ProactivitySignalProvider

    func start() {
        connect()
        // Reconnect watchdog: every 5 minutes check if still alive
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 min
                await self?.reconnectIfNeeded()
            }
        }
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        openAlertTasks.values.forEach { $0.cancel() }
        openAlertTasks.removeAll()
        // Clear all per-session tracking dicts.  Without this, a stop()→start()
        // cycle (e.g. preferences update, subsystem toggle) leaves stale state:
        // the next "door open" event sees `openSince[entityId] != nil` from the
        // previous session and skips scheduling a new deferred alert.
        openSince.removeAll()
        emittedOpenAlerts.removeAll()
        wsClient?.disconnect()
        wsClient = nil
        isConnected = false
    }

    /// For WS provider, pollNow reconnects if disconnected.
    func pollNow() async {
        await reconnectIfNeeded()
    }

    // MARK: - Connection management

    private func connect() {
        let currentPrefs = prefs.current
        guard let baseURL = currentPrefs.smartHomeBaseURL, !baseURL.isEmpty,
              let token   = currentPrefs.smartHomeToken,   !token.isEmpty else {
            Log.app.debug("[ha-prov] No HA credentials configured — skipping WebSocket connection")
            return
        }

        wsClient?.disconnect()
        isConnected = false

        let client = HomeAssistantWebSocketClient(baseURL: baseURL, token: token)
        client.onEvent = { [weak self] event in
            // onEvent is called on MainActor already (HomeAssistantWebSocketClient is @MainActor)
            self?.handleEvent(event)
        }
        wsClient = client
        client.connect()
    }

    private func reconnectIfNeeded() async {
        guard !isConnected else { return }
        Log.app.info("[ha-prov] Reconnect watchdog — attempting reconnect")
        connect()
    }

    // MARK: - Event dispatch

    private func handleEvent(_ event: HomeAssistantWebSocketClient.HAWSEvent) {
        switch event {
        case .connected:
            isConnected = true
            appState?.haWebSocketConnected = true
            Log.app.info("[ha-prov] WebSocket connected and subscribed to state_changed")

        case .disconnected(let error):
            isConnected = false
            appState?.haWebSocketConnected = false
            if let error {
                Log.app.warning("[ha-prov] WebSocket disconnected: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.app.info("[ha-prov] WebSocket disconnected (auth failure or remote close)")
            }

        case .stateChanged(let entityId, let newState, let oldState, let attributes):
            // Publish low-level bus event for any subscriber (diagnostics, task threads, etc.)
            SystemBus.shared.publish(HAEntityChangedEvent(
                entityID: entityId,
                newState: newState,
                oldState: oldState))
            let friendlyName = attributes["friendly_name"] as? String ?? entityId
            appState?.haLastEventDescription = "\(friendlyName) → \(newState)"

            handleStateChange(entityId: entityId,
                              newState: newState,
                              oldState: oldState,
                              attributes: attributes)
        }
    }

    // MARK: - Dedupe keys

    /// Entity-independent dedupe key for doorbell events, shared by BOTH the
    /// binary_sensor/motion emitter and the camera idle→streaming emitter. A
    /// single physical doorbell press frequently triggers both paths (often with
    /// different entity IDs), so keying on the entity let two alerts through.
    /// Bucketing by `cooldown` window collapses them into one alert.
    static func sharedDoorbellDedupeKey(cooldown: TimeInterval) -> String {
        let bucket = Int(Date().timeIntervalSince1970 / cooldown)
        return "ha.doorbell.event.\(bucket)"
    }

    // MARK: - State change logic

    private func handleStateChange(entityId: String,
                                   newState: String,
                                   oldState: String?,
                                   attributes: [String: Any]) {
        guard let engine, let appState else { return }
        let settings = engine.settings
        let deviceClass = attributes["device_class"] as? String ?? ""
        let friendlyName = attributes["friendly_name"] as? String ?? entityId

        // ── Door / Window left open ───────────────────────────────────────────
        // NOTE: HA only fires state_changed on transition, NOT repeatedly while
        // open. We use a deferred async Task (10-min delay) instead of a
        // synchronous elapsed-time check — the sync check could never fire
        // because `openSince` is set and immediately checked in the same call.
        if settings.haDoorsEnabled,
           deviceClass == "door" || deviceClass == "window" || deviceClass == "garage_door" {

            if newState == "on" || newState == "open" {
                // Schedule a deferred alert only on the first "open" event
                if openSince[entityId] == nil {
                    openSince[entityId] = Date()
                    let key = "ha.door.open.\(entityId)"
                    scheduleOpenAlert(
                        entityId: entityId,
                        alertKey: key,
                        title: "\(friendlyName) is open",
                        body: "\(friendlyName) has been open for over 10 minutes.",
                        category: "ha.door",
                        spokenText: "\(friendlyName) has been open for over 10 minutes."
                    )
                }
            } else {
                let key = "ha.door.open.\(entityId)"
                openSince.removeValue(forKey: entityId)
                emittedOpenAlerts.remove(key)
                openAlertTasks[key]?.cancel()
                openAlertTasks.removeValue(forKey: key)
            }
        }

        // ── Lock left unlocked ────────────────────────────────────────────────
        if settings.haDoorsEnabled, deviceClass == "lock" {
            if newState == "unlocked" {
                // Schedule a deferred alert only on the first "unlocked" event
                if openSince[entityId] == nil {
                    openSince[entityId] = Date()
                    let key = "ha.lock.unlocked.\(entityId)"
                    scheduleOpenAlert(
                        entityId: entityId,
                        alertKey: key,
                        title: "\(friendlyName) is unlocked",
                        body: "\(friendlyName) has been unlocked for over 10 minutes.",
                        category: "ha.lock",
                        spokenText: "\(friendlyName) has been unlocked for over 10 minutes."
                    )
                }
            } else if newState == "locked" {
                let key = "ha.lock.unlocked.\(entityId)"
                openSince.removeValue(forKey: entityId)
                emittedOpenAlerts.remove(key)
                openAlertTasks[key]?.cancel()
                openAlertTasks.removeValue(forKey: key)
            }
        }

        // ── Motion detected (with camera overlay + doorbell handling) ─────────
        let isDoorbellEntity = deviceClass == "doorbell"
            || entityId.lowercased().contains("doorbell")
            || entityId.lowercased().contains("_ding")
            || friendlyName.lowercased().contains("doorbell")

        let isMotionTransition = (deviceClass == "motion" || isDoorbellEntity)
            && (newState == "on" || newState == "detected")
            && (oldState == "off" || oldState == "idle" || oldState?.lowercased() == "clear" || oldState == nil)

        if isMotionTransition {
            let isDoorbellAlert = isDoorbellEntity && settings.haDoorbellAlertsEnabled
            let isMotionAlert   = !isDoorbellEntity && settings.haMotionEnabled

            guard isDoorbellAlert || isMotionAlert else { return }

            let currentPrefs = prefs.current
            let mapper = motionMapper

            // Per-entity + global cooldown check
            let cooldown = isDoorbellEntity
                ? max(currentPrefs.haMotionCooldownSeconds, 30)   // doorbell: minimum 30s
                : currentPrefs.haMotionCooldownSeconds
            let globalCooldown = currentPrefs.haGlobalAlertCooldownSeconds

            guard mapper?.canAlert(entityID: entityId, cooldownSeconds: cooldown) ?? true else {
                Log.app.debug("[ha-prov] Motion alert suppressed by per-entity cooldown: \(entityId, privacy: .public)")
                return
            }
            guard mapper?.canGlobalAlert(cooldownSeconds: globalCooldown) ?? true else {
                Log.app.debug("[ha-prov] Motion alert suppressed by global cooldown")
                return
            }
            mapper?.recordAlert(entityID: entityId)

            // Find linked camera (if any)
            let mapping = mapper?.mapping(for: entityId)
            let linkedCameraID: String? = mapping?.cameraEntityID
                ?? entityRegistry?.inferredCamera(forSensor: entityId)

            // Publish SystemBus event
            let alertPhrase: String
            if isDoorbellEntity {
                alertPhrase = currentPrefs.haDoorbellPhrase
            } else {
                alertPhrase = mapping?.alertPhrase ?? "Motion detected by \(friendlyName)."
            }
            SystemBus.shared.publish(HAMotionDetectedEvent(
                sensorEntityID: entityId,
                linkedCameraID: linkedCameraID,
                isDoorbellEvent: isDoorbellEntity,
                alertPhrase: alertPhrase))

            // Build ProactivitySignal with camera overlay payload.
            // Doorbell dedupe key is ENTITY-INDEPENDENT (see sharedDoorbellDedupeKey):
            // one physical doorbell press can surface as both a binary_sensor "on"
            // event AND a camera.* idle→streaming event, often from different entity
            // IDs. A per-entity key let both through as two alerts. Both emitters now
            // share `ha.doorbell.event.<window>` so the orchestrator collapses them.
            let windowKey = isDoorbellEntity
                ? Self.sharedDoorbellDedupeKey(cooldown: cooldown)
                : "ha.camera_motion.\(entityId).\(Int(Date().timeIntervalSince1970 / cooldown))"
            let category = isDoorbellEntity ? "ha_doorbell" : "ha_camera_motion"
            let priority: SignalPriority = isDoorbellEntity ? .urgent : .high

            let signal = ProactivitySignal(
                source: .homeAssistant,
                title: isDoorbellEntity ? "Doorbell" : "Motion detected",
                body: alertPhrase,
                category: category,
                priority: priority,
                dedupeKey: windowKey,
                spokenText: alertPhrase,
                requiresAttention: isDoorbellEntity,
                overlayKind: linkedCameraID != nil ? .haCamera : nil,
                overlayPayload: linkedCameraID)
            ProactivityOrchestrator.shared.providerPublish(signal: signal)
            appState.haLastAlertDescription = alertPhrase
        }

        // ── Camera live-view activation (e.g. camera.front_door_live_view idle→streaming) ──
        let isCameraActivation = entityId.hasPrefix("camera.")
            && (newState == "streaming" || newState == "recording" || newState == "detecting")
            && (oldState == "idle" || oldState == nil)

        if isCameraActivation && settings.haDoorbellAlertsEnabled {
            let alertPhrase = prefs.current.haDoorbellPhrase
            let cooldown = max(prefs.current.haMotionCooldownSeconds, 30)
            guard motionMapper?.canAlert(entityID: entityId, cooldownSeconds: cooldown) ?? true else { return }
            guard motionMapper?.canGlobalAlert(cooldownSeconds: prefs.current.haGlobalAlertCooldownSeconds) ?? true else { return }
            motionMapper?.recordAlert(entityID: entityId)
            SystemBus.shared.publish(HAMotionDetectedEvent(
                sensorEntityID: entityId,
                linkedCameraID: entityId,
                isDoorbellEvent: true,
                alertPhrase: alertPhrase))
            // Unified with the binary_sensor doorbell emitter above so a single
            // press does not produce two alerts. See sharedDoorbellDedupeKey.
            let windowKey = Self.sharedDoorbellDedupeKey(cooldown: cooldown)
            let signal = ProactivitySignal(
                source: .homeAssistant,
                title: "Doorbell",
                body: alertPhrase,
                category: "ha_doorbell",
                priority: .urgent,
                dedupeKey: windowKey,
                spokenText: alertPhrase,
                requiresAttention: true,
                overlayKind: .haCamera,
                overlayPayload: entityId)
            ProactivityOrchestrator.shared.providerPublish(signal: signal)
            appState.haLastAlertDescription = alertPhrase
        }

        // ── Safety sensors (smoke / CO / water / gas) — always fires regardless of settings ──
        if settings.haSensorsEnabled {
            let isSafety = ["smoke", "carbon_monoxide", "moisture", "gas"].contains(deviceClass)
            let isTriggered = newState == "on" || newState == "detected"
            let wasTriggered = oldState == "on" || oldState == "detected"

            if isSafety && isTriggered && !wasTriggered {
                let alertType: String
                switch deviceClass {
                case "smoke":            alertType = "SMOKE DETECTED"
                case "carbon_monoxide":  alertType = "CARBON MONOXIDE DETECTED"
                case "moisture":         alertType = "Water leak detected"
                case "gas":              alertType = "GAS DETECTED"
                default:                 alertType = "Alert"
                }
                // Drop `newState` from the dedup key — different HA integrations
                // report rising-edge as "on" vs "detected", which previously
                // generated two distinct keys for the SAME physical event.  Add
                // a coarse 30-minute bucket so a genuine re-trigger half an hour
                // later still fires as a new alert (life-safety alerts must not
                // be permanently dedup'd by `announcedKeys`).
                let bucket = Int(Date().timeIntervalSince1970 / 1800)
                let key = "ha.safety.\(entityId).\(bucket)"
                let signal = ProactivitySignal(
                    source: .homeAssistant,
                    title: alertType,
                    body: "\(alertType) by \(friendlyName).",
                    category: "ha.safety",
                    priority: .critical,
                    dedupeKey: key,
                    spokenText: "\(alertType) — \(friendlyName)!",
                    requiresAttention: true)
                ProactivityOrchestrator.shared.providerPublish(signal: signal)
            }
        }

        // ── Device offline ────────────────────────────────────────────────────
        if settings.haDeviceOfflineEnabled,
           newState == "unavailable", oldState != "unavailable" {

            let key = "ha.offline.\(entityId)"
            let signal = ProactivitySignal(
                source: .homeAssistant,
                title: "\(friendlyName) offline",
                body: "\(friendlyName) is no longer reachable.",
                category: "ha.offline",
                priority: .low,
                dedupeKey: key,
                spokenText: "\(friendlyName) has gone offline.")
            ProactivityOrchestrator.shared.providerPublish(signal: signal)
        }

        // ── Alarm control panel ───────────────────────────────────────────────
        if entityId.hasPrefix("alarm_control_panel") {
            let spokenMap: [String: String] = [
                "triggered":   "Alarm triggered!",
                "disarmed":    "Alarm disarmed.",
                "armed_away":  "Alarm armed — away mode.",
                "armed_home":  "Alarm armed — home mode.",
            ]
            if let spoken = spokenMap[newState] {
                let priority: SignalPriority = newState == "triggered" ? .critical : .normal
                let key = "ha.alarm.\(entityId).\(newState)"
                let signal = ProactivitySignal(
                    source: .homeAssistant,
                    title: "\(friendlyName): \(newState)",
                    body: spoken,
                    category: "ha.alarm",
                    priority: priority,
                    dedupeKey: key,
                    spokenText: spoken,
                    requiresAttention: priority == .critical)
                ProactivityOrchestrator.shared.providerPublish(signal: signal)
            }
        }
    }

    // MARK: - Deferred open/unlocked alert helper

    /// Schedules an alert to fire after 10 minutes if the entity is still
    /// open/unlocked at that point. Replaces the old synchronous elapsed-time
    /// check, which could never fire because HA only sends `state_changed` on
    /// transitions (not repeatedly while open).
    private func scheduleOpenAlert(entityId: String,
                                   alertKey: String,
                                   title: String,
                                   body: String,
                                   category: String,
                                   spokenText: String) {
        openAlertTasks[alertKey]?.cancel()
        openAlertTasks[alertKey] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))  // 10 minutes
            guard !Task.isCancelled else { return }
            guard let self,
                  self.openSince[entityId] != nil,          // still open/unlocked
                  !self.emittedOpenAlerts.contains(alertKey) // not already announced
            else { return }
            self.emittedOpenAlerts.insert(alertKey)
            let signal = ProactivitySignal(
                source: .homeAssistant,
                title: title,
                body: body,
                category: category,
                priority: .high,
                dedupeKey: alertKey,
                spokenText: spokenText)
            ProactivityOrchestrator.shared.providerPublish(signal: signal)
        }
    }
}
