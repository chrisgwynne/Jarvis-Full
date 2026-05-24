import Foundation

// MARK: - ProactiveEvent

/// A normalized proactive event that can come from any integration source.
/// All sources publish here; the ProactivityOrchestrator decides delivery timing.
struct ProactiveEvent: Identifiable {
    let id: UUID
    let source: ProactiveEventSource
    let urgency: ProactiveUrgency
    let confidence: Double
    let title: String
    let body: String
    let timestamp: Date
    let expiresAt: Date?
    let relatedEntity: String?
    let isActionable: Bool
    /// 0 = never interrupt; 1 = always interrupt. Computed by source, respected by AttentionPolicy.
    let interruptibilityScore: Double

    var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return Date() > exp
    }

    init(
        id: UUID = UUID(),
        source: ProactiveEventSource,
        urgency: ProactiveUrgency,
        confidence: Double = 0.85,
        title: String,
        body: String,
        expiresAt: Date? = nil,
        relatedEntity: String? = nil,
        isActionable: Bool = false,
        interruptibilityScore: Double? = nil
    ) {
        self.id = id
        self.source = source
        self.urgency = urgency
        self.confidence = confidence
        self.title = title
        self.body = body
        self.timestamp = Date()
        self.expiresAt = expiresAt
        self.relatedEntity = relatedEntity
        self.isActionable = isActionable
        self.interruptibilityScore = interruptibilityScore ?? urgency.defaultInterruptibilityScore
    }
}

// MARK: - ProactiveEventSource

enum ProactiveEventSource: String, Codable, CaseIterable {
    case calendar       = "calendar"
    case todoist        = "todoist"
    case github         = "github"
    case homeAssistant  = "home_assistant"
    case shopify        = "shopify"
    case email          = "email"
    case news           = "news"
    case diagnostics    = "diagnostics"
    case wifi           = "wifi"
    case location       = "location"
    case camera         = "camera"
    case projectState   = "project_state"
    case system         = "system"
    case voice          = "voice"
    case brain          = "brain"

    var displayName: String {
        switch self {
        case .calendar:      return "Calendar"
        case .todoist:       return "Tasks"
        case .github:        return "GitHub"
        case .homeAssistant: return "Home"
        case .shopify:       return "Shopify"
        case .email:         return "Mail"
        case .news:          return "News"
        case .diagnostics:   return "Diagnostics"
        case .wifi:          return "Network"
        case .location:      return "Location"
        case .camera:        return "Camera"
        case .projectState:  return "Project"
        case .system:        return "System"
        case .voice:         return "Voice"
        case .brain:         return "Brain"
        }
    }
}

// MARK: - ProactiveUrgency

enum ProactiveUrgency: String, Comparable, Codable {
    case critical = "critical"
    case high     = "high"
    case normal   = "normal"
    case low      = "low"

    static func < (lhs: ProactiveUrgency, rhs: ProactiveUrgency) -> Bool {
        let order: [ProactiveUrgency] = [.low, .normal, .high, .critical]
        guard let li = order.firstIndex(of: lhs),
              let ri = order.firstIndex(of: rhs) else { return false }
        return li < ri
    }

    var defaultInterruptibilityScore: Double {
        switch self {
        case .critical: return 1.0
        case .high:     return 0.85
        case .normal:   return 0.55
        case .low:      return 0.25
        }
    }

    /// Minimum seconds between events of this urgency from the same source.
    var defaultCooldownSeconds: Double {
        switch self {
        case .critical: return 0
        case .high:     return 30
        case .normal:   return 120
        case .low:      return 300
        }
    }
}

// MARK: - ProactiveDeliveryDecision

enum ProactiveDeliveryDecision: String {
    case speakNow      = "speak_now"
    case defer_        = "defer"
    case bundle        = "bundle"
    case overlayOnly   = "overlay_only"
    case silentMemory  = "silent_memory"
    case suppress      = "suppress"
}
