import Foundation

// MARK: - Category

/// Top-level grouping for the help overlay sidebar.  Order matters — the
/// engine sorts sections by category in this declared order then by title.
enum DocumentationCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case gettingStarted
    case wakeAndListening
    case conversations
    case commands
    case overlays
    case cameraAndVision
    case newsAndMedia
    case androidIntegration
    case callsAndMessaging
    case memoryAndObsidian
    case aiProviders
    case webSearch
    case macSystem
    case proactivity
    case troubleshooting
    case privacy
    case developer
    case diagnostics
    case examples
    case currentSupport
    case limitations
    case future

    var displayTitle: String {
        switch self {
        case .gettingStarted:     return "Getting Started"
        case .wakeAndListening:   return "Wake Word & Listening"
        case .conversations:      return "Conversations"
        case .commands:           return "Commands"
        case .overlays:           return "Overlays"
        case .cameraAndVision:    return "Camera & Vision"
        case .newsAndMedia:       return "News & Media"
        case .androidIntegration: return "Android Integration"
        case .callsAndMessaging:  return "Calls & Messaging"
        case .memoryAndObsidian:  return "Memory & Obsidian"
        case .aiProviders:        return "AI Providers"
        case .webSearch:          return "Web Search"
        case .macSystem:          return "Mac System Control"
        case .proactivity:        return "Automation & Proactivity"
        case .troubleshooting:    return "Troubleshooting"
        case .privacy:            return "Privacy & Security"
        case .developer:          return "Developer Features"
        case .diagnostics:        return "Diagnostics"
        case .examples:           return "Tips & Natural Examples"
        case .currentSupport:     return "What Jarvis Currently Supports"
        case .limitations:        return "Known Limitations"
        case .future:             return "Future Features"
        }
    }

    var systemImage: String {
        switch self {
        case .gettingStarted:     return "sparkles"
        case .wakeAndListening:   return "waveform"
        case .conversations:      return "bubble.left.and.bubble.right.fill"
        case .commands:           return "keyboard"
        case .overlays:           return "rectangle.stack.fill"
        case .cameraAndVision:    return "eye.fill"
        case .newsAndMedia:       return "newspaper.fill"
        case .androidIntegration: return "antenna.radiowaves.left.and.right"
        case .callsAndMessaging:  return "phone.fill"
        case .memoryAndObsidian:  return "brain.head.profile"
        case .aiProviders:        return "cpu.fill"
        case .webSearch:          return "magnifyingglass"
        case .macSystem:          return "laptopcomputer"
        case .proactivity:        return "bell.badge.fill"
        case .troubleshooting:    return "wrench.and.screwdriver.fill"
        case .privacy:            return "lock.shield.fill"
        case .developer:          return "hammer.fill"
        case .diagnostics:        return "stethoscope"
        case .examples:           return "text.quote"
        case .currentSupport:     return "checkmark.seal.fill"
        case .limitations:        return "exclamationmark.triangle.fill"
        case .future:             return "moon.stars.fill"
        }
    }
}

// MARK: - Status

/// Runtime status badge for a section.  Drives colour pills in the
/// sidebar and lets the conversational helper say things like
/// "Gemini is configured but no API key is set."
enum DocumentationStatus: String, Codable, Hashable, Sendable {
    case enabled         // working
    case disabled        // user turned it off
    case degraded        // partial — e.g. provider configured but offline
    case notConfigured   // never set up
    case informational   // no on/off — pure docs (e.g. "Wake Word", "Getting Started")
}

// MARK: - Example

/// A single user-facing example phrase.  Kept lightweight so contributors
/// can list 6–8 examples per section without ceremony.  `followUp` is the
/// optional next step Jarvis suggests in the help overlay's "try this
/// next" footer.
struct DocumentationExample: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case commandPhrase   // direct trigger
        case followUp        // contextual follow-up to a prior action
        case contextual      // pronoun / referring follow-up
    }
    let id: UUID
    let phrase: String
    let kind: Kind
    let followUp: String?

    init(phrase: String, kind: Kind = .commandPhrase, followUp: String? = nil) {
        self.id = UUID()
        self.phrase = phrase
        self.kind = kind
        self.followUp = followUp
    }
}

// MARK: - Troubleshooting

struct DocumentationTroubleshooting: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let symptom: String
    let cause: String?
    let fix: String
    /// True when the engine detects this situation right now (e.g. Android
    /// reported offline → the "Android disconnected" troubleshooting item
    /// is marked active so the UI surfaces it at the top).
    let isActive: Bool

    init(symptom: String, cause: String? = nil, fix: String, isActive: Bool = false) {
        self.id = UUID()
        self.symptom = symptom
        self.cause = cause
        self.fix = fix
        self.isActive = isActive
    }
}

// MARK: - Section

/// One section in the living documentation.  Built freshly at query time
/// by a `DocumentationContributor` so values reflect the current state of
/// the app — enabled providers, configured tokens, connected integrations.
///
/// **Important:** `id` is stable across rebuilds and across enable/disable
/// cycles — used as the dedupe key in caches and in the "What's New"
/// diff.  `lastUpdated` reflects when the section was last regenerated.
struct DocumentationSection: Identifiable, Codable, Hashable, Sendable {
    let id: String                                // stable e.g. "android.calls"
    let category: DocumentationCategory
    let title: String
    let subtitle: String?
    let bodyMarkdown: String
    let examples: [DocumentationExample]
    let relatedSettings: [String]                 // human labels — "Settings → AI → Gemini"
    let requiredIntegrations: [String]            // e.g. ["Android bridge", "MiniMax API key"]
    let limitations: [String]
    let troubleshooting: [DocumentationTroubleshooting]
    let status: DocumentationStatus
    let lastUpdated: Date

    /// Tags used by the search index — keywords beyond the title that
    /// should hit this section.  e.g. ["call", "ring", "dial"] for the
    /// calls section.
    let searchTags: [String]

    init(id: String,
         category: DocumentationCategory,
         title: String,
         subtitle: String? = nil,
         bodyMarkdown: String,
         examples: [DocumentationExample] = [],
         relatedSettings: [String] = [],
         requiredIntegrations: [String] = [],
         limitations: [String] = [],
         troubleshooting: [DocumentationTroubleshooting] = [],
         status: DocumentationStatus = .enabled,
         searchTags: [String] = []) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.bodyMarkdown = bodyMarkdown
        self.examples = examples
        self.relatedSettings = relatedSettings
        self.requiredIntegrations = requiredIntegrations
        self.limitations = limitations
        self.troubleshooting = troubleshooting
        self.status = status
        self.lastUpdated = Date()
        self.searchTags = searchTags
    }
}

// MARK: - Search result

struct DocumentationSearchResult: Identifiable, Hashable {
    let id = UUID()
    let section: DocumentationSection
    let score: Double
    let matchedField: MatchField

    enum MatchField: String, Hashable {
        case title
        case body
        case examplePhrase
        case troubleshootingSymptom
        case tag
    }
}
