import Foundation

// MARK: - Response Type

/// What kind of answer Jarvis is waiting for.
enum PendingResponseType: String, Codable {
    case yesNo          // "Should I do that?" → yes / no
    case clarification  // "Which app?" → user provides a value
    case freeform       // open-ended — route to LLM with history
    case choice         // pick one from a list (future)
}

// MARK: - Outcome

/// What Jarvis does when the user responds affirmatively, negatively, or with a clarification.
enum PendingOutcome {
    /// Speak a canned reply and do nothing else.
    case speak(String)
    /// Execute a known intent (no speech pre-canned — execute() speaks its own result).
    case executeIntent(Intent)
    /// Speak a canned reply then execute an intent.
    case speakThenExecute(String, Intent)
    /// Re-call the LLM, injecting the full short-term conversation history so it
    /// can resolve the follow-up in context. Used for clarifications and freeform answers.
    case callLLMWithHistory
    /// Capture the user's raw transcript and convert it to an intent via the given closure.
    /// Used when Jarvis is collecting a free-text value (e.g. message body for WhatsApp/SMS)
    /// and should NOT interpret the user's words — just pass them through as-is.
    case captureTranscript((String) -> Intent)
}

// MARK: - PendingConversationContext

/// Captures the state of a question Jarvis asked that is waiting for a user reply.
///
/// Created by `JarvisController.setPendingContext(_:)` whenever the LLM or a
/// deterministic handler wants to wait for user input.  Consumed by
/// `FollowUpResolver` on the next transcript that arrives while
/// `state.phase == .awaitingResponse` or `conversationalArmed`.
struct PendingConversationContext: Identifiable {

    // MARK: - Identity + timing

    let id: UUID
    let createdAt: Date
    /// If no response arrives before this time the context is automatically cleared.
    var expiresAt: Date

    // MARK: - Question details

    /// What the user said that led to this question ("what's the weather").
    let originalTranscript: String
    /// The intent that was partially matched (nil = fell through to LLM).
    let originalIntent: Intent?
    /// The question Jarvis actually spoke ("Should I mark that for a future update?").
    let assistantQuestion: String
    /// What kind of answer is expected.
    let expectedResponseType: PendingResponseType

    // MARK: - Outcomes (nil = fall through to LLM with history)

    let onYes: PendingOutcome?
    let onNo: PendingOutcome?
    /// Applies to clarification / freeform text answers — typically `.callLLMWithHistory`.
    let onFreeform: PendingOutcome?
    /// Valid choices for `.choice` response type (e.g. ["living room", "bedroom", "all"]).
    let choices: [String]?
    /// Called with the matched choice string; returns the outcome to execute.
    let onChoice: ((String) -> PendingOutcome)?

    // MARK: - Helpers

    var isExpired: Bool { Date() > expiresAt }

    // MARK: - Factory

    /// Convenience initialiser with sensible defaults.
    static func make(
        originalTranscript: String,
        originalIntent: Intent? = nil,
        assistantQuestion: String,
        responseType: PendingResponseType = .yesNo,
        onYes: PendingOutcome? = nil,
        onNo: PendingOutcome? = nil,
        onFreeform: PendingOutcome? = .callLLMWithHistory,
        choices: [String]? = nil,
        onChoice: ((String) -> PendingOutcome)? = nil,
        timeoutSeconds: TimeInterval = 20
    ) -> PendingConversationContext {
        PendingConversationContext(
            id: UUID(),
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(timeoutSeconds),
            originalTranscript: originalTranscript,
            originalIntent: originalIntent,
            assistantQuestion: assistantQuestion,
            expectedResponseType: responseType,
            onYes: onYes,
            onNo: onNo,
            onFreeform: onFreeform,
            choices: choices,
            onChoice: onChoice
        )
    }

    /// Quick `yesNo` context where yes/no outcomes are both canned speech replies.
    static func yesNo(
        originalTranscript: String,
        question: String,
        yesReply: String,
        noReply: String,
        timeout: TimeInterval = 20
    ) -> PendingConversationContext {
        make(
            originalTranscript: originalTranscript,
            assistantQuestion: question,
            responseType: .yesNo,
            onYes: .speak(yesReply),
            onNo: .speak(noReply),
            onFreeform: .callLLMWithHistory,
            timeoutSeconds: timeout
        )
    }

    /// Clarification context — any non-yes/no answer is routed back to the LLM with history.
    static func clarification(
        originalTranscript: String,
        question: String,
        timeout: TimeInterval = 20
    ) -> PendingConversationContext {
        make(
            originalTranscript: originalTranscript,
            assistantQuestion: question,
            responseType: .clarification,
            onYes: nil,
            onNo: nil,
            onFreeform: .callLLMWithHistory,
            timeoutSeconds: timeout
        )
    }

    /// Choice context — user must pick one of the listed options.
    static func choice(
        originalTranscript: String,
        originalIntent: Intent? = nil,
        question: String,
        choices: [String],
        onChoice: @escaping (String) -> PendingOutcome,
        timeout: TimeInterval = 20
    ) -> PendingConversationContext {
        make(
            originalTranscript: originalTranscript,
            originalIntent: originalIntent,
            assistantQuestion: question,
            responseType: .choice,
            choices: choices,
            onChoice: onChoice,
            timeoutSeconds: timeout
        )
    }
}
