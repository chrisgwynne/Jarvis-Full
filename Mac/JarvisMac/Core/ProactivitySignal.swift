import Foundation

// MARK: - Signal source

/// Identifies which integration produced a ProactivitySignal.
/// Future providers (Shopify, Todoist, calendar…) add a new case here.
enum SignalSource: String, Codable, CaseIterable {
    case news           = "news"
    case shopify        = "shopify"
    case todoist        = "todoist"
    case calendar       = "calendar"
    case email          = "email"
    case homeAssistant  = "home_assistant"
    case github         = "github"
    case system         = "system"
    case memory         = "memory"
    case obsidian       = "obsidian"
    case android        = "android"

    var displayName: String {
        switch self {
        case .news:          return "News"
        case .shopify:       return "Shopify"
        case .todoist:       return "Todoist"
        case .calendar:      return "Calendar"
        case .email:         return "Email"
        case .homeAssistant: return "Home"
        case .github:        return "GitHub"
        case .system:        return "System"
        case .memory:        return "Memory"
        case .obsidian:      return "Obsidian"
        case .android:       return "Phone"
        }
    }

    var systemImage: String {
        switch self {
        case .news:          return "newspaper.fill"
        case .shopify:       return "bag.fill"
        case .todoist:       return "checkmark.circle.fill"
        case .calendar:      return "calendar"
        case .email:         return "envelope.fill"
        case .homeAssistant: return "house.fill"
        case .github:        return "chevron.left.forwardslash.chevron.right"
        case .system:        return "cpu.fill"
        case .memory:        return "brain.head.profile"
        case .obsidian:      return "note.text"
        case .android:       return "iphone"
        }
    }

    var accentColor: String {
        switch self {
        case .news:          return "cyan"
        case .shopify:       return "green"
        case .todoist:       return "red"
        case .calendar:      return "blue"
        case .email:         return "orange"
        case .homeAssistant: return "yellow"
        case .github:        return "purple"
        case .system:        return "teal"
        case .memory:        return "indigo"
        case .obsidian:      return "purple"
        case .android:       return "green"
        }
    }
}

// MARK: - Priority

enum SignalPriority: Int, Codable, Comparable {
    case low      = 1
    case normal   = 2
    case high     = 3
    case urgent   = 4
    case critical = 5

    static func < (lhs: SignalPriority, rhs: SignalPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .low:      return "Low"
        case .normal:   return "Normal"
        case .high:     return "High"
        case .urgent:   return "Urgent"
        case .critical: return "Critical"
        }
    }

    var badgeColor: String {
        switch self {
        case .low:      return "gray"
        case .normal:   return "blue"
        case .high:     return "orange"
        case .urgent:   return "red"
        case .critical: return "red"
        }
    }
}

// MARK: - Decision

/// What the ProactivityEngine decided to do with a signal.
enum ProactivityDecision: String {
    case ignore        = "ignore"
    case logOnly       = "log_only"
    case showQuietly   = "show_quietly"
    case showOverlay   = "show_overlay"
    case speakNow      = "speak_now"
    case askUser       = "ask_user"
}

// MARK: - Signal

/// A proactivity event emitted by any integration or system source.
/// The ProactivityEngine receives signals and decides what action to take.
struct ProactivitySignal: Identifiable {
    let id: String
    let source: SignalSource
    let title: String
    let body: String
    let category: String
    let priority: SignalPriority
    let confidence: Double           // 0–1, how confident the source is this matters
    let createdAt: Date
    let expiresAt: Date?
    let dedupeKey: String            // prevents the same story from announcing twice
    let suggestedAction: String?     // e.g. "open_article", "open_email"
    let spokenText: String?          // overrides default TTS text if provided
    let requiresAttention: Bool
    let sourceArticleID: String?     // links back to a NewsArticle.id (news signals)

    // MARK: - Overlay routing overrides

    /// Override the overlay kind that `ProactivityPresentation` would normally
    /// derive from `source.preferredOverlayKind`. Used when a signal targets
    /// a specific overlay (e.g. `.haCamera` for a doorbell/motion alert).
    let overlayKind: OverlayKind?

    /// Arbitrary payload forwarded to the overlay when it opens.
    /// For `.haCamera` this is the camera entity ID (e.g. `"camera.front_door"`).
    let overlayPayload: String?

    init(
        id: String = UUID().uuidString,
        source: SignalSource,
        title: String,
        body: String,
        category: String = "",
        priority: SignalPriority = .normal,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        dedupeKey: String,
        suggestedAction: String? = nil,
        spokenText: String? = nil,
        requiresAttention: Bool = false,
        sourceArticleID: String? = nil,
        overlayKind: OverlayKind? = nil,
        overlayPayload: String? = nil
    ) {
        self.id              = id
        self.source          = source
        self.title           = title
        self.body            = body
        self.category        = category
        self.priority        = priority
        self.confidence      = confidence
        self.createdAt       = createdAt
        self.expiresAt       = expiresAt
        self.dedupeKey       = dedupeKey
        self.suggestedAction = suggestedAction
        self.spokenText      = spokenText
        self.requiresAttention = requiresAttention
        self.sourceArticleID = sourceArticleID
        self.overlayKind     = overlayKind
        self.overlayPayload  = overlayPayload
    }
}

// MARK: - Source → overlay mapping

extension SignalSource {
    /// The preferred `OverlayKind` for signals from this source.
    ///
    /// Sources whose overlay is not yet implemented return `.proactiveAlert`
    /// which renders a generic title/body/action card. Replace the case with
    /// the real overlay kind once that integration's overlay is built.
    var preferredOverlayKind: OverlayKind {
        switch self {
        case .news:          return .news            // ✓ implemented
        case .memory:        return .memory          // ✓ implemented
        case .system:        return .test            // diagnostics → Status overlay
        case .shopify:       return .shopify
        case .todoist:       return .tasks
        case .calendar:      return .calendar
        case .email:         return .proactiveAlert  // future: .email
        case .homeAssistant: return .home   // camera alerts override to .haCamera via signal.overlayKind
        case .github:        return .github
        case .obsidian:      return .obsidian
        case .android:       return .phone    // call events open dedicated Phone overlay
        }
    }
}

// MARK: - Provider protocol (stub for future integrations)

/// Any integration that wants to emit proactivity signals conforms to this.
/// The engine calls `start()` / `stop()` on the main actor; signals arrive
/// via the engine's `ingest(_:appState:)` entry point.
///
/// Annotated `@MainActor` so the conformance is statically isolated on the
/// main actor — every current implementation (`CalendarProactivityProvider`,
/// `TodoistProactivityProvider`, etc.) is already `@MainActor`-marked, so
/// this only formalises the existing invariant.  Removes the Swift 6
/// "conformance crosses into main actor-isolated code" warnings on all
/// seven providers without changing runtime behaviour.
@MainActor
protocol ProactivitySignalProvider: AnyObject {
    nonisolated var source: SignalSource { get }
    func start()
    func stop()
    func pollNow() async
}
