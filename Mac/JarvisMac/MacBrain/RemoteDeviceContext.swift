import Foundation

// MARK: - RemoteDeviceContext

/// Carries the identity and capabilities of the remote device that sent a transcript.
/// Flows through command routing, response generation, and output routing.
struct RemoteDeviceContext: Codable, Sendable {
    let deviceId: String
    let platform: String       // "android" | "windows"
    let deviceName: String?
    let capabilities: [String]
    let receivedAt: Date
    let routeId: String        // used for dedup and reply correlation
}

// MARK: - RemoteBrainResponse

/// The result of processing a remote transcript through the Mac brain.
struct RemoteBrainResponse: Sendable {
    enum Outcome: Sendable {
        case reply(text: String, speak: Bool, display: Bool)
        case commandResult(text: String, intentLabel: String)
        case error(reason: String)
        case ignored(reason: String)
    }
    let outcome: Outcome
    let routeId: String
    let handledAt: Date

    static func reply(_ text: String, routeId: String, speak: Bool = false,
                      display: Bool = true) -> RemoteBrainResponse {
        RemoteBrainResponse(outcome: .reply(text: text, speak: speak, display: display),
                            routeId: routeId, handledAt: Date())
    }
    static func error(_ reason: String, routeId: String) -> RemoteBrainResponse {
        RemoteBrainResponse(outcome: .error(reason: reason), routeId: routeId, handledAt: Date())
    }
    static func ignored(_ reason: String, routeId: String) -> RemoteBrainResponse {
        RemoteBrainResponse(outcome: .ignored(reason: reason), routeId: routeId, handledAt: Date())
    }
}

// MARK: - RemoteToolPermission

/// Policy check result for tool execution from a remote device.
enum RemoteToolPermission {
    case allowed
    case requiresConfirmation
    case denied(reason: String)
}
