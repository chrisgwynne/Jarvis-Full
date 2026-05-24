import Foundation

// MARK: - StreamingConversationEngine

/// Enables sentence-level TTS streaming so Jarvis can be interrupted naturally
/// mid-response rather than waiting for the entire text to finish.
///
/// **How it works:**
/// 1. `beginStreaming(fullText:speak:)` splits the text into sentences, stores
///    them as a queue, and speaks the first sentence.
/// 2. Each time TTS completes a sentence (`advanceIfStreaming()` is called from
///    `rewireSpeakingObserver`), the next sentence is spoken.
/// 3. If the user interrupts mid-stream, `handleInterruption(userText:)` halts
///    the queue and builds a `PivotContext` via `ConversationalPivotPlanner`.
/// 4. `onPivot` callback fires so `JarvisController` can pass the context to the
///    LLM for a natural pivot response.
///
/// This integrates cleanly with the existing TTS pipeline: if `pendingSentences`
/// is empty, `advanceIfStreaming()` is a no-op and existing behaviour is unchanged.
@MainActor
final class StreamingConversationEngine {

    static let shared = StreamingConversationEngine()

    // MARK: - Callbacks (wired by JarvisController)

    /// Speak a single sentence. Should call the existing speak() path.
    var speakSentence: ((String) -> Void)?
    /// Called when an interruption is detected, with the pivot context.
    var onPivot: ((PivotContext) -> Void)?
    /// Called when all sentences have been delivered.
    var onStreamComplete: (() -> Void)?

    // MARK: - State

    private var pendingSentences: [String] = []
    private(set) var currentSentence: String? = nil
    private(set) var isStreaming: Bool = false
    private(set) var wasInterrupted: Bool = false

    // MARK: - Configuration

    /// Minimum sentence length (chars) to speak as a separate chunk.
    var minSentenceLength: Int = 8

    // MARK: - API

    /// Begin streaming `fullText` as a sequence of sentences.
    /// - Returns: true if streaming mode was activated, false if text is too short
    ///   to warrant streaming (falls back to single-shot TTS).
    @discardableResult
    func beginStreaming(fullText: String) -> Bool {
        let sentences = splitIntoSentences(fullText)
        guard sentences.count > 1 else { return false }

        wasInterrupted = false
        isStreaming = true
        pendingSentences = sentences
        pivotPlanner.beginResponse(sentences: sentences)

        speakNext()
        return true
    }

    /// Called from `rewireSpeakingObserver` when TTS finishes a sentence.
    func advanceIfStreaming() {
        guard isStreaming, !wasInterrupted else { return }
        if pendingSentences.isEmpty {
            isStreaming = false
            currentSentence = nil
            pivotPlanner.markAllComplete()
            onStreamComplete?()
        } else {
            speakNext()
        }
    }

    /// Called when the user barges in mid-stream. Halts the queue and fires `onPivot`.
    func handleInterruption(userText: String) {
        guard isStreaming else { return }
        wasInterrupted = true
        isStreaming = false
        pendingSentences = []
        currentSentence = nil

        let pivotCtx = pivotPlanner.buildPivotContext(interruptionText: userText)
        onPivot?(pivotCtx)
    }

    /// Cancels the current stream without generating a pivot context (e.g. "stop talking").
    func cancelStream() {
        isStreaming = false
        wasInterrupted = false
        pendingSentences = []
        currentSentence = nil
        pivotPlanner.clearIfIdle()
    }

    // MARK: - Internal

    private let pivotPlanner = ConversationalPivotPlanner.shared

    private func speakNext() {
        guard !pendingSentences.isEmpty else {
            isStreaming = false
            currentSentence = nil
            onStreamComplete?()
            return
        }
        let sentence = pendingSentences.removeFirst()
        currentSentence = sentence
        pivotPlanner.markSentenceSpoken(sentence)
        speakSentence?(sentence)
    }

    // MARK: - Sentence splitting

    func splitIntoSentences(_ text: String) -> [String] {
        // Split on sentence-ending punctuation followed by space/end.
        // Preserve the punctuation with the sentence before it.
        var results: [String] = []
        var current = ""

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)

            let isSentenceEnd = (c == "." || c == "!" || c == "?")
            let nextIsSpaceOrEnd = (i + 1 >= chars.count) ||
                                   chars[i + 1] == " " || chars[i + 1] == "\n"

            if isSentenceEnd && nextIsSpaceOrEnd {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if trimmed.count >= minSentenceLength {
                    results.append(trimmed)
                }
                current = ""
            }
            i += 1
        }

        // Remainder (no terminal punctuation)
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= minSentenceLength {
            results.append(trimmed)
        }

        // If split produced nothing useful, return the full text as one chunk
        return results.isEmpty ? [text] : results
    }

    // MARK: - Diagnostics

    var diagnosticSummary: String {
        guard isStreaming else { return "idle" }
        return "streaming remaining=\(pendingSentences.count) current='\(currentSentence?.prefix(30) ?? "nil")'"
    }
}
