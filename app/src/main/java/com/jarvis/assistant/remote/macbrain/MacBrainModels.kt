package com.jarvis.assistant.remote.macbrain

/**
 * Request sent to Mac Brain before LLM calls on MEMORY / PROJECT / HISTORY intents.
 *
 * Kept deliberately minimal — only what the Brain needs to run a useful retrieval.
 * Never include raw audio, screenshots, or full conversation history.
 */
data class BrainContextRequest(
    val transcript: String,
    /** Coarse intent hint — "memory" | "project" | "history" — lets the Brain
     *  tune its retrieval strategy without repeating the full classification. */
    val intentHint: String,
    /** Last session summary from ConversationStore, if any (capped at 256 chars). */
    val recentSummary: String? = null,
    /** Foreground app package, if known. */
    val activeApp: String? = null,
)

/**
 * Context returned by Mac Brain, ready for injection into the system prompt.
 *
 * All fields are additive — null / empty means the Brain had nothing to add.
 * Android always falls back to local-only context if this is null.
 */
data class BrainContextResponse(
    /** Relevant long-term memories as plain-text bullets. */
    val memories: List<String> = emptyList(),
    /** User preferences as key→value (e.g. "answerStyle" → "concise"). */
    val preferences: Map<String, String> = emptyMap(),
    /** Project or GitHub summary if the query was project-scoped. */
    val projectSummary: String? = null,
    /** Known alias corrections (e.g. "Heidi's light" → entity ID). */
    val corrections: List<String> = emptyList(),
) {
    fun isEmpty(): Boolean =
        memories.isEmpty() && preferences.isEmpty() &&
        projectSummary == null && corrections.isEmpty()
}
