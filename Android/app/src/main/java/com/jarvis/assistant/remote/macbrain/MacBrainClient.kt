package com.jarvis.assistant.remote.macbrain

/**
 * MacBrainClient — interface for fetching long-term context from the Mac Brain
 * HTTP service before LLM calls on MEMORY / PROJECT / HISTORY intents.
 *
 * CONTRACT
 *   - All methods are suspend functions safe to call from any coroutine dispatcher.
 *   - Implementations MUST never throw — return null on any failure or timeout.
 *   - [fetchContext] has an internal hard timeout; callers in [VoicePipeline] add
 *     an additional outer [kotlinx.coroutines.withTimeoutOrNull] as a belt-and-braces
 *     guard so a slow Brain never stalls a user's response.
 *   - This interface is intentionally narrow — only context fetch and health ping.
 *     Event sending / alias corrections reuse [FederationManager] and
 *     [FederationMessage] to avoid duplicating sync infrastructure.
 *
 * ENDPOINTS (Mac Brain server, not yet implemented)
 *   GET  /brain/health         → health ping
 *   POST /brain/context        → context fetch
 *
 * FEATURE FLAG
 *   The feature is off by default ([SettingsStore.macBrainEnabled] = false).
 *   Implementations must check the flag and return null immediately when disabled.
 */
interface MacBrainClient {

    /**
     * Fetch relevant long-term context for [request].
     *
     * Returns null when:
     *   - Feature flag is off
     *   - Brain is unreachable or misconfigured
     *   - Request times out (internal timeout enforced by the implementation)
     *   - Brain returns a non-2xx status or unparseable body
     */
    suspend fun fetchContext(request: BrainContextRequest): BrainContextResponse?

    /**
     * Lightweight health ping.
     *
     * Returns true if the Brain is reachable and healthy; false otherwise.
     * Should be fast (< 3 s timeout). Used by diagnostics screens only.
     */
    suspend fun health(): Boolean

    /**
     * Report a single interaction outcome to Mac Brain.
     *
     * Returns true if the server accepted the event; false on any failure.
     * Never throws — default implementation returns false so callers that
     * don't use reporting (e.g. [FakeMacBrainClient]) compile without changes.
     */
    suspend fun reportEvent(event: AndroidInteractionEvent): Boolean = false

    /**
     * Report a batch of interaction outcomes. Returns the IDs of events that
     * were accepted by the server.
     *
     * An empty return means total failure; a partial return means some events
     * were accepted.  Never throws.
     */
    suspend fun reportEvents(events: List<AndroidInteractionEvent>): List<String> = emptyList()
}
