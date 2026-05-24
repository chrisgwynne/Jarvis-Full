import Foundation

// MARK: - AttentionState

enum AttentionState: String, Codable, Equatable, CaseIterable {
    case focused           // active deep work: fullscreen, recent commands
    case passive           // present, not actively commanding
    case away              // no presence + idle > 5 min
    case conversational    // mid-dialogue with Jarvis
    case mediaConsumption  // fullscreen media app
    case fullscreenFocus   // non-media fullscreen app
    case idle              // idle > 2 min, no strong signal
    case unknown

    var displayName: String {
        switch self {
        case .focused:          return "Focused"
        case .passive:          return "Passive"
        case .away:             return "Away"
        case .conversational:   return "Conversational"
        case .mediaConsumption: return "Media"
        case .fullscreenFocus:  return "Fullscreen"
        case .idle:             return "Idle"
        case .unknown:          return "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .focused:          return "brain"
        case .passive:          return "eye"
        case .away:             return "person.slash"
        case .conversational:   return "bubble.left.and.bubble.right"
        case .mediaConsumption: return "play.rectangle"
        case .fullscreenFocus:  return "arrow.up.left.and.arrow.down.right"
        case .idle:             return "zzz"
        case .unknown:          return "questionmark.circle"
        }
    }

    /// Whether proactive notifications should be suppressed.
    var suppressesNotifications: Bool {
        switch self {
        case .focused, .fullscreenFocus, .mediaConsumption: return true
        default: return false
        }
    }

    /// Orb dim factor in ambient mode (0 = fully dim, 1 = full brightness).
    var ambientDimFactor: Double {
        switch self {
        case .away:   return 0.15
        case .idle:   return 0.30
        case .passive: return 0.55
        default:       return 1.0
        }
    }
}

// MARK: - AttentionSignals

struct AttentionSignals {
    var presenceDetected: Bool    // camera presence
    var isConversational: Bool    // in convo follow-up window
    var isSpeaking: Bool          // TTS active
    var isListening: Bool         // STT active
    var isFullscreen: Bool        // frontmost app is fullscreen
    var activeAppName: String
    var idleSeconds: Double       // seconds since last HID event
    var overlayOpen: Bool         // any Jarvis overlay visible
    var screenWatching: Bool
    var cameraWatching: Bool
}
