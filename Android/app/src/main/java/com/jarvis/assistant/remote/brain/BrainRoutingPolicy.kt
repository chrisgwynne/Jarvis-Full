package com.jarvis.assistant.remote.brain

/**
 * BrainRoutingPolicy — decides whether a transcript warrants a Mac Brain context fetch.
 *
 * RULES
 *   A. NEVER route: transcripts that start with a known instant-command prefix.
 *      These are pure device-control commands (volume, flashlight, timer, etc.)
 *      that must execute in under 100 ms. Any network call would break that contract.
 *   B. ROUTE with hint "project": explicit GitHub / codebase / task signals.
 *   C. ROUTE with hint "history": previous-conversation references.
 *   D. ROUTE with hint "memory":  explicit recall / preference / identity signals.
 *   E. DEFAULT: null — local-only, no Brain fetch.
 *
 * This runs on every non-instant LLM path — it must complete in < 1 ms
 * with no I/O, no allocations beyond list iteration.
 *
 * Returned hint values ("memory" | "project" | "history") are forwarded in
 * [BrainContextRequest.intentHint] so the Brain can tune its retrieval strategy.
 */
object BrainRoutingPolicy {

    /**
     * Returns a non-null hint string if the transcript should be enriched with
     * Brain context before the LLM call; null for local-only routing.
     */
    fun intentHint(transcript: String): String? {
        val lower = transcript.lowercase()
        return when {
            matchesInstantCommand(lower) -> null
            matchesProjectIntent(lower)  -> "project"
            matchesHistoryIntent(lower)  -> "history"
            matchesMemoryIntent(lower)   -> "memory"
            else                         -> null
        }
    }

    // ── A. Instant-command guard ───────────────────────────────────────────────
    private val INSTANT_PREFIXES = listOf(
        "flashlight", "torch",
        "turn on flash", "turn off flash", "flash on", "flash off",
        "volume ", "turn up", "turn down", "mute ", "unmute ",
        "set a timer", "set timer", "start a timer", "start timer", "timer for",
        "set an alarm", "set alarm", "alarm for",
        "open ", "launch ", "close ",
        "play ", "pause ", "stop music", "next song", "previous song", "skip song",
        "call ", "ring ", "dial ",
        "text ", "message ", "send ",
        "take a photo", "take a selfie", "screenshot",
        "navigate to", "directions to", "take me to",
        "brightness", "screen rotation", "do not disturb", "dnd on", "dnd off",
    )

    private fun matchesInstantCommand(lower: String): Boolean =
        INSTANT_PREFIXES.any { lower.startsWith(it) }

    // ── B. Project intent ─────────────────────────────────────────────────────
    private val PROJECT_SIGNALS = listOf(
        "what's broken", "what is broken",
        "what's the status of", "what is the status of",
        "what's happening with", "what happened with",
        "github", "pull request", " pr ",
        "open prs", "the repo", "the project",
        "what are we building", "what are we working on",
        "what's left", "what's outstanding",
        "outstanding tasks", "known issues", "open issues", "unresolved issue",
        "what needs to be done", "what's next on",
        "jarvis project", "codebase", "the branch",
    )

    private fun matchesProjectIntent(lower: String): Boolean =
        PROJECT_SIGNALS.any { lower.contains(it) }

    // ── C. History intent ─────────────────────────────────────────────────────
    private val HISTORY_SIGNALS = listOf(
        "last time", "last week", "last month", "last year",
        "what did we", "what did we decide", "what did we discuss", "what did we agree",
        "what was it we", "we talked about", "we said", "we decided",
        "earlier you", "you mentioned", "you said earlier", "previously",
        "continue where", "pick up where", "we left off",
        "what were we", "going back to",
        "remember when", "remember how", "did we talk about",
    )

    private fun matchesHistoryIntent(lower: String): Boolean =
        HISTORY_SIGNALS.any { lower.contains(it) }

    // ── D. Memory intent ──────────────────────────────────────────────────────
    private val MEMORY_SIGNALS = listOf(
        "do you remember", "what did i tell you",
        "what do you know about me", "what do you know about",
        "what have you remembered", "what do you remember",
        "tell me what you know", "what do you know",
        "remember that", "don't forget", "keep in mind",
        "i told you", "you know that", "as i mentioned", "have i told you",
        "what's my name", "what is my name",
        "my preferences", "my settings", "what did i say",
    )

    private fun matchesMemoryIntent(lower: String): Boolean =
        MEMORY_SIGNALS.any { lower.contains(it) }
}
