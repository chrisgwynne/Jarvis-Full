package com.jarvis.assistant.remote.macbrain

import java.util.UUID

/**
 * AndroidInteractionEvent — one observable outcome from a Jarvis interaction.
 *
 * Queued by [BrainSyncRunner] and flushed to Mac Brain in the background so
 * Brain can improve entity mappings, store memories, and learn from corrections.
 *
 * PRIVACY CONTRACT
 *   - No raw audio, screenshots, or image data.
 *   - No full private message bodies.
 *   - No chain-of-thought or internal reasoning.
 *   - Transcripts are capped at 300 chars before storage or transmission.
 *   - Entities map contains only opaque IDs and matched names — no contact data.
 */
data class AndroidInteractionEvent(
    val id: String = UUID.randomUUID().toString(),
    val timestamp: Long = System.currentTimeMillis(),
    val deviceId: String,
    /** Raw spoken transcript, capped at 300 chars. */
    val transcript: String,
    /** Lowercased, whitespace-collapsed transcript, capped at 200 chars. */
    val normalizedTranscript: String,
    /** Coarse intent label — e.g. "command", "memory", "smart_home". */
    val intent: String,
    /** Named entities relevant to the event (e.g. entity_id, matched name). */
    val entities: Map<String, String> = emptyMap(),
    /** Tool or action executed — e.g. "smart_home", "open_app". Empty when none. */
    val actionTaken: String = "",
    val success: Boolean,
    /** Confidence score [0.0, 1.0] from the underlying classifier or matcher. */
    val confidence: Float = 1.0f,
    /** Human-readable correction description, e.g. "kitchen light → Kitchen Ceiling Light". */
    val correction: String? = null,
    /** Short error when success=false. Never includes sensitive data. */
    val error: String? = null,
    /** Foreground app at time of interaction, if available. */
    val appContext: String? = null,
    /** Whether Mac Brain should persist this event for future retrieval. */
    val shouldStore: Boolean = true,
    val eventType: EventType,
) {
    enum class EventType {
        MEMORY_CANDIDATE,
        COMMAND_OUTCOME,
        ALIAS_CORRECTION,
        CONVERSATION_SUMMARY,
        HOME_ASSISTANT_CORRECTION,
    }

    /**
     * Priority used by [PendingBrainSyncStore] when evicting at capacity.
     * Higher value = more valuable = survives eviction longer.
     */
    internal fun priority(): Int = when (eventType) {
        EventType.CONVERSATION_SUMMARY      -> 1
        EventType.MEMORY_CANDIDATE          -> 2
        EventType.COMMAND_OUTCOME           -> 3
        EventType.ALIAS_CORRECTION          -> 4
        EventType.HOME_ASSISTANT_CORRECTION -> 5
    }
}
