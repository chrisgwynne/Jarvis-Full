package com.jarvis.assistant.remote.macbrain

/**
 * MacBrainDiagnosticsSnapshot — immutable point-in-time view of Brain subsystem state.
 *
 * Consumed exclusively by [MacBrainDiagnosticsScreen] via [MacBrainStats.snapshot].
 * Never exposes internal DTOs, client references, or network state directly.
 *
 * Timestamps are epoch-ms (0 = never).
 * Latency -1 means never measured.
 * [lastHealthOk] null means health was never checked.
 */
data class MacBrainDiagnosticsSnapshot(
    // ── Feature state ──────────────────────────────────────────────────────
    val enabled: Boolean = false,

    // ── Circuit breaker ────────────────────────────────────────────────────
    /** "CLOSED" | "OPEN" | "HALF_OPEN" */
    val circuitState: String = "CLOSED",

    // ── Cache ──────────────────────────────────────────────────────────────
    val cacheSize: Int = 0,

    // ── In-flight ─────────────────────────────────────────────────────────
    val inFlightCount: Int = 0,

    // ── Last request ──────────────────────────────────────────────────────
    /** "memory" | "project" | "history" | "—" */
    val lastRequestIntent: String = "—",
    /** "succeeded" | "cache_hit" | "timeout" | "failed" | "skipped" | "—" */
    val lastRequestResult: String = "—",
    val lastFailureReason: String = "—",
    val lastSucceededAt: Long = 0L,
    val lastTimeoutAt: Long = 0L,
    val lastCacheHitAt: Long = 0L,

    // ── Health check ──────────────────────────────────────────────────────
    val lastHealthCheckedAt: Long = 0L,
    val lastHealthLatencyMs: Long = -1L,
    val lastHealthOk: Boolean? = null,

    // ── Counters (session-lifetime, reset on app restart) ─────────────────
    val totalRequests: Int = 0,
    val totalSuccesses: Int = 0,
    val totalCacheHits: Int = 0,
    val totalTimeouts: Int = 0,
    val totalFailures: Int = 0,
    val totalSkipped: Int = 0,

    // ── Offline sync queue ─────────────────────────────────────────────────
    /** Number of events currently waiting to be synced to Mac Brain. */
    val pendingSyncCount: Int = 0,
    val lastSyncAttemptAt: Long = 0L,
    val lastSyncSuccessAt: Long = 0L,
    val lastSyncFailureAt: Long = 0L,
    /** Epoch-ms of the oldest queued event, or 0 if the queue is empty. */
    val oldestQueuedAt: Long = 0L,
    /** Number of queued events that have had at least one failed attempt. */
    val failedRetryCount: Int = 0,
)
