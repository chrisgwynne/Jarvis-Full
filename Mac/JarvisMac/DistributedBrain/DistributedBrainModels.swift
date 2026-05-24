import Foundation

// MARK: - DeviceKind

enum DeviceKind: String, Codable, Sendable {
    case mac
    case windows
    case android
    case mobile
}

// MARK: - DeviceParticipant

struct DeviceParticipant: Codable, Identifiable, Sendable {
    let id: String
    let kind: DeviceKind
    let name: String
    var lastSeenAt: Date
    var isConnected: Bool

    var shortDescription: String { "\(name) (\(kind.rawValue))" }
}

// MARK: - ConversationFrame

/// A single conversational turn arriving from any device.
/// Sequence numbers are per-device; the coordinator merges and deduplicates.
struct ConversationFrame: Codable, Identifiable, Sendable {
    let id: String
    let deviceId: String
    let role: FrameRole
    let transcript: String
    let timestamp: Date
    let sequenceNumber: Int
    var intentLabel: String?
    var emotionalTone: String?

    enum FrameRole: String, Codable, Sendable {
        case user
        case assistant
        case system
    }
}

// MARK: - SpeakerLease

/// Global single-speaker guarantee. Only the owning device may produce audio.
/// interruptionGeneration increments on each preemption so stale leases are detectable.
struct SpeakerLease: Codable, Sendable {
    let ownerDeviceId: String
    let acquiredAt: Date
    let expectedDurationSeconds: Double
    let speechId: String
    let interruptionGeneration: Int

    var isExpired: Bool {
        Date().timeIntervalSince(acquiredAt) > expectedDurationSeconds + 2
    }
}

// MARK: - PresenceSnapshot

/// What the Windows sidecar can see: foreground app, browser URL, OCR summary, etc.
struct PresenceSnapshot: Codable, Sendable {
    let deviceId: String
    let timestamp: Date
    var foregroundApp: String?
    var foregroundWindowTitle: String?
    var browserURL: String?
    var ocrSummary: String?
    var isUserPresent: Bool
    var attentionLevel: AttentionLevel
    var activeCodingFile: String?
    var activeCodingLanguage: String?

    enum AttentionLevel: String, Codable, Sendable {
        case idle
        case browsing
        case working
        case codingFlow   // deep focus — low interruptibility
        case meeting
        case confused     // many window switches / error states
    }

    var contextOneLiner: String {
        var parts: [String] = []
        if let app = foregroundApp { parts.append(app) }
        if let file = activeCodingFile { parts.append(file) }
        if let url = browserURL, !url.isEmpty { parts.append(url) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - ExecutionKind / Request / Result

enum ExecutionKind: String, Codable, Sendable {
    case openURL
    case click
    case type
    case clipboard
    case ocr
    case screenshot
    case guidance        // speak a sentence on the Windows device
    case scrollTo
    case focusWindow
}

struct ExecutionRequest: Codable, Identifiable, Sendable {
    let id: String
    let kind: ExecutionKind
    let payload: [String: String]
    let timeoutSeconds: Double
    var priority: ExecutionPriority

    enum ExecutionPriority: Int, Codable, Sendable {
        case low = 0, normal = 1, high = 2, critical = 3
    }
}

struct ExecutionResult: Codable, Sendable {
    let requestId: String
    let success: Bool
    var output: String?
    var error: String?
    let completedAt: Date
}

// MARK: - OrchestrationDecision

struct OrchestrationDecision: Sendable {
    let respondingDeviceId: String
    let verbosity: Verbosity
    let shouldSpeak: Bool
    let shouldShowOverlay: Bool
    let reason: String

    enum Verbosity: String, Sendable {
        case full       // complete answer
        case brief      // one sentence
        case silent     // act only, no voice
        case delegate   // hand to Windows
    }
}

// MARK: - BridgeMessageV2 / BridgeMessageType

enum BridgeMessageType: String, Codable, Sendable {
    case conversationFrame     = "CONVERSATION_FRAME"
    case presenceUpdate        = "PRESENCE_UPDATE"
    case speakerLeaseAcquired  = "SPEAKER_LEASE_ACQUIRED"
    case speakerLeaseReleased  = "SPEAKER_LEASE_RELEASED"
    case speakerLeasePreempted = "SPEAKER_LEASE_PREEMPTED"
    case proactiveEvent        = "PROACTIVE_EVENT"
    case executionRequest      = "EXECUTION_REQUEST"
    case executionResult       = "EXECUTION_RESULT"
    case sessionStart          = "SESSION_START"
    case sessionEnd            = "SESSION_END"
    case heartbeat             = "HEARTBEAT"
    case acknowledgement       = "ACK"
}

struct BridgeMessageV2: Codable, Sendable {
    let messageId: String
    let sequenceNumber: Int
    let type: BridgeMessageType
    let deviceId: String
    let timestamp: Date
    var payload: [String: String]

    static func heartbeat(from deviceId: String, seq: Int) -> BridgeMessageV2 {
        BridgeMessageV2(
            messageId: UUID().uuidString,
            sequenceNumber: seq,
            type: .heartbeat,
            deviceId: deviceId,
            timestamp: Date(),
            payload: [:]
        )
    }
}

// MARK: - SessionSyncState

struct SessionSyncState: Codable, Sendable {
    let sessionId: String
    let startedAt: Date
    let participantCount: Int
    let lastSequenceNumber: Int
    let macSequenceNumber: Int
    var diverged: Bool
}
