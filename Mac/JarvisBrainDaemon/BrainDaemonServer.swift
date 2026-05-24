import CryptoKit
import Foundation
import Network
import OSLog

/// Standalone NWListener HTTP server for JarvisBrainDaemon.
/// Binds port 8765 (overridable via JARVIS_DAEMON_PORT env var).
/// Does NOT import SwiftUI, AppKit, or the JarvisMac target.
final class BrainDaemonServer {

    private let serverLog = Logger(subsystem: "com.jarvis.brain", category: "server")
    private let networkQueue = DispatchQueue(label: "com.jarvis.brain.server", qos: .utility)
    private var listener: NWListener?

    let port: Int

    init() {
        if let envPort = ProcessInfo.processInfo.environment["JARVIS_DAEMON_PORT"],
           let p = Int(envPort), p > 0, p < 65536 {
            port = p
        } else {
            port = 8765
        }
        DaemonDiagnostics.shared.port = port
    }

    // MARK: - Lifecycle

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            serverLog.error("Invalid port \(self.port)")
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            serverLog.error("Failed to create listener: \(error.localizedDescription)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.serverLog.info("JarvisBrainDaemon listening on port \(self.port)")
            case .failed(let err):
                self.serverLog.error("Listener failed: \(err.localizedDescription)")
                self.listener = nil
            case .cancelled:
                self.serverLog.info("Listener cancelled")
            default:
                break
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
    }

    // MARK: - HTTP accumulation

    private func readHTTP(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, _, error in
            guard let self, error == nil, let chunk, !chunk.isEmpty else {
                conn.cancel()
                return
            }
            let buf = buffer + chunk
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf[..<headerEnd.lowerBound]
                guard let headerStr = String(data: headerData, encoding: .utf8) else {
                    conn.cancel()
                    return
                }
                // Parse Content-Length
                var contentLength = 0
                for line in headerStr.components(separatedBy: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
                let bodyStart = headerEnd.upperBound
                let bodyData = buf[bodyStart...]
                if contentLength == 0 || bodyData.count >= contentLength {
                    self.processRequest(data: buf, conn: conn)
                } else {
                    // Need more body — check against hard cap first
                    let maxBody = 110 * 1024 * 1024  // 110 MB hard cap (max file 100 MB + overhead)
                    if contentLength > maxBody {
                        self.send(conn, statusCode: 413, body: self.errorJSON("File too large"))
                        return
                    }
                    self.readHTTPBody(conn: conn, buffer: buf, totalNeeded: headerData.count + 4 + contentLength)
                }
            } else if buf.count > 65_536 {
                conn.cancel()
            } else {
                self.readHTTP(conn: conn, buffer: buf)
            }
        }
    }

    private func readHTTPBody(conn: NWConnection, buffer: Data, totalNeeded: Int) {
        if buffer.count >= totalNeeded {
            processRequest(data: Data(buffer.prefix(totalNeeded)), conn: conn)
            return
        }
        let remaining = totalNeeded - buffer.count
        conn.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 65_536)) { [weak self] chunk, _, _, error in
            guard let self, error == nil, let chunk, !chunk.isEmpty else {
                conn.cancel()
                return
            }
            self.readHTTPBody(conn: conn, buffer: buffer + chunk, totalNeeded: totalNeeded)
        }
    }

    // MARK: - Request processing

    private func processRequest(data: Data, conn: NWConnection) {
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

        DaemonDiagnostics.shared.requestsServed += 1

        // ── Health (no auth required) ────────────────────────────────────
        if path == "/health" || path == "/brain/health" {
            let resp = makeHealthJSON()
            send(conn, statusCode: 200, body: resp)
            return
        }

        // ── Unified /v2/ws route (canonical for all platforms) ──────────────
        if path == "/v2/ws" && headers["upgrade"]?.lowercased() == "websocket" {
            let bearer = extractBearer(headers)
            if !DaemonAuthStore.shared.isAuthorized(bearer) {
                DaemonDiagnostics.shared.unauthorizedAttempts += 1
                send(conn, statusCode: 401, body: errorJSON("Unauthorized"))
                return
            }
            guard let clientKey = headers["sec-websocket-key"] else {
                send(conn, statusCode: 400, body: errorJSON("Missing Sec-WebSocket-Key"))
                return
            }
            let acceptKey = computeWSAcceptKey(clientKey)
            let upgradeResp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
            conn.send(content: Data(upgradeResp.utf8), completion: .contentProcessed { _ in })
            let platform = (headers["x-platform"] ?? "").lowercased() == "windows" ? "windows" : "android"
            if platform == "windows" {
                DaemonDiagnostics.shared.connectedWindowsClients += 1
                startWindowsWebSocketSession(conn: conn, platform: "windows", deviceId: extractDeviceId(headers) ?? UUID().uuidString)
            } else {
                DaemonDiagnostics.shared.connectedAndroidClients += 1
                startAndroidWebSocketSession(conn: conn, platform: platform, deviceId: extractDeviceId(headers) ?? UUID().uuidString)
            }
            return
        }

        // ── V1 WebSocket upgrade for Android ─────────────────────────────
        if path == "/v1/android/ws" && headers["upgrade"]?.lowercased() == "websocket" {
            // SECURITY AUDITED Phase 2: auth checked BEFORE 101 upgrade response
            let bearer = extractBearer(headers)
            if !DaemonAuthStore.shared.isAuthorized(bearer) {
                DaemonDiagnostics.shared.unauthorizedAttempts += 1
                send(conn, statusCode: 401, body: errorJSON("Unauthorized"))
                return
            }
            guard let clientKey = headers["sec-websocket-key"] else {
                send(conn, statusCode: 400, body: errorJSON("Missing Sec-WebSocket-Key"))
                return
            }
            let acceptKey = computeWSAcceptKey(clientKey)
            let upgradeResp = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
            conn.send(content: Data(upgradeResp.utf8), completion: .contentProcessed { _ in })
            DaemonDiagnostics.shared.connectedAndroidClients += 1
            // Begin full WebSocket frame loop (Task 4: ping/pong, heartbeat, message dispatch)
            startAndroidWebSocketSession(conn: conn, platform: "android",
                                         deviceId: extractDeviceId(headers) ?? UUID().uuidString)
            return
        }

        // ── V1 WebSocket upgrade for Windows ──────────────────────────────
        if path == "/v1/windows/ws" && headers["upgrade"]?.lowercased() == "websocket" {
            // SECURITY AUDITED Phase 2: auth checked BEFORE 101 upgrade response
            let bearer = extractBearer(headers)
            if !DaemonAuthStore.shared.isAuthorized(bearer) {
                DaemonDiagnostics.shared.unauthorizedAttempts += 1
                send(conn, statusCode: 401, body: errorJSON("Unauthorized"))
                return
            }
            guard let clientKey = headers["sec-websocket-key"] else {
                send(conn, statusCode: 400, body: errorJSON("Missing Sec-WebSocket-Key"))
                return
            }
            let acceptKey = computeWSAcceptKey(clientKey)
            let upgradeResp = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
            conn.send(content: Data(upgradeResp.utf8), completion: .contentProcessed { _ in })
            DaemonDiagnostics.shared.connectedWindowsClients += 1
            startWindowsWebSocketSession(conn: conn, platform: "windows",
                                          deviceId: extractDeviceId(headers) ?? UUID().uuidString)
            return
        }

        // ── V1 WebSocket upgrade for Mac app ──────────────────────────────
        if path == "/v1/mac/ws" && headers["upgrade"]?.lowercased() == "websocket" {
            let bearer = extractBearer(headers)
            if !DaemonAuthStore.shared.isAuthorized(bearer) {
                DaemonDiagnostics.shared.unauthorizedAttempts += 1
                send(conn, statusCode: 401, body: errorJSON("Unauthorized"))
                return
            }
            guard let clientKey = headers["sec-websocket-key"] else {
                send(conn, statusCode: 400, body: errorJSON("Missing Sec-WebSocket-Key"))
                return
            }
            let acceptKey = computeWSAcceptKey(clientKey)
            let upgradeResp = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
            conn.send(content: Data(upgradeResp.utf8), completion: .contentProcessed { _ in })
            DaemonDiagnostics.shared.connectedMacClients += 1
            startMacWebSocketSession(conn: conn)
            return
        }

        // ── All other routes require auth ────────────────────────────────
        let bearer = extractBearer(headers)
        if !DaemonAuthStore.shared.isAuthorized(bearer) {
            DaemonDiagnostics.shared.unauthorizedAttempts += 1
            send(conn, statusCode: 401, body: errorJSON("Unauthorized"))
            return
        }

        // ── V1 routes ────────────────────────────────────────────────────
        switch (method, path) {

        case ("GET", "/v1/status"):
            let diag = DaemonDiagnostics.shared
            let authStore = DaemonAuthStore.shared
            let dict: [String: Any] = [
                "daemon": true,
                "port": diag.port,
                "uptimeSeconds": diag.uptimeSeconds,
                "connectedDevices": authStore.pairedDevices.filter { !$0.isRevoked }.count,
                "startedAt": ISO8601DateFormatter().string(from: diag.startedAt),
                "connectedWebSockets": diag.connectedWebSockets
            ]
            send(conn, statusCode: 200, body: toJSON(dict))

        case ("GET", "/v1/diagnostics"):
            send(conn, statusCode: 200, body: Data(DaemonDiagnostics.shared.toJSON().utf8))

        case ("GET", "/v1/devices"):
            let iso = ISO8601DateFormatter()
            let devices = DaemonAuthStore.shared.pairedDevices.map { dev -> [String: Any] in
                [
                    "id": dev.id,
                    "name": dev.name,
                    "createdAt": iso.string(from: dev.createdAt),
                    "lastSeenAt": iso.string(from: dev.lastSeenAt),
                    "capabilities": dev.capabilities,
                    "isRevoked": dev.isRevoked
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: devices, options: .prettyPrinted) {
                send(conn, statusCode: 200, body: data)
            } else {
                send(conn, statusCode: 200, body: Data("[]".utf8))
            }

        case ("POST", "/v1/android/pair/code"):
            let code = DaemonAuthStore.shared.generatePairingCode()
            let dict: [String: Any] = [
                "code": code.code,
                "expiresAt": ISO8601DateFormatter().string(from: code.expiresAt)
            ]
            send(conn, statusCode: 200, body: toJSON(dict))

        case ("POST", "/v1/android/pair"):
            struct PairReq: Decodable { let code: String; let deviceId: String; let deviceName: String }
            guard let req = try? JSONDecoder().decode(PairReq.self, from: body) else {
                send(conn, statusCode: 400, body: errorJSON("Invalid JSON — expected {code, deviceId, deviceName}"))
                return
            }
            guard let rawToken = DaemonAuthStore.shared.completePairing(
                code: req.code, deviceId: req.deviceId, deviceName: req.deviceName, platform: "android") else {
                send(conn, statusCode: 403, body: errorJSON("Invalid or expired pairing code"))
                return
            }
            let dict: [String: Any] = ["deviceToken": rawToken]
            send(conn, statusCode: 200, body: toJSON(dict))

        case ("POST", "/v1/windows/pair/code"):
            let code = DaemonAuthStore.shared.generatePairingCode()
            let dict: [String: Any] = [
                "code": code.code,
                "expiresAt": ISO8601DateFormatter().string(from: code.expiresAt)
            ]
            send(conn, statusCode: 200, body: toJSON(dict))

        case ("POST", "/v1/windows/pair"):
            struct WinPairReq: Decodable { let code: String; let deviceId: String; let deviceName: String }
            guard let req = try? JSONDecoder().decode(WinPairReq.self, from: body) else {
                send(conn, statusCode: 400, body: errorJSON("Invalid JSON — expected {code, deviceId, deviceName}"))
                return
            }
            guard let rawToken = DaemonAuthStore.shared.completePairing(
                code: req.code, deviceId: req.deviceId, deviceName: req.deviceName, platform: "windows") else {
                send(conn, statusCode: 403, body: errorJSON("Invalid or expired pairing code"))
                return
            }
            let dict: [String: Any] = ["deviceToken": rawToken]
            send(conn, statusCode: 200, body: toJSON(dict))

        case ("POST", "/v1/mac/pair/code"):
            let code = DaemonAuthStore.shared.generatePairingCode()
            let dict: [String: Any] = [
                "code": code.code,
                "expiresAt": ISO8601DateFormatter().string(from: code.expiresAt)
            ]
            send(conn, statusCode: 200, body: toJSON(dict))

        case ("POST", "/v1/mac/pair"):
            struct MacPairReq: Decodable { let code: String; let deviceId: String; let deviceName: String }
            guard let req = try? JSONDecoder().decode(MacPairReq.self, from: body) else {
                send(conn, statusCode: 400, body: errorJSON("Invalid JSON — expected {code, deviceId, deviceName}"))
                return
            }
            guard let rawToken = DaemonAuthStore.shared.completePairing(
                code: req.code, deviceId: req.deviceId, deviceName: req.deviceName, platform: "mac") else {
                send(conn, statusCode: 403, body: errorJSON("Invalid or expired pairing code"))
                return
            }
            let dict: [String: Any] = ["sessionToken": rawToken]
            send(conn, statusCode: 200, body: toJSON(dict))

        // ── File transfer endpoints ──────────────────────────────────────────
        case ("POST", "/v1/files/upload"):
            handleFileUpload(conn: conn, headers: headers, body: body)

        case let ("GET", path) where path.hasPrefix("/v1/files/"):
            let transferId = String(path.dropFirst("/v1/files/".count))
            handleFileDownload(conn: conn, headers: headers, transferId: transferId)

        case let ("DELETE", path) where path.hasPrefix("/v1/files/"):
            let transferId = String(path.dropFirst("/v1/files/".count))
            FileTransferStore.shared.delete(transferId: transferId)
            send(conn, statusCode: 200, body: toJSON(["deleted": true]))

        case ("GET", "/v1/router/diagnostics"):
            let snap = DaemonMessageRouter.shared.snapshot()
            let iso = ISO8601DateFormatter()
            var dict: [String: Any] = [
                "connectedMacClients":     snap.connectedMacClients,
                "connectedAndroidClients": snap.connectedAndroidClients,
                "connectedWindowsClients": snap.connectedWindowsClients,
                "routedMessageCount":          snap.routedMessageCount,
                "ignoredUnknownMessageCount":  snap.ignoredUnknownMessageCount,
                "malformedMessageCount":       snap.malformedMessageCount,
                "oversizedMessageCount":       snap.oversizedMessageCount,
                "nackCount":                   snap.nackCount,
                "ackCount":                    snap.ackCount,
                "offlineQueueDepth":           snap.offlineQueueDepth,
                "offlineQueueDroppedCount":    snap.offlineQueueDroppedCount,
                "brainUnavailableCount":       snap.brainUnavailableCount,
                "lastMessageType":             snap.lastMessageType,
                "devices": snap.deviceSummaries.map { d -> [String: Any] in
                    [
                        "deviceId": d.deviceId,
                        "platform": d.platform,
                        "capabilities": d.capabilities,
                        "routedMessages": d.routedMessages,
                        "rejectedMessages": d.rejectedMessages,
                        "lastError": d.lastError
                    ]
                }
            ]
            if let d = snap.lastAndroidMessageAt { dict["lastAndroidMessageAt"] = iso.string(from: d) }
            if let d = snap.lastWindowsMessageAt { dict["lastWindowsMessageAt"] = iso.string(from: d) }
            if let d = snap.lastMacAppMessageAt  { dict["lastMacAppMessageAt"]  = iso.string(from: d) }
            send(conn, statusCode: 200, body: toJSON(dict))

        default:
            send(conn, statusCode: 404, body: errorJSON("Endpoint not found: \(path)"))
        }
    }

    // MARK: - Android WebSocket session (Task 4)

    private func startAndroidWebSocketSession(conn: NWConnection, platform: String = "android",
                                              deviceId: String = UUID().uuidString) {
        let clientId = UUID().uuidString
        serverLog.info("Android WS connected: \(clientId) deviceId=\(deviceId)")
        DaemonMessageRouter.shared.registerClient(
            id: clientId, deviceId: deviceId, platform: platform,
            conn: conn, capabilities: []
        )
        startPingLoop(conn: conn, clientId: clientId, platform: platform)
        receiveWebSocketFrames(conn: conn, clientId: clientId, platform: platform)
    }

    // MARK: - Windows WebSocket session (Task 5)

    private func startWindowsWebSocketSession(conn: NWConnection, platform: String = "windows",
                                              deviceId: String = UUID().uuidString) {
        let clientId = UUID().uuidString
        serverLog.info("Windows WS connected: \(clientId) deviceId=\(deviceId)")
        DaemonMessageRouter.shared.registerClient(
            id: clientId, deviceId: deviceId, platform: platform,
            conn: conn, capabilities: []
        )
        startPingLoop(conn: conn, clientId: clientId, platform: platform)
        receiveWebSocketFrames(conn: conn, clientId: clientId, platform: platform)
    }

    // MARK: - Mac WebSocket session (Phase 3)

    private func startMacWebSocketSession(conn: NWConnection) {
        let clientId = UUID().uuidString
        serverLog.info("Mac app WS connected: \(clientId)")
        DaemonMessageRouter.shared.registerClient(
            id: clientId, deviceId: "mac", platform: "mac",
            conn: conn, capabilities: ["brain", "memory", "llm"]
        )
        startPingLoop(conn: conn, clientId: clientId, platform: "mac")
        receiveWebSocketFrames(conn: conn, clientId: clientId, platform: "mac")
    }

    // MARK: - Ping/pong heartbeat (Task 4b)

    private func startPingLoop(conn: NWConnection, clientId: String, platform: String) {
        let pingInterval: TimeInterval = 30
        networkQueue.asyncAfter(deadline: .now() + pingInterval) { [weak self] in
            guard let self else { return }
            // Send ping frame (opcode 0x09, no payload)
            let pingFrame = Data([0x89, 0x00])
            conn.send(content: pingFrame, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.serverLog.error("Ping failed for \(clientId): \(error.localizedDescription)")
                    self?.disconnectClient(clientId: clientId, platform: platform, conn: conn)
                    return
                }
                // Schedule next ping
                self?.startPingLoop(conn: conn, clientId: clientId, platform: platform)
            })
        }
    }

    // MARK: - WebSocket frame receive loop (Task 4a: opcodes 0x01/0x08/0x09/0x0A)

    private func receiveWebSocketFrames(conn: NWConnection, clientId: String, platform: String) {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if let error {
                self.serverLog.info("WS disconnected \(clientId): \(error.localizedDescription)")
                self.disconnectClient(clientId: clientId, platform: platform, conn: conn)
                return
            }
            if let data, !data.isEmpty {
                let bytes = Array(data)
                guard bytes.count >= 2 else {
                    self.receiveWebSocketFrames(conn: conn, clientId: clientId, platform: platform)
                    return
                }
                let opcode = bytes[0] & 0x0F

                switch opcode {
                case 0x01, 0x02:  // text or binary
                    // Task 4c: record lastSeen on any frame
                    DaemonAuthStore.shared.recordSeen(deviceId: clientId)
                    if let text = Self.parseWebSocketFrame(bytes) {
                        // Wrap raw client frame in DaemonMessageEnvelope and route to other clients.
                        self.wrapAndRoute(rawJSON: text, fromClientId: clientId, platform: platform)
                        self.dispatchAndroidMessage(text: text, clientId: clientId, conn: conn, platform: platform)
                    }

                case 0x08:  // close
                    // Send close frame back, then close
                    let closeFrame = Data([0x88, 0x00])
                    conn.send(content: closeFrame, completion: .contentProcessed { _ in })
                    self.disconnectClient(clientId: clientId, platform: platform, conn: conn)
                    return

                case 0x09:  // ping — send pong immediately
                    let pongFrame = Data([0x8A, 0x00])
                    conn.send(content: pongFrame, completion: .contentProcessed { _ in })
                    DaemonAuthStore.shared.recordSeen(deviceId: clientId)

                case 0x0A:  // pong — update lastSeen, no-op otherwise
                    DaemonAuthStore.shared.recordSeen(deviceId: clientId)

                default:
                    self.serverLog.info("Unknown WS opcode \(opcode) from \(clientId)")
                }
            }
            if isComplete {
                self.disconnectClient(clientId: clientId, platform: platform, conn: conn)
            } else {
                self.receiveWebSocketFrames(conn: conn, clientId: clientId, platform: platform)
            }
        }
    }

    // MARK: - Android message dispatch (Task 4d)

    private func dispatchAndroidMessage(text: String, clientId: String, conn: NWConnection, platform: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            serverLog.info("Non-JSON frame from \(clientId)")
            return
        }
        let type = json["type"] as? String ?? "unknown"
        let deviceId = json["deviceId"] as? String ?? clientId
        serverLog.info("WS [\(platform)] type=\(type) deviceId=\(deviceId)")

        switch type {
        case "heartbeat", "ping":
            let pong = "{\"type\":\"pong\",\"ts\":\"\(ISO8601DateFormatter().string(from: Date()))\"}"
            sendWebSocketText(pong, conn: conn)

        case "device.hello":
            DaemonAuthStore.shared.recordSeen(deviceId: deviceId)
            let ack = "{\"type\":\"hello.ack\",\"daemonVersion\":\"1\"}"
            sendWebSocketText(ack, conn: conn)

        case "transcript.final":
            serverLog.info("WS transcript.final from \(deviceId) — routing deferred to Phase 2")
            // Full LLM routing is a future phase

        default:
            serverLog.info("WS unknown type '\(type)' from \(deviceId) — ignored")
        }
    }

    // MARK: - Disconnect helper

    private func disconnectClient(clientId: String, platform: String, conn: NWConnection) {
        conn.cancel()
        DaemonMessageRouter.shared.unregisterClient(id: clientId)
        switch platform {
        case "windows":
            DaemonDiagnostics.shared.connectedWindowsClients = max(0, DaemonDiagnostics.shared.connectedWindowsClients - 1)
        case "mac":
            DaemonDiagnostics.shared.connectedMacClients = max(0, DaemonDiagnostics.shared.connectedMacClients - 1)
        default:
            DaemonDiagnostics.shared.connectedAndroidClients = max(0, DaemonDiagnostics.shared.connectedAndroidClients - 1)
        }
        serverLog.info("WS [\(platform)] \(clientId) disconnected")
    }

    // MARK: - Raw frame → envelope wrapper

    /// Parses a raw client JSON frame, wraps it in a DaemonMessageEnvelope, and routes
    /// it via DaemonMessageRouter. Android and Windows send flat JSON (not envelopes).
    /// Mac clients send full DaemonMessageEnvelope JSON — those are routed directly.
    private func wrapAndRoute(rawJSON: String, fromClientId: String, platform: String) {
        guard let data = rawJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // If the frame is already a DaemonMessageEnvelope (Mac-sent), route directly.
        if raw["sourceDeviceId"] != nil, raw["target"] != nil {
            if let envelopeData = try? JSONSerialization.data(withJSONObject: raw) {
                DaemonMessageRouter.shared.route(rawData: envelopeData, fromClientId: fromClientId)
            }
            return
        }

        let type = raw["type"] as? String ?? "unknown"
        let deviceId = raw["deviceId"] as? String ?? fromClientId
        let correlationId = raw["messageId"] as? String ?? raw["routeId"] as? String

        // Route everything device → Mac except replies/orchestration (Mac → device)
        let targetType: String
        switch type {
        case "reply.final", "reply.partial", "orchestrate.speak", "orchestrate.silent", "proactive.notify":
            targetType = platform
        default:
            targetType = "macApp"
        }

        var envelope: [String: Any] = [
            "id": UUID().uuidString,
            "type": type,
            "sourceDeviceId": deviceId,
            "sourcePlatform": platform,
            "target": ["type": targetType],
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "payload": raw
        ]
        if let cid = correlationId { envelope["correlationId"] = cid }

        if let envelopeData = try? JSONSerialization.data(withJSONObject: envelope) {
            DaemonMessageRouter.shared.route(rawData: envelopeData, fromClientId: fromClientId)
        }
    }

    // MARK: - WebSocket frame codec (RFC 6455)

    private static func parseWebSocketFrame(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        guard opcode == 1 || opcode == 2 else { return nil }
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

    private func sendWebSocketText(_ text: String, conn: NWConnection) {
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
        conn.send(content: Data(frame), completion: .contentProcessed { _ in })
    }

    // MARK: - File transfer handlers

    private func handleFileUpload(conn: NWConnection, headers: [String: String], body: Data) {
        let contentType = headers["content-type"] ?? ""
        guard contentType.contains("multipart/form-data") else {
            send(conn, statusCode: 400, body: errorJSON("Expected multipart/form-data"))
            return
        }

        // Extract boundary
        guard let boundaryRange = contentType.range(of: "boundary="),
              !boundaryRange.isEmpty else {
            send(conn, statusCode: 400, body: errorJSON("Missing boundary in Content-Type"))
            return
        }
        let boundary = String(contentType[boundaryRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        // Parse multipart
        guard let parsed = parseMultipart(body: body, boundary: boundary) else {
            send(conn, statusCode: 400, body: errorJSON("Failed to parse multipart body"))
            return
        }

        let targetPlatform = parsed.fields["targetPlatform"] ?? "mac"
        let openOnMac = (parsed.fields["openOnMac"] ?? "false") == "true"
        let suggestedAction = parsed.fields["suggestedAction"] ?? "save"
        let userVisibleName = parsed.fields["userVisibleName"] ?? ""
        let sourceDeviceId = headers["x-device-id"] ?? "unknown"

        guard let (_, safeMeta) = FileTransferStore.shared.storeUpload(
            filename: parsed.filename,
            mimeType: parsed.mimeType,
            data: parsed.fileData,
            sourceDeviceId: sourceDeviceId,
            targetPlatform: targetPlatform,
            openOnMac: openOnMac,
            suggestedAction: suggestedAction,
            userVisibleName: userVisibleName
        ) else {
            send(conn, statusCode: 400, body: errorJSON("File rejected: too large, blocked extension, or disallowed type"))
            return
        }

        // Emit file.transfer.created to Mac via router
        let payloadDict: [String: JSONValue] = safeMeta.reduce(into: [:]) { dict, pair in
            switch pair.value {
            case let s as String: dict[pair.key] = .string(s)
            case let i as Int: dict[pair.key] = .int(i)
            case let b as Bool: dict[pair.key] = .bool(b)
            default: break
            }
        }
        let transferEnvelope = DaemonMessageEnvelope.make(
            type: "file.transfer.created",
            target: .macApp,
            payload: .object(payloadDict),
            sourcePlatform: "daemon"
        )
        _ = DaemonMessageRouter.shared.deliverToMac(transferEnvelope)

        send(conn, statusCode: 200, body: toJSON(safeMeta))
    }

    private func handleFileDownload(conn: NWConnection, headers: [String: String], transferId: String) {
        let platform = headers["x-platform"]?.lowercased() ?? ""
        guard platform == "mac" || headers["x-device-id"] == "mac" else {
            send(conn, statusCode: 403, body: errorJSON("File download only available to Mac clients"))
            return
        }

        guard let (data, meta) = FileTransferStore.shared.retrieve(
            transferId: transferId,
            requestingPlatform: "mac"
        ) else {
            send(conn, statusCode: 404, body: errorJSON("Transfer not found or expired"))
            return
        }

        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(meta.mimeType)\r\nContent-Length: \(data.count)\r\nContent-Disposition: attachment; filename=\"\(meta.filename)\"\r\nX-Transfer-Id: \(meta.transferId)\r\nX-SHA256: \(meta.sha256)\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private struct MultipartParsed {
        let filename: String
        let mimeType: String
        let fileData: Data
        let fields: [String: String]
    }

    private func parseMultipart(body: Data, boundary: String) -> MultipartParsed? {
        guard let bodyStr = String(data: body, encoding: .utf8) else { return nil }
        let sep = "--\(boundary)"
        let parts = bodyStr.components(separatedBy: sep).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.trimmingCharacters(in: .whitespacesAndNewlines) != "--"
        }

        var filename = "file"
        var mimeType = "application/octet-stream"
        var fileData: Data = Data()
        var fields: [String: String] = [:]

        for part in parts {
            guard let headerEnd = part.range(of: "\r\n\r\n") else { continue }
            let headerPart = String(part[..<headerEnd.lowerBound])
            let bodyPart = String(part[headerEnd.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n--"))

            if headerPart.contains("Content-Disposition: form-data") {
                if headerPart.contains("filename=") {
                    // File part
                    if let fnRange = headerPart.range(of: "filename=\"") {
                        let afterFn = String(headerPart[fnRange.upperBound...])
                        if let endQ = afterFn.firstIndex(of: "\"") {
                            filename = String(afterFn[..<endQ])
                        }
                    }
                    // Find Content-Type in this part's headers
                    for line in headerPart.components(separatedBy: "\r\n") {
                        if line.lowercased().hasPrefix("content-type:") {
                            mimeType = line.dropFirst("content-type:".count)
                                .trimmingCharacters(in: .whitespaces)
                        }
                    }
                    fileData = Data(bodyPart.utf8)
                } else if let nameRange = headerPart.range(of: "name=\"") {
                    // Field part
                    let afterName = String(headerPart[nameRange.upperBound...])
                    if let endQ = afterName.firstIndex(of: "\"") {
                        let fieldName = String(afterName[..<endQ])
                        fields[fieldName] = bodyPart
                    }
                }
            }
        }

        guard !fileData.isEmpty else { return nil }
        return MultipartParsed(filename: filename, mimeType: mimeType, fileData: fileData, fields: fields)
    }

    // MARK: - Response helpers

    private func send(_ conn: NWConnection, statusCode: Int, body: Data) {
        let text: String
        switch statusCode {
        case 200: text = "OK"
        case 400: text = "Bad Request"
        case 401: text = "Unauthorized"
        case 403: text = "Forbidden"
        case 404: text = "Not Found"
        case 413: text = "Payload Too Large"
        case 500: text = "Internal Server Error"
        case 503: text = "Service Unavailable"
        default:  text = "Unknown"
        }
        let hdr = "HTTP/1.1 \(statusCode) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(hdr.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func errorJSON(_ message: String) -> Data {
        let dict: [String: Any] = ["error": message]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    private func makeHealthJSON() -> Data {
        let dict: [String: Any] = [
            "status": "ok",
            "daemon": true,
            "version": "1",
            "uptimeSeconds": DaemonDiagnostics.shared.uptimeSeconds
        ]
        return toJSON(dict)
    }

    private func toJSON(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)) ?? Data()
    }

    private func extractBearer(_ headers: [String: String]) -> String {
        headers["authorization"]?
            .replacingOccurrences(of: "Bearer ", with: "")
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private func extractDeviceId(_ headers: [String: String]) -> String? {
        guard let v = headers["x-device-id"]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }

    // MARK: - WebSocket handshake

    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private func computeWSAcceptKey(_ clientKey: String) -> String {
        let combined = Data((clientKey + Self.wsGUID).utf8)
        return Data(Insecure.SHA1.hash(data: combined)).base64EncodedString()
    }
}
