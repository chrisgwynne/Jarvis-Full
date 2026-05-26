package com.jarvis.assistant.remote.macbrain

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import com.jarvis.assistant.util.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * BrainSyncRunner — queues and dispatches [AndroidInteractionEvent]s to Mac Brain
 * without blocking speech or any user-facing path.
 *
 * DESIGN
 *   • Enqueue methods are fast and synchronous (in-memory queue append).
 *   • [trigger] launches a debounced background sync. Rapid successive calls coalesce.
 *   • All gates (enabled, Wi-Fi only, circuit breaker, permission toggles) are
 *     evaluated inside [syncNow] so enqueuers never wait for network state.
 *   • [isWifiProvider] is injected so tests can control Wi-Fi state without
 *     needing a real Android Context.
 *
 * SAFETY
 *   • Never blocks the caller.
 *   • All sync exceptions are caught and recorded as backoff entries.
 *   • Sync failure never affects command success or any user-facing result.
 *
 * WIRING
 *   Use [BrainSyncRunner.create] in production code (provides the Wi-Fi provider
 *   backed by ConnectivityManager).  In tests, construct directly with lambda gates.
 */
class BrainSyncRunner(
    private val store:         PendingBrainSyncStore,
    private val circuit:       BrainCircuitBreaker,
    private val client:        MacBrainClient?,
    private val scope:         CoroutineScope,
    /** Returns true when Mac Brain is enabled. */
    private val enabled:       () -> Boolean,
    /** Returns true when Brain syncs must be Wi-Fi only. */
    private val wifiOnly:      () -> Boolean,
    /** Returns true when command outcome reporting is permitted. */
    private val allowOutcomes: () -> Boolean,
    /** Returns true when HA correction reporting is permitted. */
    private val allowHa:       () -> Boolean,
    /** Returns true when memory context (and memory candidate sync) is permitted. */
    private val allowMemory:   () -> Boolean,
    /** Returns true when the device is on a Wi-Fi network. Injectable for tests. */
    private val isWifiProvider: () -> Boolean = { true },
) {
    companion object {
        private const val TAG             = "BrainSyncRunner"
        private const val DEBOUNCE_MS     = 2_000L
        private const val SYNC_TIMEOUT_MS = 10_000L
        private const val BATCH_SIZE      = 20

        /** Convenience factory for production use. Wires settings and Wi-Fi provider from context. */
        fun create(
            context:  Context,
            store:    PendingBrainSyncStore,
            circuit:  BrainCircuitBreaker,
            client:   MacBrainClient?,
            scope:    CoroutineScope,
            settings: SettingsStore,
        ) = BrainSyncRunner(
            store          = store,
            circuit        = circuit,
            client         = client,
            scope          = scope,
            enabled        = { settings.macBrainEnabled },
            wifiOnly       = { settings.macBrainWifiOnly },
            allowOutcomes  = { settings.macBrainAllowOutcomeReporting },
            allowHa        = { settings.macBrainAllowHaReporting },
            allowMemory    = { settings.macBrainAllowMemory },
            isWifiProvider = { isOnWifi(context) },
        )

        private fun isOnWifi(context: Context): Boolean {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return false
            val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
            return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        }
    }

    init {
        MacBrainStats.registerSyncStore(store)
    }

    @Volatile private var pendingJob: Job? = null

    // ── Enqueuers ──────────────────────────────────────────────────────────────

    /** Queue a command tool result. No-op when outcome reporting is disabled. */
    fun enqueueCommandOutcome(
        deviceId:   String,
        transcript: String,
        toolName:   String,
        success:    Boolean,
        error:      String? = null,
    ) {
        if (!enabled() || !allowOutcomes()) return
        store.enqueue(AndroidInteractionEvent(
            deviceId             = deviceId,
            transcript           = transcript.take(300),
            normalizedTranscript = normalize(transcript),
            intent               = "command",
            actionTaken          = toolName,
            success              = success,
            error                = error?.take(100),
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        ))
        trigger()
    }

    /**
     * Queue a Home Assistant entity mismatch / alias correction.
     *
     * Only enqueued when [entitySaid] (normalised) differs from [entityMatched] (normalised)
     * — exact name matches are not corrections and are silently skipped.
     */
    fun enqueueHaCorrection(
        deviceId:      String,
        transcript:    String,
        entitySaid:    String,
        entityMatched: String,
        entityId:      String,
        success:       Boolean,
    ) {
        if (!enabled() || !allowHa()) return
        if (entitySaid.trim().lowercase() == entityMatched.trim().lowercase()) return
        store.enqueue(AndroidInteractionEvent(
            deviceId             = deviceId,
            transcript           = transcript.take(300),
            normalizedTranscript = normalize(transcript),
            intent               = "smart_home",
            entities             = mapOf(
                "said"     to entitySaid.take(100),
                "matched"  to entityMatched.take(100),
                "entityId" to entityId.take(100),
            ),
            actionTaken          = "entity_match",
            success              = success,
            correction           = "${entitySaid.take(60)} → ${entityMatched.take(60)} ($entityId)".take(200),
            eventType            = AndroidInteractionEvent.EventType.HOME_ASSISTANT_CORRECTION,
        ))
        trigger()
    }

    /** Queue a memory candidate (e.g. "remember that…", preference statement). */
    fun enqueueMemoryCandidate(
        deviceId:   String,
        transcript: String,
    ) {
        if (!enabled() || !allowMemory()) return
        store.enqueue(AndroidInteractionEvent(
            deviceId             = deviceId,
            transcript           = transcript.take(300),
            normalizedTranscript = normalize(transcript),
            intent               = "memory",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.MEMORY_CANDIDATE,
        ))
        trigger()
    }

    // ── Trigger / sync ─────────────────────────────────────────────────────────

    /** Schedule a debounced background sync. Safe to call from any thread/coroutine. */
    fun trigger() {
        pendingJob?.cancel()
        pendingJob = scope.launch(Dispatchers.IO) {
            delay(DEBOUNCE_MS)
            if (isActive) runCatching { syncNow() }
        }
    }

    /** Run a sync attempt immediately. Internal — exposed for testing. */
    internal suspend fun syncNow() {
        if (!enabled()) {
            Log.d(TAG, "[BRAIN_SYNC_SKIP] reason=disabled")
            return
        }
        if (circuit.isOpen()) {
            Log.d(TAG, "[BRAIN_SYNC_SKIP] reason=circuit_open")
            return
        }
        if (wifiOnly() && !isWifiProvider()) {
            Log.d(TAG, "[BRAIN_SYNC_SKIP] reason=wifi_only")
            return
        }
        val brainClient = client ?: run {
            Log.d(TAG, "[BRAIN_SYNC_SKIP] reason=no_client")
            return
        }

        val pending = store.peek(BATCH_SIZE)
        if (pending.isEmpty()) {
            MacBrainStats.recordSync { copy(pendingSyncCount = store.size(), oldestQueuedAt = store.oldestQueuedAt()) }
            return
        }

        // Remove permission-gated items rather than retrying them forever
        val gatedIds = pending.filterNot { shouldReport(it.event) }.map { it.event.id }.toSet()
        if (gatedIds.isNotEmpty()) store.remove(gatedIds)

        val toSend = pending.filter { shouldReport(it.event) }.map { it.event }
        if (toSend.isEmpty()) {
            MacBrainStats.recordSync { copy(pendingSyncCount = store.size(), oldestQueuedAt = store.oldestQueuedAt()) }
            return
        }

        Log.d(TAG, "[BRAIN_SYNC_STARTED] batch=${toSend.size}")
        MacBrainStats.recordSync { copy(lastSyncAttemptAt = System.currentTimeMillis()) }

        try {
            val succeededIds = withTimeoutOrNull(SYNC_TIMEOUT_MS) {
                brainClient.reportEvents(toSend)
            } ?: emptyList()

            val sentSet   = succeededIds.toSet()
            val failedIds = toSend.map { it.id }.toSet() - sentSet

            if (sentSet.isNotEmpty()) {
                store.remove(sentSet)
                Log.d(TAG, "[BRAIN_SYNC_SUCCESS] sent=${sentSet.size}")
                MacBrainStats.recordSync {
                    copy(
                        lastSyncSuccessAt = System.currentTimeMillis(),
                        pendingSyncCount  = store.size(),
                        oldestQueuedAt    = store.oldestQueuedAt(),
                        failedRetryCount  = store.failedCount(),
                    )
                }
            }
            if (failedIds.isNotEmpty()) {
                failedIds.forEach { store.markFailed(it, "partial_batch_failure") }
                Log.w(TAG, "[BRAIN_SYNC_PARTIAL] failed=${failedIds.size}")
                MacBrainStats.recordSync {
                    copy(
                        lastSyncFailureAt = System.currentTimeMillis(),
                        pendingSyncCount  = store.size(),
                        failedRetryCount  = store.failedCount(),
                    )
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "[BRAIN_SYNC_FAILED] ${e.message?.take(80)}")
            pending.forEach { store.markFailed(it.event.id, e.message?.take(100) ?: "unknown") }
            MacBrainStats.recordSync {
                copy(
                    lastSyncFailureAt = System.currentTimeMillis(),
                    pendingSyncCount  = store.size(),
                    failedRetryCount  = store.failedCount(),
                )
            }
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    private fun shouldReport(event: AndroidInteractionEvent): Boolean = when (event.eventType) {
        AndroidInteractionEvent.EventType.COMMAND_OUTCOME           -> allowOutcomes()
        AndroidInteractionEvent.EventType.HOME_ASSISTANT_CORRECTION -> allowHa()
        AndroidInteractionEvent.EventType.MEMORY_CANDIDATE          -> allowMemory()
        AndroidInteractionEvent.EventType.ALIAS_CORRECTION          -> allowOutcomes()
        AndroidInteractionEvent.EventType.CONVERSATION_SUMMARY      -> allowMemory()
    }

    private fun normalize(s: String): String =
        s.trim().lowercase().replace(Regex("\\s+"), " ").take(200)
}
