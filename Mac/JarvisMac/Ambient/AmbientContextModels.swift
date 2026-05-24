import Foundation

// MARK: - ActiveApp

struct ActiveApp: Equatable, Sendable {
    var name: String
    var bundleID: String
    var windowTitle: String
    var timestamp: Date

    static let none = ActiveApp(name: "", bundleID: "", windowTitle: "", timestamp: .distantPast)

    var isEmpty: Bool { name.isEmpty }
}

// MARK: - ScreenContextSummary

/// Compact semantic summary produced after a screen sample.
/// Raw screenshots are NOT stored here — only the derived text.
struct ScreenContextSummary: Equatable, Sendable {
    var activeApp: String
    var bundleID: String
    var windowTitle: String
    /// Human-readable task description, e.g. "Editing Swift in Cursor"
    var detectedTask: String
    /// Notable entities visible: filenames, repo names, PR titles
    var visibleEntities: [String]
    /// Error strings or dialog titles detected via OCR
    var visibleErrors: [String]
    /// First-pass OCR text (truncated summary, not full text)
    var ocrTextSummary: String
    /// Heuristic confidence 0–1
    var confidence: Double
    /// True if privacy filter suppressed capture for this app
    var isRedacted: Bool
    var timestamp: Date

    static let empty = ScreenContextSummary(
        activeApp: "", bundleID: "", windowTitle: "",
        detectedTask: "", visibleEntities: [], visibleErrors: [],
        ocrTextSummary: "", confidence: 0, isRedacted: false,
        timestamp: .distantPast
    )

    var isEmpty: Bool { activeApp.isEmpty }

    /// One-line spoken form for Jarvis responses.
    var spokenDescription: String {
        if isRedacted { return "Context is redacted for a private app." }
        if detectedTask.isEmpty && activeApp.isEmpty { return "I can't determine your current task." }
        if detectedTask.isEmpty { return "You're using \(activeApp)." }
        return detectedTask
    }
}

// MARK: - WatchModeState

enum WatchModeState: Equatable, Sendable {
    case inactive
    /// Active watch: increased sampling, focused on targetApp if set.
    case active(startedAt: Date, expiresAt: Date, targetApp: String?)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var targetApp: String? {
        if case .active(_, _, let app) = self { return app }
        return nil
    }

    var expiresAt: Date? {
        if case .active(_, let exp, _) = self { return exp }
        return nil
    }

    var timeRemaining: TimeInterval? {
        guard let exp = expiresAt else { return nil }
        return max(0, exp.timeIntervalSinceNow)
    }
}

// MARK: - ContextConfidence

/// Quantified confidence in Jarvis's understanding of the current user context.
/// Used to gate whether proactive responses or spoken summaries are reliable enough.
enum ContextConfidenceLevel: String, Equatable, Sendable {
    case unknown  = "unknown"
    case low      = "low"
    case medium   = "medium"
    case high     = "high"

    var shouldSpeak: Bool  { self == .medium || self == .high }
    var shouldProact: Bool { self == .high }
}

struct ContextConfidence: Equatable, Sendable {
    /// 0.0 – 1.0 raw score
    var score: Double
    /// When this confidence was last calculated
    var measuredAt: Date
    /// Time-decayed freshness: 1.0 = just measured, 0.0 = older than maxAge
    var freshness: Double

    var level: ContextConfidenceLevel {
        let effective = score * freshness
        switch effective {
        case 0.75...:  return .high
        case 0.45...:  return .medium
        case 0.1...:   return .low
        default:        return .unknown
        }
    }

    var shouldSpeak: Bool  { level.shouldSpeak }
    var shouldProact: Bool { level.shouldProact }

    static let zero = ContextConfidence(score: 0, measuredAt: .distantPast, freshness: 0)

    /// Returns a copy decayed by `seconds` — reduces freshness towards zero.
    func decayed(by seconds: TimeInterval, halfLife: TimeInterval = 120) -> ContextConfidence {
        let decay = pow(0.5, seconds / halfLife)
        return ContextConfidence(score: score, measuredAt: measuredAt, freshness: freshness * decay)
    }
}

// MARK: - AmbientContext

/// The live ambient picture Jarvis maintains passively.
struct AmbientContext: Equatable, Sendable {
    var activeApp: ActiveApp = .none
    var previousApp: ActiveApp = .none
    var latestSummary: ScreenContextSummary = .empty
    var watchMode: WatchModeState = .inactive
    var isEnabled: Bool = true
    var lastAppChangeAt: Date? = nil
    var lastSummaryAt: Date? = nil
    var recentAppHistory: [ActiveApp] = []    // last 10 apps, newest first

    /// Short textual description suitable for LLM injection.
    var contextDescription: String {
        var parts: [String] = []
        if !activeApp.isEmpty {
            parts.append("Active app: \(activeApp.name)")
            if !activeApp.windowTitle.isEmpty {
                parts.append("Window: \(activeApp.windowTitle)")
            }
        }
        if !latestSummary.isEmpty && !latestSummary.isRedacted {
            if !latestSummary.detectedTask.isEmpty {
                parts.append("Task: \(latestSummary.detectedTask)")
            }
            if !latestSummary.visibleErrors.isEmpty {
                parts.append("Errors: \(latestSummary.visibleErrors.joined(separator: "; "))")
            }
        }
        if watchMode.isActive {
            parts.append("Watch mode active")
        }
        return parts.joined(separator: "\n")
    }
}
