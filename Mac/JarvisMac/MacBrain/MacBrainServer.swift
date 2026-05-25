import CryptoKit
import Foundation
import Network

/// Mac Brain HTTP server — camera and brain-context HTTP routes only.
///
/// In the daemon-centric architecture, JarvisBrainDaemon (port 8765) owns all
/// external WebSocket connections (Android /v1/android/ws, Windows /v2/ws) and
/// all device pairing. This server runs on port 8765 only when the daemon is
/// not present (legacy / standalone mode). When the daemon is running, this
/// server is not started.
///
/// Route table:
///
///   GET  /health          — liveness (no auth required)
///   GET  /brain/health    — alias for /health
///   GET  /v1/status       — gateway status (auth required)
///   GET  /v1/devices      — paired device list (auth required)
///   POST /v1/auth/rotate  — rotate gateway token (auth required)
///   GET  /v1/diagnostics  — diagnostics JSON (auth required)
///   GET|POST /camera/*    — camera streaming (MacCameraHttpRoutes)
///   POST /brain/context   — Brain context assembly (auth required)
///   POST /brain/interactions — Brain learning events (auth required)
final class MacBrainServer {

    private let networkQueue = DispatchQueue(label: "com.jarvis.mac.brain", qos: .utility)
    private var listener: NWListener?

    // Both @MainActor — only touched inside `Task { @MainActor in }` blocks.
    let diagnostics: GatewayDiagnostics
    private let handler: BrainHTTPHandler

    /// Wired after construction when camera server is enabled.
    var cameraRoutes: MacCameraHttpRoutes?
    /// When true, camera routes use the same Bearer token as brain routes.
    var requireCameraToken = true

    init(handler: BrainHTTPHandler, diagnostics: GatewayDiagnostics) {
        self.handler = handler
        self.diagnostics = diagnostics
    }

    // MARK: - Lifecycle

    func start(port: UInt16, bindLocalOnly: Bool) {
        stop()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if bindLocalOnly {
            params.requiredInterfaceType = .loopback
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            Task { @MainActor [weak self] in
                self?.diagnostics.markError("Invalid port \(port)")
            }
            return
        }

        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            Task { @MainActor [weak self] in
                self?.diagnostics.markError(error.localizedDescription)
            }
            return
        }

        let capturedPort = port
        let capturedBindLocal = bindLocalOnly
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.diagnostics.markRunning(port: capturedPort, bindLocal: capturedBindLocal)
                case .failed(let err):
                    self.diagnostics.markError(err.localizedDescription)
                    self.listener = nil
                case .cancelled:
                    self.diagnostics.markStopped()
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: self.networkQueue)
            self.readHTTP(conn: conn, buffer: Data())
        }

        listener?.start(queue: networkQueue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        Task { @MainActor [weak self] in
            self?.cameraRoutes?.stopAll()
            self?.diagnostics.markStopped()
        }
    }

    // MARK: - HTTP accumulation

    private func readHTTP(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, _, error in
            guard let self, error == nil, let chunk, !chunk.isEmpty else {
                conn.cancel()
                return
            }
            let buf = buffer + chunk
            if buf.range(of: Data("\r\n\r\n".utf8)) != nil {
                Task { @MainActor [weak self] in
                    guard let self else { conn.cancel(); return }
                    await self.processRequest(data: buf, conn: conn)
                }
            } else if buf.count > 65_536 {
                conn.cancel()
            } else {
                self.readHTTP(conn: conn, buffer: buf)
            }
        }
    }

    // MARK: - Request processing (@MainActor)

    @MainActor
    private func processRequest(data: Data, conn: NWConnection) async {
        guard let raw = String(data: data, encoding: .utf8),
              let sepRange = raw.range(of: "\r\n\r\n") else {
            send(conn, statusCode: 400, body: errorJSON("Malformed request"))
            return
        }

        let headerSection = String(raw[..<sepRange.lowerBound])
        let headerLines = headerSection.components(separatedBy: "\r\n")

        guard let reqLine = headerLines.first else {
            send(conn, statusCode: 400, body: errorJSON("Empty request"))
            return
        }

        let parts = reqLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            send(conn, statusCode: 400, body: errorJSON("Bad request line"))
            return
        }

        let method = String(parts[0]).uppercased()
        let path   = String(parts[1])

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let headerByteCount = headerSection.utf8.count + 4
        let body = Data(data.dropFirst(headerByteCount))

        // ── Health routes (no auth) ──────────────────────────────────────
        if path == "/health" || path == "/brain/health" {
            send(conn, statusCode: 200, body: makeHealthJSON())
            diagnostics.recordRequest(path: path, statusCode: 200)
            return
        }

        // ── V1 gateway routes ────────────────────────────────────────────
        if path.hasPrefix("/v1/") {
            // Auth check — skip for pairing endpoint (needs its own code check)
            // Android WebSocket upgrade also needs auth
            let bearer = headers["authorization"]?
                .replacingOccurrences(of: "Bearer ", with: "")
                .trimmingCharacters(in: .whitespaces) ?? ""
            let isWS = headers["upgrade"]?.lowercased() == "websocket"

            // Pair code generation and completion are auth-gated
            if let tok = diagnostics.authToken, !tok.isEmpty {
                if !GatewayAuthStore.shared.isAuthorized(bearer) {
                    diagnostics.recordUnauthorized(isWebSocket: isWS)
                    send(conn, statusCode: 401, body: errorJSON("Unauthorized"))
                    return
                }
            }

            let (status, respBody) = await handleV1Route(
                method: method, path: path, headers: headers, body: body, conn: conn)
            if status != 0 {
                send(conn, statusCode: status, body: respBody)
                diagnostics.recordRequest(path: path, statusCode: status)
            }
            return
        }

        // ── Camera routes (/camera/*) ────────────────────────────────────
        if path.hasPrefix("/camera/") {
            if requireCameraToken, let token = diagnostics.authToken, !token.isEmpty {
                let bearer = headers["authorization"]?
                    .replacingOccurrences(of: "Bearer ", with: "")
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !GatewayAuthStore.shared.isAuthorized(bearer) {
                    diagnostics.recordUnauthorized()
                    send(conn, statusCode: 401, body: errorJSON("Unauthorized"))
                    return
                }
            }
            guard let routes = cameraRoutes else {
                send(conn, statusCode: 503, body: errorJSON("Camera server not enabled"))
                return
            }
            switch (method, path) {
            case ("GET", "/camera/health"):
                let (status, body, ct) = routes.handleHealth()
                sendBinary(conn, statusCode: status, body: body, contentType: ct)
                diagnostics.recordRequest(path: path, statusCode: status)
            case ("GET", "/camera/snapshot"):
                let (status, body, ct) = await routes.handleSnapshot()
                sendBinary(conn, statusCode: status, body: body, contentType: ct)
                diagnostics.recordRequest(path: path, statusCode: status)
            case ("GET", "/camera/stream"):
                await routes.handleStream(connection: conn)
                diagnostics.recordRequest(path: path, statusCode: 200)
            default:
                send(conn, statusCode: 404, body: errorJSON("Camera endpoint not found"))
            }
            return
        }

        // ── Brain routes (/brain/*) ──────────────────────────────────────
        let bearer = headers["authorization"]?
            .replacingOccurrences(of: "Bearer ", with: "")
            .trimmingCharacters(in: .whitespaces) ?? ""
        if let token = diagnostics.authToken, !token.isEmpty {
            if !GatewayAuthStore.shared.isAuthorized(bearer) {
                diagnostics.recordUnauthorized()
                send(conn, statusCode: 401, body: errorJSON("Unauthorized"))
                return
            }
        }

        let resp = await handler.handle(method: method, path: path, headers: headers, body: body)
        send(conn, statusCode: resp.statusCode, body: resp.body)
        diagnostics.recordRequest(path: path, statusCode: resp.statusCode)
    }

    // MARK: - V1 route handler

    @MainActor
    private func handleV1Route(method: String, path: String,
                                headers: [String: String], body: Data,
                                conn: NWConnection) async -> (Int, Data) {

        // External device WebSocket connections (/v1/android/ws, /v1/windows/ws) are now
        // handled exclusively by JarvisBrainDaemon on port 8765. This server is loopback-only.

        switch (method, path) {

        // ── GET /v1/status ───────────────────────────────────────────────
        case ("GET", "/v1/status"):
            struct StatusResp: Encodable {
                let isRunning: Bool; let port: UInt16
                let androidDevices: Int; let pairedDevices: Int
                let uptimeSeconds: Double; let version: String
            }
            let resp = StatusResp(
                isRunning: diagnostics.isRunning,
                port: diagnostics.listeningPort,
                androidDevices: diagnostics.connectedAndroidDevices,
                pairedDevices: GatewayAuthStore.shared.pairedDevices.filter { !$0.isRevoked }.count,
                uptimeSeconds: diagnostics.uptimeSeconds,
                version: "2"
            )
            return (200, (try? JSONEncoder().encode(resp)) ?? Data())

        // ── GET /v1/devices ──────────────────────────────────────────────
        case ("GET", "/v1/devices"):
            struct DeviceInfo: Encodable {
                let id: String; let name: String
                let createdAt: String; let lastSeenAt: String
                let capabilities: [String]; let isRevoked: Bool
            }
            let iso = ISO8601DateFormatter()
            let devices = GatewayAuthStore.shared.pairedDevices.map {
                DeviceInfo(id: $0.id, name: $0.name,
                           createdAt: iso.string(from: $0.createdAt),
                           lastSeenAt: iso.string(from: $0.lastSeenAt),
                           capabilities: $0.capabilities,
                           isRevoked: $0.isRevoked)
            }
            return (200, (try? JSONEncoder().encode(devices)) ?? Data())

        // ── POST /v1/auth/rotate ─────────────────────────────────────────
        case ("POST", "/v1/auth/rotate"):
            let newToken = GatewayAuthStore.shared.regenerateGatewayToken()
            diagnostics.tokenRotationCount += 1
            struct RotateResp: Encodable { let gatewayToken: String }
            return (200, (try? JSONEncoder().encode(RotateResp(gatewayToken: newToken))) ?? Data())

        // ── GET /v1/diagnostics ──────────────────────────────────────────
        case ("GET", "/v1/diagnostics"):
            struct DiagResp: Encodable {
                let isRunning: Bool; let port: UInt16; let bindAddress: String
                let requestsServed: Int; let unauthorizedAttempts: Int
                let rejectedHTTP: Int; let rejectedWS: Int
                let connectedAndroid: Int; let activeWS: Int
                let tokenRotations: Int; let uptimeSeconds: Double
                let pairingCodeActive: Bool; let deprecatedPortEnabled: Bool
                let gatewayAuthEnabled: Bool
            }
            let d = diagnostics
            let resp = DiagResp(
                isRunning: d.isRunning, port: d.listeningPort, bindAddress: d.gatewayBindAddress,
                requestsServed: d.requestsServed, unauthorizedAttempts: d.unauthorizedAttempts,
                rejectedHTTP: d.rejectedUnauthenticatedRequests, rejectedWS: d.rejectedUnauthenticatedWebSockets,
                connectedAndroid: d.connectedAndroidDevices, activeWS: d.activeWebSocketClients,
                tokenRotations: d.tokenRotationCount, uptimeSeconds: d.uptimeSeconds,
                pairingCodeActive: d.pairingCodeActive, deprecatedPortEnabled: d.deprecatedAndroidPortEnabled,
                gatewayAuthEnabled: d.gatewayAuthEnabled
            )
            return (200, (try? JSONEncoder().encode(resp)) ?? Data())

        default:
            return (404, errorJSON("V1 endpoint not found: \(path)"))
        }
    }

    // MARK: - Response helpers

    private func send(_ conn: NWConnection, statusCode: Int, body: Data) {
        let text: String
        switch statusCode {
        case 200: text = "OK"
        case 201: text = "Created"
        case 400: text = "Bad Request"
        case 401: text = "Unauthorized"
        case 403: text = "Forbidden"
        case 404: text = "Not Found"
        case 500: text = "Internal Server Error"
        case 503: text = "Service Unavailable"
        default:  text = "Unknown"
        }
        let hdr = "HTTP/1.1 \(statusCode) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(hdr.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendBinary(_ conn: NWConnection, statusCode: Int, body: Data, contentType: String) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 503: statusText = "Service Unavailable"
        default:  statusText = "Error"
        }
        let hdr = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(hdr.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func errorJSON(_ message: String) -> Data {
        (try? JSONEncoder().encode(BrainErrorResponse(error: message, requestId: nil))) ?? Data()
    }

    private func makeHealthJSON() -> Data {
        struct HealthResp: Encodable { let status: String; let version: String; let gateway: Bool }
        return (try? JSONEncoder().encode(HealthResp(status: "ok", version: "2", gateway: true))) ?? Data()
    }

    // MARK: - WebSocket handshake helpers (ported from MacBridgeProtocolV2)

    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private static func computeWSAcceptKey(_ clientKey: String) -> String {
        let combined = Data((clientKey + wsGUID).utf8)
        return Data(Insecure.SHA1.hash(data: combined)).base64EncodedString()
    }
}
