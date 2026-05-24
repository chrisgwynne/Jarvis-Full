import Foundation
import Network
import OSLog

private let routerLogger = Logger(subsystem: "com.jarvis.brain", category: "router")

// MARK: - Connected client handle

struct RouterClient {
    let id: String            // internal client UUID
    let deviceId: String      // authenticated device ID
    let platform: String      // "android" | "windows" | "mac"
    let conn: NWConnection
    var capabilities: [String]
    var routedMessages: Int = 0
    var rejectedMessages: Int = 0
    var lastError: String = ""
}

// MARK: - Router

/// Routes DaemonMessageEnvelope between connected clients.
/// Thread-safety: all access must be on `queue`.
final class DaemonMessageRouter {
    static let shared = DaemonMessageRouter()

    // Clients keyed by internal client ID
    private var clients: [String: RouterClient] = [:]
    private let queue = DispatchQueue(label: "com.jarvis.brain.router")

    // Diagnostics (read from any thread — behind lock via queue.sync)
    private(set) var routedMessageCount = 0
    private(set) var ignoredUnknownMessageCount = 0
    private(set) var malformedMessageCount = 0
    private(set) var oversizedMessageCount = 0
    private(set) var nackCount = 0
    private(set) var ackCount = 0
    private(set) var brainUnavailableCount = 0
    private(set) var lastMessageType = ""
    private(set) var lastAndroidMessageAt: Date? = nil
    private(set) var lastWindowsMessageAt: Date? = nil
    private(set) var lastMacAppMessageAt: Date? = nil

    // MARK: - Client lifecycle

    func registerClient(id: String, deviceId: String, platform: String,
                        conn: NWConnection, capabilities: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.clients[id] = RouterClient(
                id: id, deviceId: deviceId, platform: platform,
                conn: conn, capabilities: capabilities
            )
            routerLogger.info("router: client registered id=\(id) platform=\(platform) deviceId=\(deviceId)")
            // Drain offline queue for Mac app
            if platform == "mac" {
                let pending = DaemonOfflineQueue.shared.drain()
                for env in pending {
                    self.deliver(env, to: id)
                }
                if !pending.isEmpty {
                    routerLogger.info("router: drained \(pending.count) queued messages to Mac app")
                }
            }
        }
    }

    func unregisterClient(id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if let c = self.clients.removeValue(forKey: id) {
                routerLogger.info("router: client unregistered id=\(id) platform=\(c.platform)")
            }
        }
    }

    // MARK: - Route incoming message

    func route(rawData: Data, fromClientId: String) {
        queue.async { [weak self] in
            guard let self else { return }

            // Oversized check (redundant but belt-and-suspenders)
            guard rawData.count <= 256 * 1024 else {
                self.oversizedMessageCount += 1
                routerLogger.warning("router: oversized message from \(fromClientId) size=\(rawData.count)")
                return
            }

            // Parse
            guard let envelope = DaemonMessageEnvelope.decode(from: rawData) else {
                self.malformedMessageCount += 1
                routerLogger.warning("router: malformed message from \(fromClientId)")
                self.sendNack(to: fromClientId, reason: "malformed", correlationId: nil)
                return
            }

            self.lastMessageType = envelope.type
            self.updateLastSeen(clientId: fromClientId, platform: envelope.sourcePlatform)

            routerLogger.debug("router: received type=\(envelope.type) from=\(envelope.sourceDeviceId) platform=\(envelope.sourcePlatform)")

            // Dispatch by type
            switch envelope.type {

            // Presence updates: consume + broadcast to others
            case "presence.update":
                self.broadcastExcluding(envelope, excludingClientId: fromClientId)
                self.routedMessageCount += 1

            // Transcript from Android/Windows → route to Mac app
            case "transcript.final":
                self.routeToMacOrQueue(envelope, fromClientId: fromClientId)

            // transcript.partial: best-effort delivery to Mac, never queued
            case "transcript.partial":
                self.routeToMacBestEffort(envelope)

            // Replies from Mac app → route to target device
            case "reply.final", "reply.partial":
                self.routeReply(envelope, fromClientId: fromClientId)

            // Mac app orchestration → target Android/Windows
            case "orchestrate.speak", "orchestrate.silent":
                self.routeOrchestration(envelope)

            // Results → Mac app (canonical)
            case "execution.result":
                self.routeToMacOrQueue(envelope, fromClientId: fromClientId)

            // Legacy result names — accepted for backward compat, logged as deprecated
            case "tool.result", "command.result":
                routerLogger.warning("router: deprecated message type=\(envelope.type) — update sender to use execution.result")
                self.routeToMacOrQueue(envelope, fromClientId: fromClientId)

            // Error report → Mac app
            case "error.report":
                self.routeToMacOrQueue(envelope, fromClientId: fromClientId)

            // Capability update: update registered client
            case "capability.update":
                if let caps = envelope.payload.objectValue?["capabilities"] {
                    if case .array(let arr) = caps {
                        let capStrings = arr.compactMap { $0.stringValue }
                        self.clients[fromClientId]?.capabilities = capStrings
                        routerLogger.info("router: capabilities updated for \(fromClientId): \(capStrings.joined(separator: ","))")
                    }
                }

            // Heartbeat/ping: update lastSeen, no routing
            case "heartbeat", "heartbeat.android", "ping", "pong", "device.hello":
                break  // already updated lastSeen above

            // Android capabilities report: store on the registered client
            case "capabilities.report":
                if let caps = envelope.payload.objectValue?["capabilities"] {
                    if case .array(let arr) = caps {
                        let capStrings = arr.compactMap { $0.stringValue }
                        self.clients[fromClientId]?.capabilities = capStrings
                        routerLogger.info("router: capabilities.report updated for \(fromClientId): \(capStrings.joined(separator: ","))")
                    }
                }

            // Proactive Android events (calls, SMS, WhatsApp, battery, etc.) → Mac
            case "android.event":
                self.routeToMacOrQueue(envelope, fromClientId: fromClientId)

            // Execution requests from Mac → Android (capability round-trip)
            case "execution.request":
                self.routeExecutionRequest(envelope, fromClientId: fromClientId)

            // Daemon diagnostics: consumed
            case "diagnostics.request":
                self.handleDiagnosticsRequest(envelope, fromClientId: fromClientId)

            // Remote action: Android → Mac (request) and Mac → Android (result)
            case "remote.action.request":
                RemoteActionRouter.shared.routeRequest(envelope, fromClientId: fromClientId, router: self)
                self.routedMessageCount += 1

            case "remote.action.result":
                RemoteActionRouter.shared.routeResult(envelope, router: self)
                self.routedMessageCount += 1

            // File transfer: Android uploads file; daemon notifies Mac
            case "file.transfer.created":
                self.routeToMacOrQueue(envelope, fromClientId: fromClientId)

            // File transfer result: Mac acknowledges pickup → back to originating Android device
            case "file.transfer.result":
                let deviceId = envelope.payload.objectValue?["targetDeviceId"]?.stringValue
                if let did = deviceId, let clientId = clientId(forDeviceId: did, platform: "android") {
                    deliver(envelope, to: clientId)
                    self.routedMessageCount += 1
                } else if let clientId = clients.first(where: { $0.value.platform == "android" })?.key {
                    deliver(envelope, to: clientId)
                    self.routedMessageCount += 1
                }

            // Unknown: increment counter, log, ignore
            default:
                self.ignoredUnknownMessageCount += 1
                routerLogger.debug("router: unknown type=\(envelope.type) ignored (total=\(self.ignoredUnknownMessageCount))")
            }
        }
    }

    // MARK: - Routing helpers

    private func routeToMacOrQueue(_ env: DaemonMessageEnvelope, fromClientId: String) {
        if let macId = macClientId() {
            deliver(env, to: macId)
            routedMessageCount += 1
        } else {
            // Mac app offline — queue if replay-safe
            brainUnavailableCount += 1
            DaemonOfflineQueue.shared.enqueue(env, reason: "mac_offline")
            let depth = DaemonOfflineQueue.shared.depth
            if depth > 0 {
                routerLogger.info("router: Mac app offline — queued type=\(env.type) depth=\(depth)")
            } else {
                routerLogger.debug("router: Mac app offline — type=\(env.type) not queued (replay-unsafe)")
            }
            // Send brain_unavailable NACK to sender
            sendNack(to: fromClientId, reason: "brain_unavailable", correlationId: env.correlationId)
        }
    }

    private func routeToMacBestEffort(_ env: DaemonMessageEnvelope) {
        if let macId = macClientId() {
            deliver(env, to: macId)
            routedMessageCount += 1
        }
        // partial transcripts silently dropped when Mac is offline — ephemeral
    }

    private func routeReply(_ env: DaemonMessageEnvelope, fromClientId: String) {
        switch env.target {
        case .android(let did):
            if let clientId = clientId(forDeviceId: did, platform: "android") {
                deliver(env, to: clientId)
                routedMessageCount += 1
            }
        case .windows(let did):
            if let clientId = clientId(forDeviceId: did, platform: "windows") {
                deliver(env, to: clientId)
                routedMessageCount += 1
            }
        case .broadcast:
            broadcastExcluding(env, excludingClientId: fromClientId)
            routedMessageCount += 1
        default:
            ignoredUnknownMessageCount += 1
        }
    }

    private func routeOrchestration(_ env: DaemonMessageEnvelope) {
        switch env.target {
        case .android(let did):
            if let clientId = clientId(forDeviceId: did, platform: "android") {
                deliver(env, to: clientId)
                routedMessageCount += 1
            }
        case .windows(let did):
            if let clientId = clientId(forDeviceId: did, platform: "windows") {
                deliver(env, to: clientId)
                routedMessageCount += 1
            }
        case .broadcast:
            for (id, c) in clients where c.platform != "mac" {
                deliver(env, to: id)
            }
            routedMessageCount += 1
        default:
            break
        }
    }

    /// Routes an `execution.request` from the Mac app to the target Android device.
    /// Falls back to any connected Android client when no specific deviceId is given.
    /// NACKs the Mac if no Android client is currently connected.
    private func routeExecutionRequest(_ env: DaemonMessageEnvelope, fromClientId: String) {
        // Determine target Android client
        let targetClientId: String?
        switch env.target {
        case .android(let did):
            if let did = did, !did.isEmpty {
                // Specific device requested
                targetClientId = clientId(forDeviceId: did, platform: "android")
            } else {
                // Any connected Android
                targetClientId = clients.first(where: { $0.value.platform == "android" })?.key
            }
        default:
            // Should always be .android — if not, fall back to any Android
            targetClientId = clients.first(where: { $0.value.platform == "android" })?.key
        }

        if let clientId = targetClientId {
            deliver(env, to: clientId)
            routedMessageCount += 1
            routerLogger.info("router: execution.request routed to android \(clientId) command=\(env.payload.objectValue?["command"]?.stringValue ?? "?")")
        } else {
            routerLogger.warning("router: execution.request — no Android client connected, NACKing Mac (correlationId=\(env.correlationId ?? "?"))")
            sendNack(to: fromClientId, reason: "no_android_device", correlationId: env.correlationId)
        }
    }

    private func broadcastExcluding(_ env: DaemonMessageEnvelope, excludingClientId: String) {
        for id in clients.keys where id != excludingClientId {
            deliver(env, to: id)
        }
    }

    private func deliver(_ env: DaemonMessageEnvelope, to clientId: String) {
        guard let c = clients[clientId], let data = env.encode() else { return }
        let frame = encodeTextFrame(data)
        c.conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let err = error {
                self?.queue.async {
                    self?.clients[clientId]?.lastError = err.localizedDescription
                    self?.clients[clientId]?.rejectedMessages += 1
                }
            } else {
                self?.queue.async {
                    self?.clients[clientId]?.routedMessages += 1
                }
            }
        })
    }

    private func sendNack(to clientId: String, reason: String, correlationId: String?) {
        nackCount += 1
        let reply = DaemonMessageEnvelope.make(
            type: "nack",
            target: .daemon,
            payload: .object(["reason": .string(reason)]),
            correlationId: correlationId
        )
        deliver(reply, to: clientId)
    }

    private func handleDiagnosticsRequest(_ env: DaemonMessageEnvelope, fromClientId: String) {
        let reply = DaemonMessageEnvelope.make(
            type: "diagnostics.response",
            target: .daemon,
            payload: .object([
                "routedMessages": .int(routedMessageCount),
                "queueDepth": .int(DaemonOfflineQueue.shared.depth),
                "clients": .int(clients.count)
            ]),
            correlationId: env.correlationId
        )
        deliver(reply, to: fromClientId)
    }

    // MARK: - Public delivery helpers (used by RemoteActionRouter)

    /// Delivers an envelope to the first connected Mac client.
    /// Returns true if delivered, false if no Mac client is connected.
    func deliverToMac(_ env: DaemonMessageEnvelope) -> Bool {
        var delivered = false
        queue.sync {
            if let macId = macClientId() {
                deliver(env, to: macId)
                delivered = true
            } else {
                DaemonOfflineQueue.shared.enqueue(env, reason: "mac_offline_remote_action")
            }
        }
        return delivered
    }

    /// Delivers an envelope to the Android client with matching deviceId.
    /// Falls back to any connected Android client if deviceId doesn't match.
    /// Returns true if delivered.
    @discardableResult
    func deliverToAndroid(_ env: DaemonMessageEnvelope, deviceId: String) -> Bool {
        var delivered = false
        queue.sync {
            if let clientId = clientId(forDeviceId: deviceId, platform: "android")
                ?? clients.first(where: { $0.value.platform == "android" })?.key {
                deliver(env, to: clientId)
                delivered = true
            }
        }
        return delivered
    }

    // MARK: - Client lookups

    private func macClientId() -> String? {
        clients.first(where: { $0.value.platform == "mac" })?.key
    }

    private func clientId(forDeviceId deviceId: String?, platform: String) -> String? {
        guard let deviceId else {
            return clients.first(where: { $0.value.platform == platform })?.key
        }
        return clients.first(where: { $0.value.platform == platform && $0.value.deviceId == deviceId })?.key
    }

    private func updateLastSeen(clientId: String, platform: String) {
        switch platform {
        case "android": lastAndroidMessageAt = Date()
        case "windows": lastWindowsMessageAt = Date()
        case "mac":     lastMacAppMessageAt  = Date()
        default: break
        }
        DaemonAuthStore.shared.recordSeen(deviceId: clients[clientId]?.deviceId ?? clientId)
    }

    // MARK: - RFC 6455 text frame encoding (no AppKit dep)

    private func encodeTextFrame(_ payload: Data) -> Data {
        var frame = Data()
        frame.append(0x81)  // FIN + text opcode
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len < 65536 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> i) & 0xFF))
            }
        }
        frame.append(contentsOf: payload)
        return frame
    }

    // MARK: - Diagnostics snapshot

    struct DiagnosticsSnapshot {
        let connectedMacClients: Int
        let connectedAndroidClients: Int
        let connectedWindowsClients: Int
        let routedMessageCount: Int
        let ignoredUnknownMessageCount: Int
        let malformedMessageCount: Int
        let oversizedMessageCount: Int
        let nackCount: Int
        let ackCount: Int
        let offlineQueueDepth: Int
        let offlineQueueDroppedCount: Int
        let brainUnavailableCount: Int
        let lastMessageType: String
        let lastAndroidMessageAt: Date?
        let lastWindowsMessageAt: Date?
        let lastMacAppMessageAt: Date?
        let deviceSummaries: [DeviceSummary]
    }

    struct DeviceSummary {
        let deviceId: String
        let platform: String
        let capabilities: [String]
        let routedMessages: Int
        let rejectedMessages: Int
        let lastError: String
    }

    func snapshot() -> DiagnosticsSnapshot {
        queue.sync {
            DiagnosticsSnapshot(
                connectedMacClients:     clients.values.filter { $0.platform == "mac" }.count,
                connectedAndroidClients: clients.values.filter { $0.platform == "android" }.count,
                connectedWindowsClients: clients.values.filter { $0.platform == "windows" }.count,
                routedMessageCount:          routedMessageCount,
                ignoredUnknownMessageCount:  ignoredUnknownMessageCount,
                malformedMessageCount:       malformedMessageCount,
                oversizedMessageCount:       oversizedMessageCount,
                nackCount:                   nackCount,
                ackCount:                    ackCount,
                offlineQueueDepth:           DaemonOfflineQueue.shared.depth,
                offlineQueueDroppedCount:    DaemonOfflineQueue.shared.droppedCount,
                brainUnavailableCount:       brainUnavailableCount,
                lastMessageType:             lastMessageType,
                lastAndroidMessageAt:        lastAndroidMessageAt,
                lastWindowsMessageAt:        lastWindowsMessageAt,
                lastMacAppMessageAt:         lastMacAppMessageAt,
                deviceSummaries: clients.values.map {
                    DeviceSummary(
                        deviceId: $0.deviceId,
                        platform: $0.platform,
                        capabilities: $0.capabilities,
                        routedMessages: $0.routedMessages,
                        rejectedMessages: $0.rejectedMessages,
                        lastError: $0.lastError
                    )
                }
            )
        }
    }
}
