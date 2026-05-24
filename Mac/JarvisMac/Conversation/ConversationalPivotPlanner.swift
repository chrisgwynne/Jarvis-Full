import Foundation

// MARK: - InterruptionKind

enum InterruptionKind {
    case correction          // "no, after pinch specifically"
    case clarification       // "wait, which overlay?"
    case topicShift          // "actually, let's talk about X"
    case urgentCommand       // "stop—turn off the lights"
    case confirmation        // "yeah exactly"
    case expansion           // "tell me more about that part"
    case unknown
}

// MARK: - PivotContext

/// The context built by `ConversationalPivotPlanner` when an interruption occurs.
/// Passed to the LLM so it can respond naturally to the interruption without
/// losing the thread of what was being said.
struct PivotContext {
    /// Sentences Jarvis had already spoken before the interruption.
    let spokenClauses: [String]
    /// Sentences Jarvis had queued but not yet spoken.
    let unspokenClauses: [String]
    /// The user's interruption text.
    let interruptionText: String
    /// How the interruption was classified.
    let kind: InterruptionKind

    /// Compact context block injected into the LLM system prompt.
    func contextBlock() -> String {
        var lines: [String] = ["[CONVERSATIONAL PIVOT CONTEXT]"]
        if !spokenClauses.isEmpty {
            lines.append("Was saying: \(spokenClauses.joined(separator: " "))")
        }
        if !unspokenClauses.isEmpty {
            lines.append("Had planned: \(unspokenClauses.joined(separator: " "))")
        }
        lines.append("User interrupted (\(kind.label)): \(interruptionText)")
        lines.append("Respond only to the interruption. Do NOT restart your previous explanation.")
        return lines.joined(separator: "\n")
    }
}

private extension InterruptionKind {
    var label: String {
        switch self {
        case .correction:      return "correction"
        case .clarification:   return "clarification"
        case .topicShift:      return "topic shift"
        case .urgentCommand:   return "urgent command"
        case .confirmation:    return "confirmation"
        case .expansion:       return "wants more detail"
        case .unknown:         return "unknown"
        }
    }
}

// MARK: - ConversationalPivotPlanner

/// Tracks what Jarvis is saying mid-stream, classifies interruptions, and
/// builds `PivotContext` objects so the LLM can respond naturally.
///
/// **Usage**
/// ```swift
/// planner.beginResponse(sentences: sentences)
/// planner.markSentenceSpoken("The wake pipeline issue…")
/// // user barges in:
/// let ctx = planner.buildPivotContext(interruptionText: "No, after pinch specifically.")
/// ```
@MainActor
final class ConversationalPivotPlanner {

    static let shared = ConversationalPivotPlanner()

    // MARK: - State

    private(set) var spokenClauses: [String] = []
    private(set) var unspokenClauses: [String] = []
    private(set) var isActive: Bool = false
    private(set) var lastPivotAt: Date?
    private(set) var pivotCount: Int = 0

    // MARK: - Interruption classification

    private static let correctionSignals: [String] = [
        "no,", "no ", "not that", "not exactly", "wrong",
        "that's not", "that isn't", "i meant", "i mean",
        "actually", "wait,", "hold on", "specifically", "not quite"
    ]

    private static let clarificationSignals: [String] = [
        "which", "what do you mean", "can you clarify",
        "what is", "where is", "how do you", "could you explain",
        "i don't understand", "what exactly", "what specifically"
    ]

    private static let topicShiftSignals: [String] = [
        "let's talk about", "actually let's", "forget that",
        "never mind", "change of topic", "different question",
        "on a different note", "unrelated", "something else",
        "instead", "what about"
    ]

    private static let urgentCommandSignals: [String] = [
        "stop", "pause", "turn off", "turn on", "lock",
        "call ", "message ", "play ", "open ", "close ",
        "emergency", "quick", "cancel that", "abort"
    ]

    private static let expansionSignals: [String] = [
        "tell me more", "go on", "continue", "keep going",
        "what else", "and", "elaborate", "explain more",
        "why", "how", "what does that mean"
    ]

    private static let confirmationSignals: [String] = [
        "yeah", "yes", "yep", "right", "correct", "exactly",
        "that's right", "agreed", "ok", "got it", "perfect"
    ]

    // MARK: - Lifecycle

    func beginResponse(sentences: [String]) {
        spokenClauses = []
        unspokenClauses = sentences
        isActive = !sentences.isEmpty
    }

    func markSentenceSpoken(_ sentence: String) {
        guard isActive else { return }
        spokenClauses.append(sentence)
        unspokenClauses.removeFirst(where: { $0 == sentence })
    }

    func markAllComplete() {
        isActive = false
    }

    // MARK: - Pivot

    func buildPivotContext(interruptionText: String) -> PivotContext {
        let kind = classify(interruptionText)
        let ctx = PivotContext(
            spokenClauses: spokenClauses,
            unspokenClauses: unspokenClauses,
            interruptionText: interruptionText,
            kind: kind
        )
        lastPivotAt = Date()
        pivotCount += 1
        isActive = false
        spokenClauses = []
        unspokenClauses = []
        return ctx
    }

    func clearIfIdle() {
        isActive = false
        spokenClauses = []
        unspokenClauses = []
    }

    // MARK: - Classification

    func classify(_ text: String) -> InterruptionKind {
        let lower = text.lowercased()

        if Self.urgentCommandSignals.contains(where: { lower.hasPrefix($0) || lower.contains($0) }) {
            // commands that start with action verbs take priority
            if Self.urgentCommandSignals.filter({ lower.hasPrefix($0) }).isEmpty == false {
                return .urgentCommand
            }
        }
        if Self.correctionSignals.contains(where: { lower.hasPrefix($0) || lower.contains(", " + $0) }) {
            return .correction
        }
        if Self.clarificationSignals.contains(where: { lower.contains($0) }) {
            return .clarification
        }
        if Self.topicShiftSignals.contains(where: { lower.contains($0) }) {
            return .topicShift
        }
        if Self.confirmationSignals.contains(where: { lower.hasPrefix($0) || lower == $0 }) {
            return .confirmation
        }
        if Self.expansionSignals.contains(where: { lower.hasPrefix($0) || lower.contains($0) }) {
            return .expansion
        }
        return .unknown
    }

    // MARK: - Diagnostics

    var diagnosticSummary: String {
        guard isActive else { return "idle" }
        return "spoken=\(spokenClauses.count) remaining=\(unspokenClauses.count) pivots=\(pivotCount)"
    }
}

private extension Array {
    mutating func removeFirst(where predicate: (Element) -> Bool) {
        if let idx = firstIndex(where: predicate) {
            remove(at: idx)
        }
    }
}
