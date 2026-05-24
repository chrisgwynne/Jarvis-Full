import CryptoKit
import Foundation
import Network

// MARK: - MacBridgeProtocolV2

/// WebSocket server for the Windows sidecar protocol.
///
/// Windows connects to `GET /v2/ws` with a standard RFC 6455 Upgrade request.
/// The bridge handles bidirectional typed message frames:
///
///   Windows → Mac:  transcript.partial, transcript.final, presence.update,
///                   lease.request, replay.begin, replay.end,
///                   execution.result, device.hello, ping
///
///   Mac → Windows:  chat.reply.partial, chat.reply.final, lease.grant,
///                   lease.denied, orchestrate.silent, orchestrate.speak,
///                   proactive.notify, session.start, ack, heartbeat
///
/// Replay mode: frames arriving between replay.begin / replay.end are
/// ingested into history but NEVER trigger live responses.
@MainActor
final class MacBridgeProtocolV2 {

    static let shared = MacBridgeProtocolV2()

    // MARK: - WebSocket client

    private struct WSClient {
        let id: String
        var deviceId: String
        let sessionId: String
        var nextOutboundSeq: Int = 0
        var isReplayMode: Bool = false
        let conn: NWConnection
    }

    // MARK: - Inbound message envelope

    private struct WSInbound: Decodable {
        let type: String
        let messageId: String
        let deviceId: String?
        let seq: Int
        let ts: Date?
        let payload: [String: String]

        private enum CodingKeys: String, CodingKey {
            case type, messageId, deviceId, seq, ts, payload
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type      = try c.decode(String.self, forKey: .type)
            messageId = (try? c.decodeIfPresent(String.self, forKey: .messageId)) ?? UUID().uuidString
            deviceId  = try? c.decodeIfPresent(String.self, forKey: .deviceId)
            seq       = (try? c.decodeIfPresent(Int.self,    forKey: .seq)) ?? 0
            ts        = try? c.decodeIfPresent(Date.self,    forKey: .ts)
            payload   = (try? c.decodeIfPresent([String: String].self, forKey: .payload)) ?? [:]
        }
    }

    // MARK: - State

    private var wsClients: [String: WSClient] = [:]

    // MARK: - Callbacks (wired from JarvisController)

    /// Called with (deviceId, enriched transcript) for every live transcript.final.
    var onInboundTranscript: ((String, String) -> Void)?
    /// Called for every presence.update.
    var onInboundPresence: ((PresenceSnapshot) -> Void)?

    // MARK: - Codec

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let iso8601 = ISO8601DateFormatter()

    // MARK: - WebSocket constants

    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private static func computeAcceptKey(_ clientKey: String) -> String {
        let combined = Data((clientKey + wsGUID).utf8)
        return Data(Insecure.SHA1.hash(data: combined)).base64EncodedString()
    }

    // MARK: - HTTP → WebSocket upgrade

    /// Called by MacBrainServer when it detects `GET /v2/ws` + Upgrade: websocket.
    /// Takes ownership of `conn`; caller must NOT cancel it.
    func handleWebSocketUpgrade(headers: [String: String], conn: NWConnection) {
        guard let key = headers["sec-websocket-key"] else { conn.cancel(); return }

        let acceptKey = Self.computeAcceptKey(key)
        let response  = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"

        let deviceId  = headers["x-device-id"] ?? "device-\(UUID().uuidString.prefix(8))"
        let clientId  = UUID().uuidString
        let sessionId = DistributedConversationCoordinator.shared.sessionId ?? UUID().uuidString

        wsClients[clientId] = WSClient(
            id: clientId, deviceId: deviceId, sessionId: sessionId, conn: conn
        )

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.removeWSClient(clientId) }
            default: break
            }
        }

        let participant = DeviceParticipant(
            id: deviceId, kind: .windows, name: deviceId,
            lastSeenAt: Date(), isConnected: true
        )
        DistributedBrainDiagnostics.shared.markConnected(participant)
        DistributedBrainDiagnostics.shared.wsClientsConnected = wsClients.count

        conn.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                Task { @MainActor [weak self] in self?.removeWSClient(clientId) }
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sendWS(type: "session.start", payload: [
                    "sessionId": sessionId,
                    "macVersion": "2",
                    "deviceId": "mac"
                ], to: clientId)
                self.readWSData(conn: conn, buffer: Data(), clientId: clientId)
            }
        })
    }

    // MARK: - Frame reading loop

    private func readWSData(conn: NWConnection, buffer: Data, clientId: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, _, error in
            guard error == nil, let chunk, !chunk.isEmpty else {
                Task { @MainActor [weak self] in self?.removeWSClient(clientId) }
                return
            }
            let newBuffer = buffer + chunk
            Task { @MainActor [weak self] in
                guard let self else { return }
                let remaining = self.processWSBuffer(newBuffer, clientId: clientId, conn: conn)
                if self.wsClients[clientId] != nil {
                    self.readWSData(conn: conn, buffer: remaining, clientId: clientId)
                }
            }
        }
    }

    private func processWSBuffer(_ buffer: Data, clientId: String, conn: NWConnection) -> Data {
        var remaining = buffer
        while let (opcode, payload, consumed) = Self.parseFrame(remaining) {
            remaining = Data(remaining.dropFirst(consumed))
            dispatchOpcode(opcode, payload: payload, clientId: clientId, conn: conn)
        }
        return remaining
    }

    private func dispatchOpcode(_ opcode: UInt8, payload: Data, clientId: String, conn: NWConnection) {
        switch opcode {
        case 0x1:  // text
            if let text = String(data: payload, encoding: .utf8) {
                handleWSMessage(text: text, clientId: clientId)
            }
        case 0x8:  // close
            conn.send(content: Self.closeFrame(), completion: .contentProcessed { _ in conn.cancel() })
            removeWSClient(clientId)
        case 0x9:  // ping
            conn.send(content: Self.pongFrame(), completion: .idempotent)
        default:
            break
        }
    }

    // MARK: - Message dispatch

    private func handleWSMessage(text: String, clientId: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? decoder.decode(WSInbound.self, from: data),
              let client = wsClients[clientId] else { return }

        switch msg.type {
        case "transcript.partial":
            // Log only — partials don't trigger processing
            DistributedBrainDiagnostics.shared.recordFrame(accepted: false)

        case "transcript.final":
            handleTranscriptFinal(msg: msg, client: client, clientId: clientId)

        case "presence.update":
            handlePresenceUpdate(msg: msg, client: client)

        case "lease.request":
            handleLeaseRequest(msg: msg, clientId: clientId, client: client)

        case "replay.begin":
            wsClients[clientId]?.isReplayMode = true
            DistributedBrainDiagnostics.shared.recordReplayBegin()

        case "replay.end":
            wsClients[clientId]?.isReplayMode = false
            DistributedBrainDiagnostics.shared.recordReplayEnd()

        case "execution.result":
            handleExecutionResultMsg(msg: msg)

        case "device.hello":
            handleDeviceHelloMsg(msg: msg, clientId: clientId)

        case "ping":
            sendWS(type: "pong", payload: ["ts": Self.iso8601.string(from: Date())], to: clientId)

        default:
            break
        }
    }

    // MARK: - Inbound handlers

    private func handleTranscriptFinal(msg: WSInbound, client: WSClient, clientId: String) {
        guard let transcript = msg.payload["transcript"], !transcript.isEmpty else { return }

        let fallback = DistributedFallbackCoordinator.shared
        guard fallback.canAccept(msg.messageId) else {
            sendWS(type: "ack", payload: ["messageId": msg.messageId, "accepted": "false"], to: clientId)
            DistributedBrainDiagnostics.shared.recordFrame(accepted: false)
            return
        }

        let frame = ConversationFrame(
            id: msg.messageId,
            deviceId: client.deviceId,
            role: .user,
            transcript: transcript,
            timestamp: msg.ts ?? Date(),
            sequenceNumber: msg.seq
        )

        let inReplay = client.isReplayMode
        _ = DistributedConversationCoordinator.shared.ingest(frame)
        DistributedBrainDiagnostics.shared.recordFrame(accepted: true)
        sendWS(type: "ack", payload: ["messageId": msg.messageId, "accepted": "true"], to: clientId)

        if inReplay {
            DistributedBrainDiagnostics.shared.recordReplayFrame()
            return
        }

        // Enrich transcript with cross-device reference resolution
        var enriched = transcript
        if let ctx = DistributedReferenceResolver.shared.enrichedContext(for: transcript) {
            enriched = transcript + "\n" + ctx
        }
        onInboundTranscript?(client.deviceId, enriched)
    }

    private func handlePresenceUpdate(msg: WSInbound, client: WSClient) {
        let p = msg.payload
        func str(_ k: String) -> String? { p[k].flatMap { $0.isEmpty ? nil : $0 } }
        let level = PresenceSnapshot.AttentionLevel(rawValue: p["attentionLevel"] ?? "idle") ?? .idle
        let snapshot = PresenceSnapshot(
            deviceId: client.deviceId,
            timestamp: msg.ts ?? Date(),
            foregroundApp: str("foregroundApp"),
            foregroundWindowTitle: str("foregroundWindowTitle"),
            browserURL: str("browserURL"),
            ocrSummary: str("ocrSummary"),
            isUserPresent: p["isUserPresent"] == "true",
            attentionLevel: level,
            activeCodingFile: str("activeCodingFile"),
            activeCodingLanguage: str("activeCodingLanguage")
        )
        GlobalPresenceAggregator.shared.update(snapshot)
        GlobalAttentionCoordinator.shared.refresh()
        GlobalPresenceState.shared.refresh()
        DistributedBrainDiagnostics.shared.recordPresenceUpdate()
        DistributedEntityLinker.shared.ingestPresence(snapshot)
        onInboundPresence?(snapshot)
    }

    private func handleLeaseRequest(msg: WSInbound, clientId: String, client: WSClient) {
        let speechId = msg.payload["speechId"] ?? UUID().uuidString
        let duration = Double(msg.payload["durationSeconds"] ?? "5") ?? 5.0

        if let lease = SpeakerCoordinator.shared.acquire(
            deviceId: client.deviceId,
            speechId: speechId,
            expectedDurationSeconds: duration
        ) {
            sendWS(type: "lease.grant", payload: [
                "speechId":         lease.speechId,
                "ownerDeviceId":    lease.ownerDeviceId,
                "expectedDuration": "\(lease.expectedDurationSeconds)",
                "generation":       "\(lease.interruptionGeneration)"
            ], to: clientId)
            DistributedBrainDiagnostics.shared.leaseAcquisitions += 1
        } else {
            sendWS(type: "lease.denied", payload: [
                "speechId": speechId,
                "reason":   "lease_held"
            ], to: clientId)
        }
    }

    private func handleExecutionResultMsg(msg: WSInbound) {
        guard let requestId = msg.payload["requestId"] else { return }
        let result = ExecutionResult(
            requestId: requestId,
            success: msg.payload["success"] == "true",
            output: msg.payload["output"],
            error: msg.payload["error"],
            completedAt: msg.ts ?? Date()
        )
        RemoteExecutionCoordinator.shared.deliver(result)
        DistributedBrainDiagnostics.shared.recordExecutionReceived()
    }

    private func handleDeviceHelloMsg(msg: WSInbound, clientId: String) {
        let deviceId = msg.payload["deviceId"] ?? msg.deviceId ?? wsClients[clientId]?.deviceId ?? "unknown"
        let kind     = DeviceKind(rawValue: msg.payload["kind"] ?? "windows") ?? .windows
        let name     = msg.payload["name"] ?? deviceId

        // Update the client's deviceId if it changed from the connection-time default
        wsClients[clientId]?.deviceId = deviceId

        DistributedBrainDiagnostics.shared.markConnected(
            DeviceParticipant(id: deviceId, kind: kind, name: name,
                              lastSeenAt: Date(), isConnected: true)
        )
        sendWS(type: "hello.ack", payload: [
            "sessionId":  wsClients[clientId]?.sessionId ?? "none",
            "macVersion": "2",
            "deviceId":   "mac"
        ], to: clientId)
    }

    // MARK: - Outbound helpers

    private func sendWS(type: String, payload: [String: String], to clientId: String) {
        guard var client = wsClients[clientId] else { return }
        client.nextOutboundSeq += 1
        wsClients[clientId] = client

        let envelope: [String: Any] = [
            "type":      type,
            "messageId": UUID().uuidString,
            "deviceId":  "mac",
            "seq":       client.nextOutboundSeq,
            "ts":        Self.iso8601.string(from: Date()),
            "payload":   payload
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: data, encoding: .utf8) else { return }

        let frame = Self.encodeTextFrame(text)
        client.conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil {
                Task { @MainActor [weak self] in self?.removeWSClient(clientId) }
            }
        })
    }

    private func broadcastWS(type: String, payload: [String: String]) {
        for clientId in wsClients.keys { sendWS(type: type, payload: payload, to: clientId) }
    }

    // MARK: - Public push API (called by JarvisController)

    func pushReplyFinal(text: String, intentLabel: String? = nil) {
        broadcastWS(type: "chat.reply.final", payload: [
            "text": text,
            "intentLabel": intentLabel ?? ""
        ])
    }

    func pushReplyPartial(text: String) {
        broadcastWS(type: "chat.reply.partial", payload: ["text": text])
    }

    func pushOrchestrateSpeak(text: String) {
        broadcastWS(type: "orchestrate.speak", payload: ["text": text])
    }

    func pushOrchestrateSilent(reason: String = "mac_responding") {
        broadcastWS(type: "orchestrate.silent", payload: ["reason": reason])
    }

    func pushProactiveNotify(title: String, body: String, urgency: String = "normal") {
        broadcastWS(type: "proactive.notify", payload: [
            "title": title, "body": body, "urgency": urgency
        ])
    }

    /// Legacy compatibility shim — used by RemoteExecutionCoordinator.onSendRequest.
    func pushEvent(type: BridgeMessageType, payload: [String: String]) {
        let wsType: String
        switch type {
        case .executionRequest:      wsType = "execution.request"
        case .proactiveEvent:        wsType = "proactive.notify"
        case .speakerLeaseAcquired:  wsType = "lease.grant"
        case .speakerLeaseReleased:  wsType = "lease.released"
        case .speakerLeasePreempted: wsType = "lease.preempted"
        case .sessionStart:          wsType = "session.start"
        case .sessionEnd:            wsType = "session.end"
        case .heartbeat:             wsType = "heartbeat"
        default:
            wsType = type.rawValue
                .lowercased()
                .replacingOccurrences(of: "_", with: ".")
        }
        broadcastWS(type: wsType, payload: payload)
    }

    // MARK: - Client lifecycle

    private func removeWSClient(_ clientId: String) {
        guard let client = wsClients.removeValue(forKey: clientId) else { return }
        client.conn.cancel()
        DistributedBrainDiagnostics.shared.wsClientsConnected = wsClients.count
        DistributedFallbackCoordinator.shared.markDisconnected(client.deviceId)
        DistributedBrainDiagnostics.shared.markDisconnected(client.deviceId)
    }

    func stopAll() {
        for client in wsClients.values { client.conn.cancel() }
        wsClients.removeAll()
        DistributedBrainDiagnostics.shared.wsClientsConnected = 0
    }

    var wsClientCount: Int { wsClients.count }

    // MARK: - Legacy HTTP REST routes (retained for testing / non-WS clients)

    func handle(
        method: String, path: String,
        headers: [String: String], body: Data,
        conn: NWConnection
    ) async -> (Int, Data, String) {
        switch (method, path) {
        case ("POST", "/v2/frame"):
            return await handleIngestFrame(body: body)
        case ("POST", "/v2/presence"):
            return await handleUpdatePresence(body: body)
        case ("GET",  "/v2/session"):
            return handleGetSession()
        case ("POST", "/v2/execution/result"):
            return await handleExecutionResult(body: body)
        case ("POST", "/v2/device/hello"):
            return await handleDeviceHello(body: body, headers: headers)
        default:
            return (404, errorData("V2 endpoint not found"), "application/json")
        }
    }

    private func handleIngestFrame(body: Data) async -> (Int, Data, String) {
        guard let frame = try? decoder.decode(ConversationFrame.self, from: body) else {
            return (400, errorData("Invalid ConversationFrame JSON"), "application/json")
        }
        guard DistributedFallbackCoordinator.shared.canAccept(frame.id) else {
            DistributedBrainDiagnostics.shared.recordFrame(accepted: false)
            return (200, ackData(frameId: frame.id, accepted: false), "application/json")
        }
        _ = DistributedConversationCoordinator.shared.ingest(frame)
        DistributedBrainDiagnostics.shared.recordFrame(accepted: true)
        return (200, ackData(frameId: frame.id, accepted: true), "application/json")
    }

    private func handleUpdatePresence(body: Data) async -> (Int, Data, String) {
        guard let snapshot = try? decoder.decode(PresenceSnapshot.self, from: body) else {
            return (400, errorData("Invalid PresenceSnapshot JSON"), "application/json")
        }
        GlobalPresenceAggregator.shared.update(snapshot)
        GlobalAttentionCoordinator.shared.refresh()
        GlobalPresenceState.shared.refresh()
        DistributedBrainDiagnostics.shared.recordPresenceUpdate()
        let resp: [String: String] = ["status": "ok", "deviceId": snapshot.deviceId]
        return (200, (try? JSONEncoder().encode(resp)) ?? Data(), "application/json")
    }

    private func handleGetSession() -> (Int, Data, String) {
        if let sync = DistributedConversationCoordinator.shared.syncState(),
           let data = try? JSONEncoder().encode(sync) {
            return (200, data, "application/json")
        }
        return (200, (try? JSONEncoder().encode(["status": "no_session"])) ?? Data(), "application/json")
    }

    private func handleExecutionResult(body: Data) async -> (Int, Data, String) {
        guard let result = try? decoder.decode(ExecutionResult.self, from: body) else {
            return (400, errorData("Invalid ExecutionResult JSON"), "application/json")
        }
        RemoteExecutionCoordinator.shared.deliver(result)
        DistributedBrainDiagnostics.shared.recordExecutionReceived()
        return (200, (try? JSONEncoder().encode(["status": "ok"])) ?? Data(), "application/json")
    }

    private func handleDeviceHello(body: Data, headers: [String: String]) async -> (Int, Data, String) {
        struct HelloBody: Codable {
            let deviceId: String; let kind: String; let name: String
        }
        guard let hello = try? decoder.decode(HelloBody.self, from: body) else {
            return (400, errorData("Invalid hello JSON"), "application/json")
        }
        let participant = DeviceParticipant(
            id: hello.deviceId,
            kind: DeviceKind(rawValue: hello.kind) ?? .windows,
            name: hello.name, lastSeenAt: Date(), isConnected: true
        )
        DistributedBrainDiagnostics.shared.markConnected(participant)
        let resp: [String: String] = [
            "status":     "ok",
            "sessionId":  DistributedConversationCoordinator.shared.sessionId ?? "none",
            "macVersion": "2"
        ]
        return (200, (try? JSONEncoder().encode(resp)) ?? Data(), "application/json")
    }

    // MARK: - RFC 6455 frame codec

    /// Parses the first complete WebSocket frame from `data`.
    /// Returns (opcode, unmasked payload, bytes consumed) or nil if incomplete.
    private static func parseFrame(_ data: Data) -> (opcode: UInt8, payload: Data, consumed: Int)? {
        let bytes = Array(data)
        guard bytes.count >= 2 else { return nil }

        let opcode  = bytes[0] & 0x0F
        let masked  = (bytes[1] & 0x80) != 0
        var plen    = Int(bytes[1] & 0x7F)
        var offset  = 2

        if plen == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            plen   = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        } else if plen == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            plen = 0
            for i in 0..<8 { plen = (plen << 8) | Int(bytes[offset + i]) }
            offset += 8
        }

        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask   = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }

        guard bytes.count >= offset + plen else { return nil }

        var payload = Array(bytes[offset..<(offset + plen)])
        if masked { for i in 0..<payload.count { payload[i] ^= mask[i % 4] } }

        return (opcode, Data(payload), offset + plen)
    }

    /// Encodes text as a server→client (unmasked) WebSocket text frame.
    private static func encodeTextFrame(_ text: String) -> Data {
        let payload = Array(text.utf8)
        var frame: [UInt8] = [0x81]   // FIN + text opcode
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65_536 {
            frame.append(0x7E)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(0x7F)
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> i) & 0xFF))
            }
        }
        frame.append(contentsOf: payload)
        return Data(frame)
    }

    private static func closeFrame(code: UInt16 = 1000) -> Data {
        Data([0x88, 0x02, UInt8(code >> 8), UInt8(code & 0xFF)])
    }

    private static func pongFrame() -> Data { Data([0x8A, 0x00]) }

    // MARK: - Helpers

    private func errorData(_ msg: String) -> Data {
        (try? JSONEncoder().encode(["error": msg])) ?? Data()
    }

    private func ackData(frameId: String, accepted: Bool) -> Data {
        (try? JSONEncoder().encode(["frameId": frameId, "accepted": "\(accepted)"])) ?? Data()
    }
}
