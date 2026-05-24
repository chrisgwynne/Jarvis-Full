import Foundation
import OSLog

private let actionLogger = Logger(subsystem: "com.jarvis.brain", category: "remote-action")

/// Tracks pending remote.action.request messages and routes results back to origin.
final class RemoteActionRouter {
    static let shared = RemoteActionRouter()

    private struct PendingAction {
        let sourceClientId: String      // internal router client ID of the Android device
        let sourceDeviceId: String      // Android device ID (for result targeting)
        let enqueuedAt: Date
    }

    private var pending: [String: PendingAction] = [:]  // requestId → PendingAction
    private let lock = NSLock()
    private let timeoutSeconds: TimeInterval = 30

    private(set) var pendingCount: Int = 0
    private(set) var routedRequests: Int = 0
    private(set) var routedResults: Int = 0
    private(set) var timedOut: Int = 0
    private(set) var macUnavailableDrops: Int = 0

    // MARK: - Route request (Android → Mac)

    func routeRequest(_ env: DaemonMessageEnvelope, fromClientId: String, router: DaemonMessageRouter) {
        let requestId = env.payload.objectValue?["requestId"]?.stringValue ?? env.id
        let sourceDeviceId = env.sourceDeviceId

        lock.withLock {
            evictExpired()
            pending[requestId] = PendingAction(
                sourceClientId: fromClientId,
                sourceDeviceId: sourceDeviceId,
                enqueuedAt: Date()
            )
            pendingCount = pending.count
        }

        // Route to Mac client. If Mac offline, NACK Android with mac_client_unavailable.
        let delivered = router.deliverToMac(env)
        if delivered {
            routedRequests += 1
            actionLogger.info("remote-action: request routed to Mac requestId=\(requestId) action=\(env.payload.objectValue?["action"]?.stringValue ?? "?")")
        } else {
            lock.withLock {
                pending.removeValue(forKey: requestId)
                pendingCount = pending.count
            }
            macUnavailableDrops += 1
            actionLogger.warning("remote-action: Mac unavailable for requestId=\(requestId) — sending nack")
            // Return mac_client_unavailable result directly to Android
            let resultPayload: JSONValue = .object([
                "requestId": .string(requestId),
                "routeId": env.payload.objectValue?["routeId"] ?? .string(requestId),
                "targetDeviceId": .string(sourceDeviceId),
                "success": .bool(false),
                "errorCode": .string("mac_client_unavailable"),
                "errorMessage": .string("The Mac is not connected."),
                "spokenSummary": .string("The Mac is not connected."),
                "timestamp": .string(ISO8601DateFormatter().string(from: Date()))
            ])
            let result = DaemonMessageEnvelope.make(
                type: "remote.action.result",
                target: .android(deviceId: sourceDeviceId),
                payload: resultPayload,
                correlationId: requestId
            )
            router.deliverToAndroid(result, deviceId: sourceDeviceId)
        }
    }

    // MARK: - Route result (Mac → Android)

    func routeResult(_ env: DaemonMessageEnvelope, router: DaemonMessageRouter) {
        let requestId = env.payload.objectValue?["requestId"]?.stringValue
                    ?? env.correlationId
                    ?? ""

        let pendingAction: PendingAction? = lock.withLock {
            evictExpired()
            return self.pending.removeValue(forKey: requestId).map { p in
                self.pendingCount = self.pending.count
                return p
            }
        }

        guard let p = pendingAction else {
            actionLogger.debug("remote-action: result for unknown/expired requestId=\(requestId) — discarding")
            return
        }

        let deviceId = env.payload.objectValue?["targetDeviceId"]?.stringValue ?? p.sourceDeviceId
        let delivered = router.deliverToAndroid(env, deviceId: deviceId)
        if delivered {
            routedResults += 1
            actionLogger.info("remote-action: result routed to Android deviceId=\(deviceId) requestId=\(requestId)")
        } else {
            actionLogger.warning("remote-action: Android deviceId=\(deviceId) not connected for result requestId=\(requestId)")
        }
    }

    // MARK: - Timeout cleanup

    private func evictExpired() {
        let cutoff = Date().addingTimeInterval(-timeoutSeconds)
        let before = pending.count
        pending = pending.filter { $0.value.enqueuedAt >= cutoff }
        let evicted = before - pending.count
        if evicted > 0 {
            timedOut += evicted
            pendingCount = pending.count
            actionLogger.debug("remote-action: evicted \(evicted) timed-out pending requests")
        }
    }

    var diagnosticsSummary: String {
        lock.withLock {
            "pending=\(pending.count) routedReqs=\(routedRequests) routedResults=\(routedResults) timedOut=\(timedOut) macUnavailable=\(macUnavailableDrops)"
        }
    }
}
