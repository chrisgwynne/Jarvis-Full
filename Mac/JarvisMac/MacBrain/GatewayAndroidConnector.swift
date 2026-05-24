import Foundation
import Network

// MARK: - GatewayAndroidConnector
//
// Accepts NWConnections that have been HTTP-upgraded to WebSocket by MacBrainServer
// on the /v1/android/ws route.  Handles WebSocket framing manually (same approach
// as MacBridgeProtocolV2 for the Windows sidecar).
//
// AndroidBridgeManager calls `gatewayAndroidConnector.broadcast(_:)` to push to
// Android, and wires `onMessage` to receive inbound Android frames.

@MainActor
final class GatewayAndroidConnector {

    // MARK: - Client

    private struct WSClient {
        let id: String
        var deviceId: String
        let conn: NWConnection
    }

    private var clients: [String: WSClient] = [:]
    private let networkQueue = DispatchQueue(label: "com.jarvis.gateway.android.ws", qos: .utility)

    // MARK: - Diagnostics back-reference (set by MacBrainServer)
    weak var diagnostics: GatewayDiagnostics?

    // MARK: - Callbacks

    /// Called for every complete inbound WebSocket text/binary frame from Android.
    /// The respond closure pushes a reply back to that specific client.
    var onMessage: ((Data, @escaping (Data) -> Void) -> Void)?

    // MARK: - Accept a new WebSocket connection (called by MacBrainServer after upgrade)

    func acceptConnection(_ conn: NWConnection, clientId: String = UUID().uuidString) {
        let client = WSClient(id: clientId, deviceId: clientId, conn: conn)
        clients[clientId] = client
        updateDiagnostics()
        receiveLoop(clientId: clientId, conn: conn)
    }

    // MARK: - Outbound

    func broadcast(_ data: Data) {
        let frame = encodeTextFrame(String(data: data, encoding: .utf8) ?? "")
        networkQueue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values {
                client.conn.send(content: frame, completion: .contentProcessed { _ in })
            }
        }
    }

    func send(_ data: Data, to clientId: String) {
        guard let client = clients[clientId] else { return }
        let frame = encodeTextFrame(String(data: data, encoding: .utf8) ?? "")
        networkQueue.async {
            client.conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    var connectedCount: Int { clients.count }

    // MARK: - Receive loop

    private func receiveLoop(clientId: String, conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if let error {
                _ = error // suppress unused warning
                Task { @MainActor [weak self] in self?.removeClient(id: clientId) }
                return
            }
            if let data, !data.isEmpty {
                let bytes = Array(data)
                if let text = Self.parseFrame(bytes) {
                    let frameData = Data(text.utf8)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.diagnostics?.recordAndroidSeen()
                        GatewayAuthStore.shared.recordSeen(deviceId: clientId)
                        self.onMessage?(frameData) { [weak self] reply in
                            self?.send(reply, to: clientId)
                        }
                    }
                } else if bytes.count >= 2 && (bytes[0] & 0x0F) == 8 {
                    // Close frame
                    Task { @MainActor [weak self] in self?.removeClient(id: clientId) }
                    return
                }
            }
            if isComplete {
                Task { @MainActor [weak self] in self?.removeClient(id: clientId) }
            } else {
                self.receiveLoop(clientId: clientId, conn: conn)
            }
        }
    }

    private func removeClient(id: String) {
        clients[id]?.conn.cancel()
        clients.removeValue(forKey: id)
        updateDiagnostics()
    }

    private func updateDiagnostics() {
        diagnostics?.connectedAndroidDevices = clients.count
        diagnostics?.activeWebSocketClients = clients.count
    }

    // MARK: - WebSocket frame codec (RFC 6455)
    // Ported from MacBridgeProtocolV2 — server-to-client frames are unmasked,
    // client-to-server frames are masked (Android SDK does this automatically).

    static func parseFrame(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        guard opcode == 1 || opcode == 2 else { return nil }  // text or binary
        let masked = (bytes[1] & 0x80) != 0
        var payloadLen = Int(bytes[1] & 0x7F)
        var offset = 2
        if payloadLen == 126 {
            guard bytes.count >= 4 else { return nil }
            payloadLen = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if payloadLen == 127 {
            guard bytes.count >= 10 else { return nil }
            payloadLen = 0
            for i in 2..<10 { payloadLen = payloadLen << 8 | Int(bytes[i]) }
            offset = 10
        }
        var maskKey = [UInt8](repeating: 0, count: 4)
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<offset+4])
            offset += 4
        }
        guard bytes.count >= offset + payloadLen else { return nil }
        var payload = Array(bytes[offset..<offset+payloadLen])
        if masked { for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] } }
        return String(bytes: payload, encoding: .utf8)
    }

    func encodeTextFrame(_ text: String) -> Data {
        let payload = Array(text.utf8)
        var frame: [UInt8] = [0x81]  // FIN + text opcode
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((payload.count >> (i*8)) & 0xFF)) }
        }
        frame.append(contentsOf: payload)
        return Data(frame)
    }
}
