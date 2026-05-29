import Foundation

/// Classifies an utterance the deterministic command pipeline didn't match
/// into one of seven categories.  The classifier is intentionally heuristic
/// (string-shape rules, not ML) so the pipeline can route to the right
/// LLM mode (intent-JSON vs free-text), or to a search provider, without
/// a network round-trip.
///
/// The output drives `JarvisController.tryLLMFallback` (free-text mode for
/// questions / chat; intent-JSON mode for action-shaped utterances).
enum QuestionClassifier {

    enum Kind: String, Equatable {
        /// Refers to a recent context item via pronoun or ordinal.
        /// e.g. "what colour is it?", "open the second one"
        case contextualFollowUp
        /// Open-ended factual question that's independent of context.
        /// e.g. "what's the population of Tokyo"
        case factualQuestion
        /// Time-sensitive factual question — should prefer a web search
        /// over an LLM's stale training data.
        /// e.g. "who won the match today"
        case webSearchQuestion
        /// Refers to information Jarvis itself stored / remembered.
        /// e.g. "what do you remember about Shopify"
        case memoryQuestion
        /// Short reply to a pending Jarvis question.
        /// e.g. "yes", "the second one", "Chrome", "no thanks"
        case clarificationReply
        /// Greeting / chat / acknowledgement.
        /// e.g. "thanks", "good morning", "how are you"
        case generalChat
        /// Looks like an action the user wants performed, but the
        /// deterministic pipeline didn't match it.  Route to intent-JSON LLM.
        /// e.g. "set my desk lamp to half"
        case unsupportedCommand
    }

    /// Run the classifier.  `hasPendingQuestion` and `hasActiveContext`
    /// are taken from the controller; they nudge ambiguous inputs the right way.
    static func classify(_ text: String,
                         hasPendingQuestion: Bool,
                         hasActiveContext: Bool) -> Kind {
        let n = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
        guard !n.isEmpty else { return .generalChat }
        let words = n.split(separator: " ").map(String.init)

        // ── Clarification reply (very short, while a question is pending) ──
        // 1–4 words while we're waiting for an answer is overwhelmingly a
        // reply, not a new command.
        if hasPendingQuestion && words.count <= 4 {
            return .clarificationReply
        }

        // ── Contextual follow-up (pronouns / ordinals while context exists) ──
        let pronouns: Set<String> = [
            "it", "that", "this", "these", "those", "they", "them",
            "him", "her", "he", "she",
        ]
        let ordinalRefs: Set<String> = [
            "first", "second", "third", "fourth", "fifth",
            "1st", "2nd", "3rd", "4th", "5th",
            "last", "latest", "previous",
        ]
        let mentionsPronoun = words.contains(where: { pronouns.contains($0) })
        let mentionsOrdinal = words.contains(where: { ordinalRefs.contains($0) })
        if hasActiveContext && (mentionsPronoun || mentionsOrdinal) {
            return .contextualFollowUp
        }

        // ── Memory question ("what did I tell you", "what do you remember") ─
        let memoryCues: [String] = [
            "remember", "you remember", "did i tell you",
            "what did i say", "what have i told you",
            "what did we talk about", "the thing about",
        ]
        if memoryCues.contains(where: { n.contains($0) }) {
            return .memoryQuestion
        }

        // ── Web/search-shaped (time-sensitive / score / news / current) ─────
        let webCues: [String] = [
            "today", "right now", "current", "currently", "latest",
            "this week", "yesterday", "score", "scoreline",
            "weather forecast", "stock price", "exchange rate",
            "trending", "in the news",
        ]
        let looksWebShaped = webCues.contains(where: { n.contains($0) })

        // ── Question shape (interrogative starters) ─────────────────────────
        let questionStarters: [String] = [
            "what", "who", "when", "where", "why", "how",
            "is", "are", "was", "were", "do", "does", "did",
            "can", "could", "would", "will", "should",
            "tell me", "explain", "describe",
        ]
        // Also accept the common contractions so "what's the score" routes
        // the same way as "what is the score".
        let contractionStarters: [String] = [
            "what's", "who's", "where's", "when's", "how's", "why's",
            "there's", "it's", "that's",
        ]
        let endsInQuestion = n.hasSuffix("?")
        let startsWithQ    = questionStarters.contains { n.hasPrefix($0 + " ") || n == $0 }
        let startsWithContraction = contractionStarters.contains { n.hasPrefix($0 + " ") || n == $0 }
        let isQuestionShape = endsInQuestion || startsWithQ || startsWithContraction

        if isQuestionShape && looksWebShaped {
            return .webSearchQuestion
        }
        if isQuestionShape {
            // "what colour is it" while there's active context → follow-up.
            if hasActiveContext && mentionsPronoun {
                return .contextualFollowUp
            }
            return .factualQuestion
        }

        // ── General chat (no question shape, no obvious action verb) ────────
        let chatCues: [String] = [
            "thanks", "thank you", "cheers", "good morning", "good evening",
            "good night", "hello", "hi jarvis", "hey jarvis", "how are you",
            "nice", "cool", "okay then", "got it",
        ]
        if chatCues.contains(where: { n.contains($0) }) {
            return .generalChat
        }

        // ── Action-shaped vs conversational (#62) ───────────────────────────
        // Conversation-first: an utterance with no question shape AND no obvious
        // action verb is almost certainly chat, not a failed command. Only route
        // to the intent-JSON LLM (`.unsupportedCommand`) when the text actually
        // *looks* like an instruction (starts with an imperative verb). Everything
        // else defaults to conversational free-text so Jarvis replies naturally
        // instead of trying — and failing — to synthesise an action.
        let actionVerbStarters: Set<String> = [
            "set", "turn", "open", "close", "play", "pause", "stop", "start",
            "make", "send", "create", "add", "remove", "delete", "show", "hide",
            "switch", "enable", "disable", "mute", "unmute", "increase", "decrease",
            "raise", "lower", "dim", "brighten", "lock", "unlock", "call", "text",
            "email", "schedule", "remind", "launch", "run", "find", "search",
            "skip", "resume", "restart", "move", "copy", "paste", "save", "cancel",
        ]
        let firstWord = words.first ?? ""
        if actionVerbStarters.contains(firstWord) {
            // Looks like an instruction the deterministic pipeline missed —
            // route to intent-JSON LLM so it can map to an action.
            return .unsupportedCommand
        }
        // No question shape, no action verb → treat as conversational chat.
        return .generalChat
    }
}
