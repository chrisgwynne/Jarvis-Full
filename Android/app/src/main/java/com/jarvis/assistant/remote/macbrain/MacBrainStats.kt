package com.jarvis.assistant.remote.macbrain

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * MacBrainStats — global telemetry hub for the Brain context layer.
 *
 * PRODUCER: [HttpMacBrainClient] — calls [record] after every significant event.
 * CONSUMER: [MacBrainDiagnosticsScreen] (via [SettingsViewModel]) — reads [snapshot].
 * CONTROL:  [SettingsViewModel] — calls [clearCache] / [resetCircuit].
 *
 * Mirrors the AndroidEventBroadcaster.diagnostics / MacBridgeClient.sharedStatus
 * pattern so there is no direct coupling between JarvisRuntime and the settings ViewModel.
 *
 * Live values (cacheSize, inFlightCount, circuitState) are baked into [snapshot]
 * on every [record] call so the UI always reflects the most recent operation.
 */
object MacBrainStats {

    private val _snapshot = MutableStateFlow(MacBrainDiagnosticsSnapshot())
    val snapshot: StateFlow<MacBrainDiagnosticsSnapshot> = _snapshot.asStateFlow()

    // Refs registered once by HttpMacBrainClient on construction.
    @Volatile private var _cache:     BrainContextCache?    = null
    @Volatile private var _circuit:   BrainCircuitBreaker?  = null
    @Volatile private var _deduper:   BrainRequestDeduper?  = null
    @Volatile private var _syncStore: PendingBrainSyncStore? = null

    // ── Registration ───────────────────────────────────────────────────────

    /** Called by [HttpMacBrainClient] once on construction so live values are accessible. */
    internal fun register(
        cache:   BrainContextCache,
        circuit: BrainCircuitBreaker,
        deduper: BrainRequestDeduper,
    ) {
        _cache   = cache
        _circuit = circuit
        _deduper = deduper
    }

    /** Called by [BrainSyncRunner] on construction so sync queue state is reflected in diagnostics. */
    internal fun registerSyncStore(syncStore: PendingBrainSyncStore) {
        _syncStore = syncStore
    }

    // ── Control (called from SettingsViewModel) ────────────────────────────

    fun clearCache() {
        _cache?.clear()
        syncLive()
    }

    fun resetCircuit() {
        _circuit?.reset()
        syncLive()
    }

    // ── Recording (called from HttpMacBrainClient and BrainSyncRunner) ────────

    /**
     * Apply [block] to the current snapshot, then bake in fresh live values.
     * [block] runs with the snapshot as receiver so callers can `copy(...)` cleanly.
     */
    internal fun record(block: MacBrainDiagnosticsSnapshot.() -> MacBrainDiagnosticsSnapshot) {
        _snapshot.update { current ->
            current.block().baked()
        }
    }

    /**
     * Alias for [record] — used by [BrainSyncRunner] when updating sync-specific fields.
     * Bakes in live sync-queue state alongside the caller's changes.
     */
    internal fun recordSync(block: MacBrainDiagnosticsSnapshot.() -> MacBrainDiagnosticsSnapshot) {
        record(block)
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private fun syncLive() {
        _snapshot.update { it.baked() }
    }

    /** Returns a copy with all live component values stamped in. */
    private fun MacBrainDiagnosticsSnapshot.baked() = copy(
        cacheSize        = _cache?.size              ?: cacheSize,
        inFlightCount    = _deduper?.inFlightCount    ?: inFlightCount,
        circuitState     = _circuit?.currentState()   ?: circuitState,
        pendingSyncCount = _syncStore?.size()         ?: pendingSyncCount,
        oldestQueuedAt   = _syncStore?.oldestQueuedAt() ?: oldestQueuedAt,
        failedRetryCount = _syncStore?.failedCount()  ?: failedRetryCount,
    )
}
