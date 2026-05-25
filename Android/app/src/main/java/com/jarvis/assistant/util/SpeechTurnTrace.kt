package com.jarvis.assistant.util

import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

// MARK: - Turn metadata enums

enum class TurnRoute(val key: String) {
    FAST_COMMAND("fast_command"),
    LLM_FALLBACK("llm_fallback"),
    LLM_WITH_TOOL("llm_with_tool"),
    DIRECT_COMMAND("direct_command"),
    UNKNOWN("unknown");
}

enum class TtsKind(val key: String) {
    LOCAL("local"),
    CLOUD("cloud"),
    SYSTEM("system");
}

// MARK: - SpeechTurnTrace

/**
 * Full timing and metadata snapshot for one voice-to-voice pipeline turn.
 * Immutable — built by [SpeechTurnStore.Builder] and stored in the ring buffer.
 */
data class SpeechTurnTrace(
    val turnId: String,
    val startedAtMs: Long,
    val timestamps: Map<String, Long>,
    val route: TurnRoute = TurnRoute.UNKNOWN,
    val device: String = "android",
    val transcriptLength: Int = 0,
    val replyLength: Int = 0,
    val llmUsed: Boolean = false,
    val toolUsed: Boolean = false,
    val ttsKind: TtsKind = TtsKind.LOCAL,
) {
    val totalLatencyMs: Long get() =
        deltaMs("WAKE_DETECTED", "PIPELINE_DONE")
            ?: deltaMs("PIPELINE_START", "PIPELINE_DONE")
            ?: 0L

    val firstAudioLatencyMs: Long get() = deltaMs("WAKE_DETECTED", LatencyTracker.TTS_START) ?: 0L

    val sttMs: Long    get() = deltaMs("STT_START", "STT_COMPLETE") ?: 0L
    val intentMs: Long get() = deltaMs("STT_COMPLETE", "INTENT_CLASSIFIED") ?: 0L
    val llmMs: Long    get() = deltaMs("LLM_REQUEST_START", "LLM_STREAM_END")
        ?: deltaMs("LLM_REQUEST_START", "LLM_COMPLETE") ?: 0L
    val llmFirstTokenMs: Long get() = deltaMs("LLM_REQUEST_START", "LLM_FIRST_TOKEN") ?: 0L
    val ttsMs: Long    get() = deltaMs(LatencyTracker.TTS_START, "PIPELINE_DONE") ?: 0L
    val toolMs: Long   get() = deltaMs("TOOL_START", "TOOL_END") ?: 0L
    val replyLoggerMs: Long get() = deltaMs("REPLY_LOGGER_START", "REPLY_LOGGER_END") ?: 0L

    fun deltaMs(from: String, to: String): Long? {
        val a = timestamps[from] ?: return null
        val b = timestamps[to]   ?: return null
        return b - a
    }

    val slowestStageLabel: String? get() {
        val pairs = listOf(
            "stt"         to sttMs,
            "intent"      to intentMs,
            "llm"         to llmMs,
            "tool"        to toolMs,
            "tts"         to ttsMs,
            "replyLogger" to replyLoggerMs,
        )
        return pairs.filter { it.second > 0 }.maxByOrNull { it.second }?.first
    }
}

// MARK: - SpeechTurnStore

/**
 * Thread-safe ring buffer of the last 20 per-turn speech traces.
 *
 * Usage:
 *   SpeechTurnStore.beginTurn()
 *   SpeechTurnStore.mark("WAKE_DETECTED")
 *   …
 *   SpeechTurnStore.completeTurn()
 */
object SpeechTurnStore {
    private const val CAP = 20
    private val traces = CopyOnWriteArrayList<SpeechTurnTrace>()
    private val builder = AtomicReference<Builder?>(null)

    fun beginTurn(id: String = UUID.randomUUID().toString()): String {
        builder.set(Builder(id))
        return id
    }

    fun mark(label: String) = builder.get()?.mark(label)
    fun setRoute(route: TurnRoute) { builder.get()?.route = route }
    fun setTranscriptLength(len: Int) { builder.get()?.transcriptLength = len }
    fun setReplyLength(len: Int) { builder.get()?.replyLength = len }
    fun setLlmUsed(used: Boolean) { builder.get()?.llmUsed = used }
    fun setToolUsed(used: Boolean) { builder.get()?.toolUsed = used }
    fun setTtsKind(kind: TtsKind) { builder.get()?.ttsKind = kind }

    fun completeTurn() {
        val trace = builder.getAndSet(null)?.build() ?: return
        traces.add(trace)
        while (traces.size > CAP) traces.removeAt(0)
    }

    /** Most-recent first. */
    fun recentTraces(): List<SpeechTurnTrace> = traces.reversed()

    fun averageTotalMs(): Double? {
        val vals = recentTraces().map { it.totalLatencyMs }.filter { it > 0 }
        return if (vals.isEmpty()) null else vals.average()
    }

    fun p50(): Long? = percentile(0.50)
    fun p95(): Long? = percentile(0.95)

    private fun percentile(p: Double): Long? {
        val vals = recentTraces().map { it.totalLatencyMs }.filter { it > 0 }.sorted()
        if (vals.isEmpty()) return null
        val idx = maxOf(0, minOf((vals.size * p).toInt(), vals.size - 1))
        return vals[idx]
    }

    fun routeBreakdown(): Map<TurnRoute, Int> =
        recentTraces().groupingBy { it.route }.eachCount()

    // MARK: - Builder

    class Builder(val turnId: String) {
        private val startedAtMs = System.currentTimeMillis()
        val timestamps = mutableMapOf<String, Long>()
        var route = TurnRoute.UNKNOWN
        var transcriptLength = 0
        var replyLength = 0
        var llmUsed = false
        var toolUsed = false
        var ttsKind = TtsKind.LOCAL

        fun mark(label: String) { timestamps[label] = System.currentTimeMillis() }

        fun build() = SpeechTurnTrace(
            turnId          = turnId,
            startedAtMs     = startedAtMs,
            timestamps      = timestamps.toMap(),
            route           = route,
            transcriptLength = transcriptLength,
            replyLength     = replyLength,
            llmUsed         = llmUsed,
            toolUsed        = toolUsed,
            ttsKind         = ttsKind,
        )
    }
}
