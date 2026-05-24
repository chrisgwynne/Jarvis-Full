import Foundation
import Network
import OSLog

/// Connects the Mac app to the daemon's `/v1/mac/ws` endpoint.
/// Receives routed messages (Android/Windows transcripts, tool results, etc.)
/// and dispatches them to registered handlers.
@MainActor
final class DaemonAppBridge: ObservableObject {
    static let shared = DaemonAppBridge()

    private let logger = Logger(subsystem: "com.jarvis.jarvisapp", category: "daemonbridge")

    @Published var isConnected = false
    @Published var lastReceivedType: String = ""
    @Published var reconnectAttempts: Int = 0

    private var connection: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    /// Called when a transcript.final arrives from Android/Windows via the daemon.
    /// Parameters: (transcript, sourceDeviceId, sourcePlatform)
    var onTranscript: ((String, String, String) -> Void)?
    /// Called when a tool.result arrives.
    var onToolResult: ((Data) -> Void)?
    /// Called when an android.event arrives from the Android app via the daemon.
    /// Parameters: (command, payloadData, sourceDeviceId)
    /// The payloadData contains the `data` sub-object from the android.event payload,
    /// serialised as JSON and ready for AndroidEventReceiver ingestion.
    var onAndroidEvent: ((String, Data, String) -> Void)?

    private var authToken: String? {
        Keychain.get(KeychainAccount.gatewayToken)
    }

    // MARK: - Connect / disconnect

    func connect() {
        guard let token = authToken else {
            logger.warning("DaemonAppBridge: no auth token — cannot connect to daemon")
            return
        }
        disconnect()

        guard var comps = URLComponents(string: "ws://127.0.0.1:8765/v1/mac/ws") else { return }
        comps.scheme = "ws"
        guard let url = comps.url else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("mac", forHTTPHeaderField: "X-Platform")

        let session = URLSession.shared
        let task = session.webSocketTask(with: request)
        self.connection = task
        task.resume()
        isConnected = true
        reconnectAttempts = 0
        logger.info("DaemonAppBridge: connected to daemon")

        receive()
        startPing()
    }

    func disconnect() {
        pingTask?.cancel(); pingTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        connection?.cancel(with: .normalClosure, reason: nil)
        connection = nil
        isConnected = false
    }

    // MARK: - Send

    func send(_ envelope: [String: Any]) {
        guard let conn = connection,
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: data, encoding: .utf8) else { return }
        conn.send(.string(text)) { [weak self] error in
            if let err = error {
                self?.logger.warning("DaemonAppBridge send error: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - Receive loop

    private func receive() {
        connection?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleText(text)
                    }
                @unknown default: break
                }
                self.receive()  // continue loop
            case .failure(let error):
                self.logger.warning("DaemonAppBridge receive error: \(error.localizedDescription)")
                Task { @MainActor in
                    self.isConnected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""
        Task { @MainActor in
            self.lastReceivedType = type
        }
        let payload = json["payload"] as? [String: Any] ?? [:]
        let deviceId = json["sourceDeviceId"] as? String ?? ""
        let platform = json["sourcePlatform"] as? String ?? "android"

        switch type {
        case "transcript.final":
            // Android sends text under "text" key; legacy Mac frames used "transcript".
            let transcript = payload["text"] as? String
                          ?? payload["transcript"] as? String
                          ?? ""
            if !transcript.isEmpty {
                Task { @MainActor in self.onTranscript?(transcript, deviceId, platform) }
            }
        // Canonical execution result type (Phase P9)
        case "execution.result":
            onToolResult?(data)
        // Legacy result names — kept for backward compat; log in debug builds only
        case "tool.result", "command.result":
            logger.debug("DaemonAppBridge: deprecated type=\(type, privacy: .public) — update Android to use execution.result")
            onToolResult?(data)
        case "android.event":
            // Phone/device event from Android — route to AndroidEventReceiver.
            let command = payload["command"] as? String ?? ""
            let eventData = payload["data"] as? [String: Any] ?? [:]
            if !command.isEmpty,
               let serialised = try? JSONSerialization.data(withJSONObject: eventData) {
                Task { @MainActor in self.onAndroidEvent?(command, serialised, deviceId) }
            }
        case "nack":
            let reason = payload["reason"] as? String ?? ""
            logger.debug("DaemonAppBridge: nack reason=\(reason, privacy: .public)")
        case "execution.result":
            // Result of a Mac-initiated capability request — route as tool.result.
            onToolResult?(data)
        default:
            logger.debug("DaemonAppBridge: received type=\(type, privacy: .public)")
        }
    }

    private func startPing() {
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                connection?.sendPing { _ in }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempts += 1

        // Clear any pending Android tool executions — when the daemon connection drops,
        // we cannot know if the Android device received the execution.request or whether
        // it will ever reply.  Clearing prevents orphaned CheckedContinuation leaks.
        // Callers receive a timeout result immediately rather than waiting up to 15s.
        Task { @MainActor in
            AndroidToolOrchestrator.shared.clearPending(reason: .daemonRestart)
        }

        let delay = min(Double(reconnectAttempts) * 2, 30)
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { self.connect() }
        }
    }

    // MARK: - Sending replies to remote devices

    func sendReply(text: String, speak: Bool, display: Bool, routeId: String,
                   targetPlatform: String, targetDeviceId: String) {
        let envelope: [String: Any] = [
            "id": UUID().uuidString,
            "type": "reply.final",
            "sourceDeviceId": "mac",
            "sourcePlatform": "mac",
            "target": ["type": targetPlatform, "deviceId": targetDeviceId],
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "correlationId": routeId,
            "payload": [
                "text": text,
                "speak": speak,
                "display": display,
                "routeId": routeId,
                "source": "mac.brain"
            ]
        ]
        send(envelope)
    }

    func sendCommandResult(text: String, intentLabel: String, routeId: String,
                           targetPlatform: String, targetDeviceId: String) {
        let envelope: [String: Any] = [
            "id": UUID().uuidString,
            "type": "command.result",
            "sourceDeviceId": "mac",
            "sourcePlatform": "mac",
            "target": ["type": targetPlatform, "deviceId": targetDeviceId],
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "correlationId": routeId,
            "payload": ["text": text, "intentLabel": intentLabel, "routeId": routeId]
        ]
        send(envelope)
    }

    func sendErrorReport(reason: String, routeId: String,
                         targetPlatform: String, targetDeviceId: String) {
        let envelope: [String: Any] = [
            "id": UUID().uuidString,
            "type": "error.report",
            "sourceDeviceId": "mac",
            "sourcePlatform": "mac",
            "target": ["type": targetPlatform, "deviceId": targetDeviceId],
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "correlationId": routeId,
            "payload": ["reason": reason, "source": "mac.brain"]
        ]
        send(envelope)
    }
}
