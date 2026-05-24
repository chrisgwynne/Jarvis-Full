import Foundation

/// Thin wrapper around URLSessionWebSocketTask that speaks the HA WebSocket
/// auth + event-subscription protocol.
///
/// Usage:
/// ```swift
/// let client = HomeAssistantWebSocketClient(baseURL: "http://192.168.1.20:8123", token: "…")
/// client.onEvent = { event in … }
/// client.connect()
/// ```
@MainActor
final class HomeAssistantWebSocketClient {

    // MARK: - Event type

    enum HAWSEvent {
        case stateChanged(entityId: String, newState: String, oldState: String?, attributes: [String: Any])
        case connected
        case disconnected(Error?)
    }

    // MARK: - Private state

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var msgId = 1
    private var pingTask: Task<Void, Never>?

    // MARK: - Public

    let baseURL: String
    let token: String

    var onEvent: ((HAWSEvent) -> Void)?

    init(baseURL: String, token: String) {
        self.baseURL = baseURL
        self.token   = token
    }

    // MARK: - Connect / disconnect

    func connect() {
        // Convert http:// → ws://  and  https:// → wss://
        let wsURL = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://",  with: "ws://")
        guard let url = URL(string: "\(wsURL)/api/websocket") else {
            Log.app.warning("[ha-ws] Invalid URL: \(wsURL, privacy: .public)/api/websocket")
            return
        }

        let cfg = URLSessionConfiguration.default
        urlSession = URLSession(configuration: cfg)
        task = urlSession?.webSocketTask(with: url)
        task?.resume()
        Log.app.info("[ha-ws] Connecting to \(url.absoluteString, privacy: .public)")
        receiveLoop()
        startPingLoop()
    }

    func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        msgId = 1
    }

    // MARK: - Ping / keep-alive

    /// Sends a WebSocket ping every 30 s so NAT routers don't silently drop
    /// the idle connection (many home routers expire TCP sessions after 30–120 s).
    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.task?.sendPing { error in
                        if let error {
                            Log.app.debug("[ha-ws] Ping failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Internal receive loop

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Task { @MainActor [weak self] in
                    Log.app.warning("[ha-ws] Receive error: \(error.localizedDescription, privacy: .public)")
                    self?.onEvent?(.disconnected(error))
                }
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s):       text = s
                case .data(let d):         text = String(data: d, encoding: .utf8)
                @unknown default:          text = nil
                }
                if let text {
                    Task { @MainActor [weak self] in self?.handleMessage(text) }
                }
                // Continue reading regardless of parse success
                self.receiveLoop()
            }
        }
    }

    // MARK: - Send

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error {
                Log.app.warning("[ha-ws] Send error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Message handler

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type_ = json["type"] as? String else { return }

        switch type_ {
        case "auth_required":
            Log.app.debug("[ha-ws] Auth required — sending token")
            send(["type": "auth", "access_token": token])

        case "auth_ok":
            Log.app.info("[ha-ws] Auth OK — subscribing to state_changed")
            send(["id": msgId, "type": "subscribe_events", "event_type": "state_changed"])
            msgId += 1
            onEvent?(.connected)

        case "auth_invalid":
            Log.app.error("[ha-ws] Auth invalid — check HA long-lived access token")
            onEvent?(.disconnected(nil))

        case "event":
            guard
                let event     = json["event"] as? [String: Any],
                let eventData = event["data"]  as? [String: Any],
                let entityId  = eventData["entity_id"] as? String,
                let newStateObj = eventData["new_state"] as? [String: Any],
                let newState  = newStateObj["state"] as? String
            else { return }

            let oldState   = (eventData["old_state"] as? [String: Any])?["state"] as? String
            let attributes = newStateObj["attributes"] as? [String: Any] ?? [:]
            onEvent?(.stateChanged(entityId: entityId,
                                   newState: newState,
                                   oldState: oldState,
                                   attributes: attributes))

        default:
            break
        }
    }
}
