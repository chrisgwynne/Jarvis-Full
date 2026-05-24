import Foundation

// MARK: - NotificationPriority

enum NotificationPriority: Int, Codable, Comparable, CaseIterable {
    case silent    = 0  // no TTS, no toast — log only
    case passive   = 1  // toast only (no speech)
    case important = 2  // toast + TTS when not focused
    case critical  = 3  // always speaks, even in silent mode

    static func < (lhs: NotificationPriority, rhs: NotificationPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .silent:    return "Silent"
        case .passive:   return "Passive"
        case .important: return "Important"
        case .critical:  return "Critical"
        }
    }
}

// MARK: - NotificationEvent

struct NotificationEvent: Identifiable {
    let id: UUID
    let timestamp: Date
    let priority: NotificationPriority
    let title: String
    let body: String?
    let symbol: String       // SF Symbol
    let category: String     // e.g. "build", "memory", "camera"
    var delivered: Bool

    init(priority: NotificationPriority,
         title: String,
         body: String? = nil,
         symbol: String = "bell.fill",
         category: String = "general") {
        self.id = UUID()
        self.timestamp = Date()
        self.priority = priority
        self.title = title
        self.body = body
        self.symbol = symbol
        self.category = category
        self.delivered = false
    }
}

// MARK: - NotificationClassifier

/// Pure function: infers priority from source category and attention state.
struct NotificationClassifier {

    static func classify(category: String,
                         attentionState: AttentionState) -> NotificationPriority {
        let base = basePriority(for: category)
        return adjust(base, for: attentionState)
    }

    private static func basePriority(for category: String) -> NotificationPriority {
        switch category {
        case "build_failure", "crash", "camera_unavailable",
             "microphone_unavailable", "auth_failure":
            return .critical
        case "memory_save", "memory_search", "overlay_action":
            return .passive
        case "home_alert", "presence_change", "screen_watch":
            return .important
        default:
            return .passive
        }
    }

    private static func adjust(_ base: NotificationPriority,
                                for attention: AttentionState) -> NotificationPriority {
        // Downgrade non-critical notifications when user is focused/fullscreen
        if attention.suppressesNotifications && base < .critical {
            return .silent
        }
        // Downgrade important → passive when user is conversational (don't interrupt)
        if attention == .conversational && base == .important {
            return .passive
        }
        return base
    }
}
