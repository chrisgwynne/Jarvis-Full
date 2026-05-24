import Foundation

// MARK: - Resolution result

struct FollowUpResolution {
    /// `true` if this resolver handled the follow-up fully — caller should
    /// NOT fall through to normal intent routing.
    let didHandle: Bool
    /// Optional text for Jarvis to speak.
    let reply: String?
    /// Optional intent to execute after the reply.
    let intent: Intent?
    /// `true` if the LLM should be called with the full conversation history
    /// to resolve this follow-up (clarifications, ambiguous freeform answers).
    let shouldCallLLMWithHistory: Bool

    static let notHandled = FollowUpResolution(
        didHandle: false, reply: nil, intent: nil, shouldCallLLMWithHistory: false)
    static func handled(reply: String? = nil, intent: Intent? = nil) -> FollowUpResolution {
        FollowUpResolution(didHandle: true, reply: reply, intent: intent, shouldCallLLMWithHistory: false)
    }
    static func deferToLLM() -> FollowUpResolution {
        FollowUpResolution(didHandle: true, reply: nil, intent: nil, shouldCallLLMWithHistory: true)
    }
}

// MARK: - FollowUpResolver

enum FollowUpResolver {

    // MARK: - Positive / negative word lists

    private static let positiveWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "yea", "ya",
        "okay", "ok", "sure", "certainly", "absolutely",
        "do it", "go ahead", "please", "please do",
        "sounds good", "sounds great", "that's fine", "that works",
        "affirmative", "correct", "right", "exactly",
        "go for it", "let's do it", "do that",
        "of course", "why not", "definitely"
    ]

    private static let negativeWords: Set<String> = [
        "no", "nope", "nah", "nay",
        "don't", "do not", "don't do it",
        "not now", "not yet", "maybe later",
        "cancel", "cancelled",
        "nevermind", "never mind", "forget it", "forget that",
        "stop", "abort", "skip",
        "negative", "incorrect", "that's wrong",
        "don't bother", "no thanks", "no thank you"
    ]

    // MARK: - Public API

    /// Returns `true` if the text clearly expresses agreement.
    static func isPositive(_ text: String) -> Bool {
        let n = normalize(text)
        return positiveWords.contains(n)
            || n.hasPrefix("yes ")
            || n.hasPrefix("yeah ")
            || n.hasPrefix("sure ")
            || n == "yes" || n == "yeah" || n == "ok" || n == "okay"
    }

    /// Returns `true` if the text clearly expresses refusal.
    static func isNegative(_ text: String) -> Bool {
        let n = normalize(text)
        return negativeWords.contains(n)
            || n.hasPrefix("no ")
            || n.hasPrefix("don't ")
            || n.hasPrefix("not ")
            || n == "no" || n == "nope" || n == "cancel"
    }

    // MARK: - Context-aware resolution

    /// Main entry point. Tries to resolve `normalized` against `pending`.
    ///
    /// Priority:
    /// 1. Exact yes/no detection  — dispatches `onYes` / `onNo`
    /// 2. Clarification / freeform — routes to LLM with history
    /// 3. `notHandled` — caller falls through to normal intent routing
    static func resolve(normalized: String,
                        pending: PendingConversationContext) -> FollowUpResolution {
        switch pending.expectedResponseType {

        case .yesNo:
            if isPositive(normalized), let outcome = pending.onYes {
                return apply(outcome)
            }
            if isNegative(normalized), let outcome = pending.onNo {
                return apply(outcome)
            }
            // Ambiguous — send to LLM with history
            return .deferToLLM()

        case .clarification, .freeform:
            if let freeformOutcome = pending.onFreeform {
                // captureTranscript: use the user's words directly as the value —
                // do NOT send to LLM (it would interpret "hello" as a greeting).
                if case .captureTranscript(let handler) = freeformOutcome {
                    return .handled(intent: handler(normalized))
                }
                return apply(freeformOutcome)
            }
            return .deferToLLM()

        case .choice:
            guard let choices = pending.choices, let onChoice = pending.onChoice else {
                return .deferToLLM()
            }
            let userText = normalize(normalized)
            // First try exact match
            if let match = choices.first(where: { normalize($0) == userText }) {
                return apply(onChoice(match))
            }
            // Then try contains match (user said "living room lights" when choice is "living room")
            if let match = choices.first(where: {
                userText.contains(normalize($0)) || normalize($0).contains(userText)
            }) {
                return apply(onChoice(match))
            }
            // No match — re-ask with the options
            let optionsList = choices.joined(separator: ", ")
            return FollowUpResolution(
                didHandle: true,
                reply: "Sorry, I didn't catch that. Options are: \(optionsList).",
                intent: nil,
                shouldCallLLMWithHistory: false
            )
        }
    }

    // MARK: - Contextual pronoun resolution (no pending context required)

    /// Resolve pronouns / references when a conversational session is active
    /// but there's no specific pending question.  Returns nil when nothing matches.
    ///
    /// Examples: "open it", "close that", "show me", "summarise that"
    static func resolveContextualPronoun(_ text: String,
                                         lastOverlayKind: OverlayKind?,
                                         lastPresentation: ProactivityPresentation?) -> Intent? {
        let n = normalize(text)
        // "open that" / "open it" / "show me" / "show that"
        if n == "open that" || n == "open it" || n == "show me" || n == "show that" {
            if lastPresentation != nil { return .showLatestAlert }
            if lastOverlayKind == .news { return .showNews }
        }
        // "close that" / "close it"
        if n == "close that" || n == "close it" {
            return .closeOverlay
        }
        // "summarise that" / "summarize that"
        if n.hasPrefix("summar") {
            if lastPresentation != nil { return .summariseThat }
        }
        // "dismiss that"
        if n == "dismiss that" || n == "dismiss it" {
            return .dismissLatestAlert
        }
        return nil
    }

    // MARK: - Private helpers

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
    }

    private static func apply(_ outcome: PendingOutcome) -> FollowUpResolution {
        switch outcome {
        case .speak(let text):
            return .handled(reply: text)
        case .executeIntent(let intent):
            return .handled(intent: intent)
        case .speakThenExecute(let text, let intent):
            return .handled(reply: text, intent: intent)
        case .callLLMWithHistory:
            return .deferToLLM()
        case .captureTranscript:
            // Should be handled upstream (in resolve()) before reaching apply().
            // If we somehow arrive here, defer to LLM as a safe fallback.
            return .deferToLLM()
        }
    }
}
