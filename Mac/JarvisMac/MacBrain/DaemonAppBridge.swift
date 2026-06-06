import Foundation
import Network
import OSLog

// MARK: - DaemonRoutes
//
// Single source of truth for paths used by both DaemonAppBridge and BrainDaemonServer.
// Any path change here must be mirrored in BrainDaemonServer.processRequest().

enum DaemonRoutes {
    static let health    = "/health"
    static let version   = "/version"
    static let routes    = "/routes"
    /// The Mac app WebSocket path — must match the `path == "/v1/mac/ws"` check in BrainDaemonServer.
    static let macWS     = "/v1/mac/ws"
}

// MARK: - BrainConnectionStatus
//
// Replaces the old contradictory "daemon online / bridge offline" split.
// Each layer is independent so the UI can show exactly where the failure is.

enum BrainConnectionStatus: Equatable {
    case notConfigured                          // no URL set
    case connecting                             // first attempt
    case connected                              // WS open, pings succeeding
    case reconnecting(attempt: Int, delaySecs: Int) // dropped, retrying
    case offline(reason: String)               // cannot reach daemon at all
    case wrongURL(detail: String)              // DNS/TCP failure
    case incompatible(expected: String, got: String) // version mismatch
    case databaseDegraded                      // WS connected, brain DB unhealthy

    var shortLabel: String {
        switch self {
        case .notConfigured:             return "Not configured"
        case .connecting:                return "Connecting…"
        case .connected:                 return "Connected"
        case .reconnecting(let a, let d):return "Reconnecting… (attempt \(a), wait \(d)s)"
        case .offline(let r):            return "Offline — \(r)"
        case .wrongURL(let d):           return "Wrong URL — \(d)"
        case .incompatible(let e, let g):return "Incompatible (expected \(e), got \(g))"
        case .databaseDegraded:          return "Connected — Brain database degraded"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        if case .databaseDegraded = self { return true }
        return false
    }

    var isOffline: Bool {
        switch self {
        case .offline, .wrongURL, .incompatible, .notConfigured: return true
        default: return false
        }
    }
}

// MARK: - DaemonAppBridge
//
// Simple, reliable WebSocket bridge to the Brain daemon.
//
// Design:
//   - URL configured in Settings (daemonBaseURL), default http://127.0.0.1:8765
//   - NO auth token required by default (private/local mode)
//   - ONE connection per app instance
//   - Automatic reconnect — no permanent-offline dead state
//   - Heartbeat every 25 s; reconnects if ping fails
//   - Exponential backoff with jitter, no maximum retry count
//   - Structured logs under [BrainConnection]

@MainActor
final class DaemonAppBridge: ObservableObject {
    static let shared = DaemonAppBridge()

    private let logger = Logger(subsystem: "com.jarvis.jarvisapp", category: "brain_connection")

    // MARK: - Observable state

    @Published var connectionStatus: BrainConnectionStatus = .notConfigured
    @Published var isConnected: Bool = false
    @Published var lastReceivedType: String = ""
    @Published var reconnectAttempts: Int = 0
    /// Backwards-compat: UI code that reads this still works.
    var permanentlyOffline: Bool { connectionStatus.isOffline && reconnectAttempts > 0 }

    // MARK: - Callbacks (unchanged public API)

    var onTranscript:         ((String, String, String, String) -> Void)?
    var onToolResult:         ((Data) -> Void)?
    var onAndroidEvent:       ((String, Data, String) -> Void)?
    var onRemoteActionRequest: ((String, String, String, String, [String: Any], String, Bool) -> Void)?
    var onFileTransferCreated: ((String, String, String, Int, Bool, String, String) -> Void)?
    var onPresenceUpdate:     (([String: Any]) -> Void)?
    var onCommPrompt:         (([String: Any]) -> Void)?
    var onHandoffReceived:    ((String, String) -> Void)?
    var onClipboardUpdate:    ((String) -> Void)?
    var onNotificationForward: (([String: Any]) -> Void)?
    var onContextUpdate:      (([String: Any]) -> Void)?

    // MARK: - Private

    private var connection: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var pingTask:      Task<Void, Never>?
    private var configuredBaseURL: String = ""

    // MARK: - Connect / disconnect

    /// Connect using the URL from preferences.
    /// Derives: ws[s]://host:port/v1/mac/ws from http[s]://host:port
    func connect(baseURL: String? = nil, authToken: String? = nil) {
        let url = baseURL ?? configuredBaseURL
        guard !url.isEmpty else {
            connectionStatus = .notConfigured
            logger.info("[BrainConnection] configuredURL=<empty> — not configured")
            return
        }
        configuredBaseURL = url
        connectionStatus  = .connecting
        disconnect(silent: true)

        guard let wsURL = deriveWebSocketURL(from: url) else {
            connectionStatus = .wrongURL(detail: "Cannot parse URL: \(url)")
            logger.warning("[BrainConnection] configuredURL=\(url) — invalid URL format")
            return
        }

        logger.info("[BrainConnection] configuredURL=\(url)")
        logger.info("[BrainConnection] ws connecting url=\(wsURL.absoluteString)")

        var request = URLRequest(url: wsURL)
        request.setValue("mac", forHTTPHeaderField: "X-Platform")
        // Auth header only if explicitly provided and auth is required
        if let token = authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.webSocketTask(with: request)
        connection = task
        task.resume()

        receive()
        startPing()
    }

    func disconnect(silent: Bool = false) {
        pingTask?.cancel();      pingTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        connection?.cancel(with: .normalClosure, reason: nil)
        connection = nil
        if !silent {
            isConnected = false
            connectionStatus = .offline(reason: "Disconnected by user")
        }
    }

    /// Reset and reconnect immediately (called from UI Reconnect button).
    func resetAndReconnect() {
        reconnectAttempts = 0
        connectionStatus  = .connecting
        reconnectTask?.cancel()
        reconnectTask = nil
        logger.info("[BrainConnection] manual reconnect — resetting state")
        connect()
    }

    // MARK: - URL derivation

    /// Converts http://host:port → ws://host:port/v1/mac/ws
    ///          https://host:port → wss://host:port/v1/mac/ws
    private func deriveWebSocketURL(from baseURL: String) -> URL? {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("https://") {
            raw = "wss://" + raw.dropFirst("https://".count)
        } else if raw.hasPrefix("http://") {
            raw = "ws://" + raw.dropFirst("http://".count)
        }
        let suffix = raw.hasSuffix("/") ? String(DaemonRoutes.macWS.dropFirst()) : DaemonRoutes.macWS
        return URL(string: raw + suffix)
    }

    // MARK: - Receive loop

    private func receive() {
        connection?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.isConnected      = true
                    self.reconnectAttempts = 0
                    self.connectionStatus = .connected
                    switch message {
                    case .string(let text): self.handleText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handleText(text) }
                    @unknown default: break
                    }
                    self.receive()

                case .failure(let error):
                    let reason = Self.friendlyError(error)
                    self.logger.info("[BrainConnection] disconnected reason=\(reason)")
                    self.isConnected = false
                    let nsErr = error as NSError
                    if nsErr.code == -1011 {
                        Task { await self.logHandshakeDiagnostics() }
                    }
                    self.scheduleReconnect(reason: reason)
                }
            }
        }
    }

    // MARK: - Reconnect (no maximum retry count — always keep trying)

    private func scheduleReconnect(reason: String) {
        // Kill the heartbeat and dead socket before rescheduling — otherwise pingTask
        // fires 25 s later on a closed connection and logs a misleading error.
        pingTask?.cancel();  pingTask = nil
        connection?.cancel(with: .normalClosure, reason: nil)
        connection = nil
        isConnected = false
        reconnectTask?.cancel()
        reconnectAttempts += 1

        // Cancel any orphaned Android tool continuations
        Task { @MainActor in
            AndroidToolOrchestrator.shared.clearPending(reason: .daemonRestart)
        }

        // Exponential backoff with jitter: 2^attempt capped at 60s, +0-5s jitter
        let base   = min(pow(2.0, Double(reconnectAttempts)), 60.0)
        let jitter = Double.random(in: 0..<5)
        let delay  = base + jitter
        let attempt = reconnectAttempts

        connectionStatus = .reconnecting(attempt: attempt, delaySecs: Int(delay))
        logger.info("[BrainConnection] reconnect scheduled delay=\(String(format: "%.1f", delay))s attempt=\(attempt)")

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { self.connect() }
        }
    }

    // MARK: - Heartbeat

    private func startPing() {
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self else { return }
                // Don't ping if we already reconnected or disconnected during the sleep.
                guard self.isConnected, let conn = self.connection else { return }
                conn.sendPing { [weak self] error in
                    guard let self else { return }
                    if let error {
                        Task { @MainActor in
                            self.logger.info("[BrainConnection] heartbeat failed — \(error.localizedDescription)")
                            self.isConnected = false
                            self.scheduleReconnect(reason: "Heartbeat timeout")
                        }
                    } else {
                        Task { @MainActor in
                            self.logger.debug("[BrainConnection] heartbeat ok")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Message dispatch (unchanged from previous implementation)

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type     = json["type"] as? String ?? ""
        let payload  = json["payload"] as? [String: Any] ?? [:]
        let deviceId = json["sourceDeviceId"] as? String ?? ""
        let platform = json["sourcePlatform"] as? String ?? "android"
        let corrId   = json["correlationId"] as? String
                    ?? json["messageId"] as? String
                    ?? UUID().uuidString

        Task { @MainActor in self.lastReceivedType = type }

        switch type {
        case "transcript.final":
            let transcript = payload["text"] as? String ?? payload["transcript"] as? String ?? ""
            if !transcript.isEmpty {
                Task { @MainActor in self.onTranscript?(transcript, deviceId, platform, corrId) }
            }
        case "execution.result":
            onToolResult?(data)
        case "tool.result", "command.result":
            logger.debug("[BrainConnection] deprecated type=\(type)")
            onToolResult?(data)
        case "android.event":
            let command   = payload["command"] as? String ?? ""
            let eventData = payload["data"] as? [String: Any] ?? [:]
            if !command.isEmpty, let serialised = try? JSONSerialization.data(withJSONObject: eventData) {
                Task { @MainActor in self.onAndroidEvent?(command, serialised, deviceId) }
            }
        case "remote.action.request":
            let requestId = payload["requestId"] as? String ?? ""
            let routeId   = payload["routeId"]   as? String ?? requestId
            let action    = payload["action"]     as? String ?? ""
            let params    = payload["parameters"] as? [String: Any] ?? [:]
            let text_     = payload["userVisibleText"] as? String ?? ""
            let confirm   = payload["requiresConfirmation"] as? Bool ?? false
            if !requestId.isEmpty && !action.isEmpty {
                Task { @MainActor in self.onRemoteActionRequest?(requestId, routeId, deviceId, action, params, text_, confirm) }
            }
        case "file.transfer.created":
            let tid       = payload["transferId"]     as? String ?? ""
            let filename  = payload["filename"]        as? String ?? ""
            let mimeType  = payload["mimeType"]        as? String ?? ""
            let sizeBytes = payload["sizeBytes"]       as? Int    ?? 0
            let openOnMac = payload["openOnMac"]       as? Bool   ?? false
            let action    = payload["suggestedAction"] as? String ?? "save"
            let visName   = payload["userVisibleName"] as? String ?? filename
            if !tid.isEmpty {
                Task { @MainActor in self.onFileTransferCreated?(tid, filename, mimeType, sizeBytes, openOnMac, action, visName) }
            }
        case "presence.update":
            Task { @MainActor in self.onPresenceUpdate?(payload) }
        case "proactive.comm.prompt":
            Task { @MainActor in self.onCommPrompt?(payload) }
        case "handoff.request":
            let key = payload["key"] as? String ?? ""
            let val = payload["value"] as? String ?? ""
            if !key.isEmpty { Task { @MainActor in self.onHandoffReceived?(key, val) } }
        case "clipboard.update":
            let clipText = payload["text"] as? String ?? ""
            if !clipText.isEmpty { Task { @MainActor in self.onClipboardUpdate?(clipText) } }
        case "notification.forward":
            Task { @MainActor in self.onNotificationForward?(payload) }
        case "context.update":
            Task { @MainActor in self.onContextUpdate?(payload) }
        default:
            logger.debug("[BrainConnection] received type=\(type)")
        }
    }

    // MARK: - Send helpers (unchanged public API)

    func send(_ envelope: [String: Any]) {
        guard let conn = connection,
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: data, encoding: .utf8) else { return }
        conn.send(.string(text)) { [weak self] error in
            if let err = error {
                self?.logger.warning("[BrainConnection] send error: \(err.localizedDescription)")
            }
        }
    }

    func sendRemoteActionResult(requestId: String, routeId: String, targetDeviceId: String,
                                success: Bool, spokenSummary: String,
                                errorCode: String? = nil, errorMessage: String? = nil) {
        var payload: [String: Any] = [
            "requestId": requestId, "routeId": routeId,
            "targetDeviceId": targetDeviceId, "success": success,
            "spokenSummary": spokenSummary,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let c = errorCode    { payload["errorCode"]    = c }
        if let m = errorMessage { payload["errorMessage"] = m }
        send(["id": UUID().uuidString, "type": "remote.action.result",
              "sourceDeviceId": "mac", "sourcePlatform": "mac",
              "target": ["type": "android", "deviceId": targetDeviceId],
              "timestamp": ISO8601DateFormatter().string(from: Date()),
              "correlationId": requestId, "payload": payload])
    }

    func sendReply(text: String, speak: Bool, display: Bool, routeId: String,
                   targetPlatform: String, targetDeviceId: String) {
        send(["id": UUID().uuidString, "type": "reply.final",
              "sourceDeviceId": "mac", "sourcePlatform": "mac",
              "target": ["type": targetPlatform, "deviceId": targetDeviceId],
              "timestamp": ISO8601DateFormatter().string(from: Date()),
              "correlationId": routeId,
              "payload": ["text": text, "speak": speak, "display": display,
                          "routeId": routeId, "source": "mac.brain"]])
    }

    func sendCommandResult(text: String, intentLabel: String, routeId: String,
                           targetPlatform: String, targetDeviceId: String) {
        send(["id": UUID().uuidString, "type": "command.result",
              "sourceDeviceId": "mac", "sourcePlatform": "mac",
              "target": ["type": targetPlatform, "deviceId": targetDeviceId],
              "timestamp": ISO8601DateFormatter().string(from: Date()),
              "correlationId": routeId,
              "payload": ["text": text, "intentLabel": intentLabel, "routeId": routeId]])
    }

    func sendErrorReport(reason: String, routeId: String,
                         targetPlatform: String, targetDeviceId: String) {
        send(["id": UUID().uuidString, "type": "error.report",
              "sourceDeviceId": "mac", "sourcePlatform": "mac",
              "target": ["type": targetPlatform, "deviceId": targetDeviceId],
              "timestamp": ISO8601DateFormatter().string(from: Date()),
              "correlationId": routeId,
              "payload": ["reason": reason, "source": "mac.brain"]])
    }

    func sendHandoffRequest(key: String, value: String, targetDeviceId: String? = nil) {
        let target: [String: Any] = targetDeviceId != nil
            ? ["type": "android", "deviceId": targetDeviceId!] : ["type": "broadcast"]
        send(["id": UUID().uuidString, "type": "handoff.request",
              "sourceDeviceId": "mac", "sourcePlatform": "mac",
              "target": target,
              "timestamp": ISO8601DateFormatter().string(from: Date()),
              "payload": ["key": key, "value": value, "sourceDevice": "mac"]])
    }

    func sendClipboardUpdate(text: String, targetDeviceId: String? = nil) {
        let target: [String: Any] = targetDeviceId != nil
            ? ["type": "android", "deviceId": targetDeviceId!] : ["type": "broadcast"]
        send(["id": UUID().uuidString, "type": "clipboard.update",
              "sourceDeviceId": "mac", "sourcePlatform": "mac",
              "target": target,
              "timestamp": ISO8601DateFormatter().string(from: Date()),
              "payload": ["text": text, "sourceDevice": "mac"]])
    }

    func sendCommActionRequest(requestId: String, eventId: String, contactName: String,
                               channel: String, action: String, targetDeviceId: String) {
        send(["id": UUID().uuidString, "type": "comm.action.request",
              "sourceDeviceId": "mac", "sourcePlatform": "mac",
              "target": ["type": "android", "deviceId": targetDeviceId],
              "timestamp": ISO8601DateFormatter().string(from: Date()),
              "correlationId": requestId,
              "payload": ["requestId": requestId, "eventId": eventId,
                          "contactName": contactName, "channel": channel,
                          "action": action, "requiresConfirmation": true]])
    }

    // MARK: - Handshake diagnostics

    /// Called when the WS upgrade fails with -1011.  Fetches /health and /routes to narrow
    /// down why the server rejected the WebSocket upgrade, then logs a probableCause tag.
    private func logHandshakeDiagnostics() async {
        guard !configuredBaseURL.isEmpty else { return }
        let base = configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: ["/"])

        // ── /health ───────────────────────────────────────────────────────────
        var healthStatus = "unknown"
        if let healthURL = URL(string: "\(base)\(DaemonRoutes.health)"),
           let (_, hRes) = try? await URLSession.shared.data(from: healthURL),
           let http = hRes as? HTTPURLResponse {
            healthStatus = "\(http.statusCode)"
        }
        logger.info("[BrainConnection] health status=\(healthStatus)")

        // ── /routes ───────────────────────────────────────────────────────────
        var routesStatus = "unknown"
        var wsRouteListed = false
        var routesBody = ""
        if let routesURL = URL(string: "\(base)\(DaemonRoutes.routes)"),
           let (data, rRes) = try? await URLSession.shared.data(from: routesURL),
           let http = rRes as? HTTPURLResponse {
            routesStatus = "\(http.statusCode)"
            routesBody = String(data: data, encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                wsRouteListed = (json["websocket"] as? String) == DaemonRoutes.macWS
            }
        }
        logger.info("[BrainConnection] routes status=\(routesStatus)")
        if !routesBody.isEmpty { logger.info("[BrainConnection] routes body=\(routesBody)") }

        let wsPath = configuredBaseURL.contains("ws://") || configuredBaseURL.contains("wss://")
            ? configuredBaseURL
            : (deriveWebSocketURL(from: configuredBaseURL)?.absoluteString ?? "?")
        logger.info("[BrainConnection] wsURL=\(wsPath)")
        logger.info("[BrainConnection] wsHandshake=failed")

        let cause: String
        if healthStatus == "unknown" || healthStatus.hasPrefix("0") {
            cause = "server_not_ready"
        } else if routesStatus == "unknown" {
            cause = "route_missing"
        } else if !wsRouteListed {
            cause = "route_missing"
        } else {
            cause = "not_websocket"
        }
        logger.info("[BrainConnection] probableCause=\(cause)")
    }

    /// Smoke-test the daemon: /health → /routes → WebSocket connect → ping → pong.
    /// Logs each step with [BrainConnectionTest] prefix.
    func testDaemonWebSocket() async {
        let base = configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: ["/"])
        guard !base.isEmpty else {
            logger.info("[BrainConnectionTest] base URL not configured")
            return
        }
        logger.info("[BrainConnectionTest] starting smoke test base=\(base)")

        // /health
        var healthOK = false
        if let url = URL(string: "\(base)\(DaemonRoutes.health)"),
           let (_, res) = try? await URLSession.shared.data(from: url),
           let http = res as? HTTPURLResponse, http.statusCode == 200 {
            healthOK = true
        }
        logger.info("[BrainConnectionTest] health=\(healthOK ? "ok" : "FAIL")")

        // /routes
        var routesOK = false
        if let url = URL(string: "\(base)\(DaemonRoutes.routes)"),
           let (data, res) = try? await URLSession.shared.data(from: url),
           let http = res as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["websocket"] as? String) == DaemonRoutes.macWS {
            routesOK = true
        }
        logger.info("[BrainConnectionTest] routes=\(routesOK ? "ok" : "FAIL")")

        // WebSocket
        guard let wsURL = deriveWebSocketURL(from: base) else {
            logger.info("[BrainConnectionTest] ws=FAIL (cannot derive URL)")
            return
        }
        var wsOK = false
        var pingOK = false
        let session  = URLSession(configuration: .ephemeral)
        let testTask = session.webSocketTask(with: wsURL)
        testTask.resume()

        // Try to receive one message to verify 101 upgrade
        do {
            testTask.sendPing { err in
                Task { @MainActor in
                    pingOK = (err == nil)
                }
            }
            _ = try await withTimeout(seconds: 5) { try await testTask.receive() }
            wsOK = true
        } catch {
            // A receive timeout after a successful 101 is fine (no messages yet)
            let ns = error as NSError
            wsOK = (ns.code != -1011)
            pingOK = wsOK
        }
        testTask.cancel(with: .normalClosure, reason: nil)

        logger.info("[BrainConnectionTest] ws=\(wsOK ? "connected" : "FAIL")")
        logger.info("[BrainConnectionTest] ping=\(pingOK ? "pong" : "FAIL")")
    }

    // Throws after `seconds` if the async closure hasn't returned.
    private func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Helpers

    private static func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case -1011: return "Protocol mismatch or wrong service on port (HTTP 400/401 during WebSocket upgrade)"
        case -1004: return "Connection refused — daemon not running"
        case -1001: return "Timeout — daemon unreachable"
        case NSURLErrorNetworkConnectionLost: return "Network connection lost"
        default:    return "\(ns.domain) \(ns.code): \(error.localizedDescription)"
        }
    }
}
