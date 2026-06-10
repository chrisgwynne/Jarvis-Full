import Foundation

// MARK: - DaemonFrameWrapper
//
// Pure transformation: a raw client WebSocket text frame → the
// DaemonMessageEnvelope-shaped JSON that DaemonMessageRouter routes.
//
// Clients (Android/Windows) send flat frames ({"type":"transcript.final",...});
// the Mac app sends pre-wrapped envelopes. This logic was extracted from
// BrainDaemonServer.wrapAndRoute so ProtocolConformanceTests can exercise the
// real wrapping rules against shared/contracts/ws-frame-examples.json without
// a network connection. No behaviour change.

enum DaemonFrameWrapper {

    /// Result of preparing a raw client frame for routing.
    enum Wrapped {
        /// Frame was already a DaemonMessageEnvelope (Mac-sent) — route as-is.
        case envelope(Data)
        /// Flat client frame, now wrapped into an envelope.
        case wrappedFlat(Data)
        /// Not JSON / not an object — drop.
        case malformed
    }

    static func prepare(rawJSON: String, fromClientId: String, platform: String) -> Wrapped {
        guard let data = rawJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }

        // If the frame is already a DaemonMessageEnvelope (Mac-sent), route directly.
        if raw["sourceDeviceId"] != nil, raw["target"] != nil {
            guard let envelopeData = try? JSONSerialization.data(withJSONObject: raw) else {
                return .malformed
            }
            return .envelope(envelopeData)
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

        guard let envelopeData = try? JSONSerialization.data(withJSONObject: envelope) else {
            return .malformed
        }
        return .wrappedFlat(envelopeData)
    }
}
