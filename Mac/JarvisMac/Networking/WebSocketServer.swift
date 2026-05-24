import Foundation
import Network

/// Local WebSocket server built on Network.framework. No third-party deps.
/// Bind failures are reported to the delegate but never thrown upward —
/// the rest of the app keeps running.
///
/// Phase-2: every frame is JSON-decoded and the optional `auth` field is
/// compared against the configured shared secret before any side effect.
/// Auth is enforced only when `requireAuth` is true.
final class WebSocketServer {

    protocol Delegate: AnyObject {
        func server(_ server: WebSocketServer, didChangeStatus status: DeviceStatus)
        func server(_ server: WebSocketServer, didChangeClients count: Int)
        func server(_ server: WebSocketServer,
                    didReceive data: Data,
                    respond: @escaping (Data) -> Void)
    }

    weak var delegate: Delegate?

    /// Hard ceiling on a single inbound frame.  Frames larger than this are
    /// dropped before the delegate is invoked — protection against memory
    /// exhaustion via a malicious or buggy client.  Legitimate Jarvis frames
    /// are well under 16 KB; 64 KB is generous headroom.
    static let maxInboundFrameBytes = 64 * 1024

    weak var jarvisDelegate: Delegate? { delegate }

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.jarvis.mac.ws")

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 17872
    }

    func start() {
        stop() // idempotent

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let params = NWParameters(tls: nil)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            let listener = try NWListener(using: params, on: port)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.delegate?.server(self, didChangeStatus: .ready)
                case .failed(let err):
                    self.delegate?.server(self, didChangeStatus: .failed(err.localizedDescription))
                case .cancelled:
                    self.delegate?.server(self, didChangeStatus: .unavailable("Stopped"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: queue)
        } catch {
            delegate?.server(self, didChangeStatus: .failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
        delegate?.server(self, didChangeClients: 0)
    }

    func broadcast(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "broadcast",
                                                  metadata: [metadata])
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.connections.values {
                conn.send(content: data,
                          contentContext: context,
                          isComplete: true,
                          completion: .contentProcessed { _ in })
            }
        }
    }

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        delegate?.server(self, didChangeClients: connections.count)

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                self.receive(on: conn)
            case .failed, .cancelled:
                self.connections.removeValue(forKey: ObjectIdentifier(conn))
                self.delegate?.server(self, didChangeClients: self.connections.count)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, context, _, error in
            guard let self, let conn else { return }
            if let error {
                Log.net.error("ws receive: \(error.localizedDescription)")
                conn.cancel()
                return
            }
            if let data,
               let metadata = context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .text || metadata.opcode == .binary {
                // Defensive frame-size cap — drop oversized frames before any
                // decode work or delegate dispatch.  Logs once per drop so a
                // chatty bad client is visible in diagnostics.
                if data.count > WebSocketServer.maxInboundFrameBytes {
                    Log.net.warning("ws: dropped oversized frame \(data.count)B (cap \(WebSocketServer.maxInboundFrameBytes)B)")
                } else {
                    self.delegate?.server(self, didReceive: data) { reply in
                        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                        let ctx = NWConnection.ContentContext(identifier: "reply",
                                                              metadata: [meta])
                        conn.send(content: reply,
                                  contentContext: ctx,
                                  isComplete: true,
                                  completion: .contentProcessed { _ in })
                    }
                }
            }
            self.receive(on: conn)
        }
    }
}
