import Foundation

final class DaemonDiagnostics {
    static let shared = DaemonDiagnostics()
    let startedAt = Date()
    var requestsServed: Int = 0
    var unauthorizedAttempts: Int = 0
    var port: Int = 8765

    // Per-platform WebSocket client counts (Task 5)
    var connectedAndroidClients: Int = 0
    var connectedWindowsClients: Int = 0
    var connectedMacClients: Int = 0
    var totalConnectedClients: Int { connectedAndroidClients + connectedWindowsClients + connectedMacClients }

    /// Legacy alias — kept for callers that still read this field.
    var connectedWebSockets: Int {
        get { totalConnectedClients }
        set { connectedAndroidClients = newValue }  // legacy write: treat as android
    }

    // Cross-device latency diagnostics
    var avgTranscriptToDaemonMs: Double = 0    // Android STT → daemon receive
    var avgDaemonRouteMs: Double = 0           // daemon route time
    var avgReplyRouteMs: Double = 0            // daemon reply route time
    var websocketRttMs: Double = 0             // latest measured WS RTT (from ping/pong)
    var totalRoundtripMs: Double = 0           // latest full command roundtrip
    var timeoutCount: Int = 0
    var staleReplyCount: Int = 0
    var supersededReplyCount: Int = 0

    // Routing diagnostics (Phase 3)
    var routedMessageCount: Int = 0
    var ignoredUnknownMessageCount: Int = 0
    var malformedMessageCount: Int = 0
    var oversizedMessageCount: Int = 0
    var nackCount: Int = 0
    var ackCount: Int = 0
    var offlineQueueDepth: Int = 0
    var offlineQueueDroppedCount: Int = 0
    var brainUnavailableCount: Int = 0
    var lastMessageType: String = ""
    var lastAndroidMessageAt: Date? = nil
    var lastWindowsMessageAt: Date? = nil
    var lastMacAppMessageAt: Date? = nil

    var uptimeSeconds: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// Copies current router state into this diagnostics object.
    /// Called on a 10-second timer from main.swift.
    func syncFromRouter() {
        let snap = DaemonMessageRouter.shared.snapshot()
        connectedMacClients     = snap.connectedMacClients
        connectedAndroidClients = snap.connectedAndroidClients
        connectedWindowsClients = snap.connectedWindowsClients
        routedMessageCount          = snap.routedMessageCount
        ignoredUnknownMessageCount  = snap.ignoredUnknownMessageCount
        malformedMessageCount       = snap.malformedMessageCount
        oversizedMessageCount       = snap.oversizedMessageCount
        nackCount                   = snap.nackCount
        ackCount                    = snap.ackCount
        offlineQueueDepth           = snap.offlineQueueDepth
        offlineQueueDroppedCount    = snap.offlineQueueDroppedCount
        brainUnavailableCount       = snap.brainUnavailableCount
        lastMessageType             = snap.lastMessageType
        lastAndroidMessageAt        = snap.lastAndroidMessageAt
        lastWindowsMessageAt        = snap.lastWindowsMessageAt
        lastMacAppMessageAt         = snap.lastMacAppMessageAt
    }

    /// Update rolling averages for daemon routing timing.
    /// Uses simple replacement (latest value) for now.
    func recordDaemonRoute(receiveMs: Double, routeMs: Double) {
        avgTranscriptToDaemonMs = receiveMs
        avgDaemonRouteMs = routeMs
    }

    func toJSON() -> String {
        let iso = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "daemon": true,
            "startedAt": iso.string(from: startedAt),
            "uptimeSeconds": uptimeSeconds,
            "requestsServed": requestsServed,
            "unauthorizedAttempts": unauthorizedAttempts,
            "connectedWebSockets": totalConnectedClients,
            "connectedAndroidClients": connectedAndroidClients,
            "connectedWindowsClients": connectedWindowsClients,
            "connectedMacClients": connectedMacClients,
            "port": port,
            // Routing diagnostics
            "routedMessageCount": routedMessageCount,
            "ignoredUnknownMessageCount": ignoredUnknownMessageCount,
            "malformedMessageCount": malformedMessageCount,
            "oversizedMessageCount": oversizedMessageCount,
            "nackCount": nackCount,
            "ackCount": ackCount,
            "offlineQueueDepth": offlineQueueDepth,
            "offlineQueueDroppedCount": offlineQueueDroppedCount,
            "brainUnavailableCount": brainUnavailableCount,
            "lastMessageType": lastMessageType,
            // Cross-device latency diagnostics
            "avgTranscriptToDaemonMs": avgTranscriptToDaemonMs,
            "avgDaemonRouteMs": avgDaemonRouteMs,
            "avgReplyRouteMs": avgReplyRouteMs,
            "websocketRttMs": websocketRttMs,
            "totalRoundtripMs": totalRoundtripMs,
            "timeoutCount": timeoutCount,
            "staleReplyCount": staleReplyCount,
            "supersededReplyCount": supersededReplyCount
        ]
        if let d = lastAndroidMessageAt { dict["lastAndroidMessageAt"] = iso.string(from: d) }
        if let d = lastWindowsMessageAt { dict["lastWindowsMessageAt"] = iso.string(from: d) }
        if let d = lastMacAppMessageAt  { dict["lastMacAppMessageAt"]  = iso.string(from: d) }
        return (try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
