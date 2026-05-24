import Foundation

// MARK: - PhraseMatchType

enum PhraseMatchType: String, Codable, CaseIterable, Identifiable {
    case exact
    case contains
    case startsWith
    case regex
    case fuzzy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .exact:      return "Exact"
        case .contains:   return "Contains"
        case .startsWith: return "Starts with"
        case .regex:      return "Regex"
        case .fuzzy:      return "Fuzzy"
        }
    }

    var helpText: String {
        switch self {
        case .exact:
            return "Input must equal the phrase exactly (after normalization)."
        case .contains:
            return "Input must contain the phrase as a substring."
        case .startsWith:
            return "Input must begin with the phrase."
        case .regex:
            return "Input must match the regular expression pattern."
        case .fuzzy:
            return "Input must be sufficiently similar — tolerates minor typos and word omissions."
        }
    }
}

// MARK: - SafetyLevel

enum SafetyLevel: String, Codable, CaseIterable, Identifiable {
    /// UI / overlay commands — fuzzy match acceptable.
    case low
    /// Moderate risk — conservative matching, no fuzzy.
    case medium
    /// High risk — exact match required, may require confirmation.
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }
}

// MARK: - CommandCategory

enum CommandCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    case news
    case camera
    case ui
    case overlays
    case time
    case memory
    case screen
    case system
    case smallTalk
    case listening
    // macOS system control
    case apps
    case systemSettings
    case volume
    case files
    case windows
    case homeAssistant
    case calendar
    case todoist
    case github
    case music
    case shopify
    case reddit
    case email

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .news:           return "News"
        case .camera:         return "Camera"
        case .ui:             return "UI"
        case .overlays:       return "Overlays"
        case .time:           return "Time"
        case .memory:         return "Memory"
        case .screen:         return "Screen"
        case .system:         return "System"
        case .smallTalk:      return "Small Talk"
        case .listening:      return "Listening"
        case .apps:           return "Apps"
        case .systemSettings: return "Settings"
        case .volume:         return "Volume"
        case .files:          return "Files"
        case .windows:        return "Windows"
        case .homeAssistant:  return "Home Assistant"
        case .calendar:       return "Calendar"
        case .todoist:        return "Todoist"
        case .github:         return "GitHub"
        case .music:          return "Music"
        case .shopify:        return "Shopify"
        case .reddit:         return "Reddit"
        case .email:          return "Email"
        }
    }

    var systemImage: String {
        switch self {
        case .news:           return "newspaper.fill"
        case .camera:         return "camera.fill"
        case .ui:             return "macwindow"
        case .overlays:       return "rectangle.stack.fill"
        case .time:           return "clock.fill"
        case .memory:         return "brain.head.profile"
        case .screen:         return "display"
        case .system:         return "gearshape.fill"
        case .smallTalk:      return "bubble.left.fill"
        case .listening:      return "mic.fill"
        case .apps:           return "square.grid.2x2.fill"
        case .systemSettings: return "gearshape.2.fill"
        case .volume:         return "speaker.wave.2.fill"
        case .files:          return "folder.fill"
        case .windows:        return "rectangle.on.rectangle.fill"
        case .homeAssistant:  return "house.fill"
        case .calendar:       return "calendar"
        case .todoist:        return "checkmark.circle.fill"
        case .github:         return "chevron.left.forwardslash.chevron.right"
        case .music:          return "music.note"
        case .shopify:        return "bag.fill"
        case .reddit:         return "bubble.left.and.text.bubble.right"
        case .email:          return "envelope.fill"
        }
    }
}

// MARK: - CommandPhrase

struct CommandPhrase: Identifiable, Codable, Equatable {
    var id: UUID
    /// The phrase as entered by the user — shown in the UI.
    var phrase: String
    /// Pre-normalized form of `phrase`, computed once and stored for fast
    /// matching. Uses the same `TranscriptNormalizer` pipeline as incoming
    /// speech, so normalization is always symmetric.
    var normalizedPhrase: String
    var enabled: Bool
    var matchType: PhraseMatchType
    /// Tiebreak: higher priority wins when two phrases have equal confidence.
    var priority: Int
    let createdAt: Date
    var updatedAt: Date

    init(phrase: String,
         enabled: Bool = true,
         matchType: PhraseMatchType = .exact,
         priority: Int = 0) {
        self.id               = UUID()
        self.phrase           = phrase
        self.normalizedPhrase = TranscriptNormalizer.normalize(phrase)
        self.enabled          = enabled
        self.matchType        = matchType
        self.priority         = priority
        self.createdAt        = Date()
        self.updatedAt        = Date()
    }

    /// Call after editing `phrase` in the UI to keep the normalized form fresh.
    mutating func refreshNormalization() {
        normalizedPhrase = TranscriptNormalizer.normalize(phrase)
        updatedAt = Date()
    }
}

// MARK: - CommandDefinition

struct CommandDefinition: Identifiable, Codable, Equatable {
    /// Stable string identifier, e.g. "show_news". Used in persistence,
    /// `IntentMapping`, and voice-learning assignment.
    var id: String
    var displayName: String
    var category: CommandCategory
    var description: String
    var phrases: [CommandPhrase]
    var enabled: Bool
    var safetyLevel: SafetyLevel

    @discardableResult
    mutating func addPhrase(_ text: String,
                            matchType: PhraseMatchType = .exact,
                            priority: Int = 0) -> CommandPhrase {
        let p = CommandPhrase(phrase: text, matchType: matchType, priority: priority)
        phrases.append(p)
        return p
    }

    mutating func removePhrase(id phraseID: UUID) {
        phrases.removeAll { $0.id == phraseID }
    }

    mutating func updatePhrase(_ updated: CommandPhrase) {
        if let i = phrases.firstIndex(where: { $0.id == updated.id }) {
            phrases[i] = updated
        }
    }
}

// MARK: - MatchedCommand

/// Result returned by `CommandPhraseMatcher.match()`.
struct MatchedCommand {
    let commandId: String
    let displayName: String
    let matchedPhrase: String       // the stored phrase that triggered the match
    let normalizedInput: String     // the normalized transcript
    let matchType: PhraseMatchType
    let confidence: Double          // 0.0 – 1.0
    let reason: String              // human-readable explanation for diagnostics
}
