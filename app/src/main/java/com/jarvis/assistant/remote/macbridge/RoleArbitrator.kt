package com.jarvis.assistant.remote.macbridge

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Decides which Jarvis instance owns the conversational role at any given moment.
 *
 * When [AndroidRole.AUTO] is configured:
 *   - Mac connected → Android demotes to BRIDGE_ONLY after [DEMOTION_DELAY_MS]
 *   - Mac gone      → Android promotes to FULL_ASSISTANT after [PROMOTION_DELAY_MS]
 *
 * For fixed roles (FULL_ASSISTANT / BRIDGE_ONLY / DISABLED) the arbitrator is a
 * passthrough — it emits the configured role immediately and keeps the state
 * display fields live.
 *
 * Wiring: lives as a singleton in [com.jarvis.assistant.JarvisApp], started at app
 * boot.  [com.jarvis.assistant.service.JarvisService] observes [state] and calls
 * [com.jarvis.assistant.runtime.JarvisRuntime.promoteToFullAssistant] /
 * [com.jarvis.assistant.runtime.JarvisRuntime.demoteToBridge] when it changes.
 *
 * @param demotionDelayMs Override demotion delay (default [DEMOTION_DELAY_MS]). Injected
 *   by tests to make timing controllable without waiting 5 real seconds.
 * @param promotionDelayMs Override promotion delay (default [PROMOTION_DELAY_MS]).
 * @param testScope If non-null, coroutines are launched inside a child of this scope so
 *   that [kotlinx.coroutines.test.TestScope.advanceTimeBy] controls virtual time. When
 *   null (production) a dedicated [CoroutineScope] is created as before.
 * @param bridgeStatusProvider Returns the live bridge connection status for the
 *   post-delay confirmation check inside demotion/promotion jobs. Defaults to reading
 *   [MacBridgeClient.sharedStatus]; injected by tests to avoid the companion dependency.
 */
class RoleArbitrator(
    private val settingsRepo: MacBridgeSettingsRepository,
    private val demotionDelayMs: Long = DEMOTION_DELAY_MS,
    private val promotionDelayMs: Long = PROMOTION_DELAY_MS,
    testScope: CoroutineScope? = null,
    private val bridgeStatusProvider: () -> MacBridgeStatus =
        { MacBridgeClient.sharedStatus.value },
) {
    companion object {
        private const val TAG = "RoleArbitrator"
        /** Milliseconds Mac must stay connected before Android hands off. */
        const val DEMOTION_DELAY_MS  = 5_000L
        /** Milliseconds without Mac before Android takes over. */
        const val PROMOTION_DELAY_MS = 20_000L
    }

    /**
     * Production: a standalone scope on Dispatchers.Default.
     * Test: a child scope of [testScope] so virtual-time advances propagate into
     * our [delay] calls while [stop] can cancel only the child without tearing
     * down the parent [TestScope].
     */
    private val scope: CoroutineScope = testScope
        ?.let { CoroutineScope(it.coroutineContext + SupervisorJob()) }
        ?: CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _state = MutableStateFlow(
        ArbitratorState(
            configuredRole      = settingsRepo.snapshot().androidRole,
            effectiveRole       = EffectiveRole.FULL_ASSISTANT,
            reason              = "Initialising",
            macReachable        = false,
            macAssistantActive  = false,
            lastActivityAgeMs   = -1L,
            conversationalOwner = "android",
        )
    )
    val state: StateFlow<ArbitratorState> = _state.asStateFlow()

    private var demotionJob:  Job? = null
    private var promotionJob: Job? = null

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    fun start() {
        scope.launch {
            MacBridgeClient.sharedStatus.collect { status ->
                onBridgeStatusChanged(status)
            }
        }
        scope.launch {
            while (isActive) {
                delay(5_000L)
                refreshDisplayFields()
            }
        }
        Log.d(TAG, "started")
    }

    fun stop() {
        scope.cancel()
        Log.d(TAG, "stopped")
    }

    // ── External signal ───────────────────────────────────────────────────────

    /** Called by MacBridgeClient when it receives a mac_status frame from the Mac. */
    fun onMacStatusReceived(assistantActive: Boolean) {
        _state.update { it.copy(macAssistantActive = assistantActive) }
    }

    // ── Core arbitration ──────────────────────────────────────────────────────

    /**
     * Core state-transition function.  `internal` so tests in the same module
     * can inject synthetic [MacBridgeStatus] values without reflection or a live
     * WebSocket connection.
     */
    internal fun onBridgeStatusChanged(status: MacBridgeStatus) {
        val cfg             = settingsRepo.snapshot()
        val macNowReachable = status == MacBridgeStatus.CONNECTED
        val current         = _state.value.effectiveRole

        _state.update { it.copy(
            configuredRole = cfg.androidRole,
            macReachable   = macNowReachable,
        ) }

        if (cfg.androidRole != AndroidRole.AUTO) {
            // Fixed role — cancel pending jobs and apply immediately.
            demotionJob?.cancel();  demotionJob  = null
            promotionJob?.cancel(); promotionJob = null
            val fixed = fixedEffectiveRole(cfg.androidRole)
            _state.update { it.copy(
                effectiveRole       = fixed,
                reason              = "Fixed: ${cfg.androidRole.displayName}",
                conversationalOwner = if (fixed == EffectiveRole.BRIDGE_ONLY) "mac" else "android",
            ) }
            return
        }

        // AUTO arbitration
        if (macNowReachable && current == EffectiveRole.FULL_ASSISTANT) {
            promotionJob?.cancel(); promotionJob = null
            if (demotionJob?.isActive != true) {
                demotionJob = scope.launch {
                    delay(demotionDelayMs)
                    if (bridgeStatusProvider() == MacBridgeStatus.CONNECTED) {
                        commitRole(EffectiveRole.BRIDGE_ONLY,
                            "Mac connected — handing off to Mac Jarvis")
                    }
                }
            }
        } else if (!macNowReachable && current == EffectiveRole.BRIDGE_ONLY) {
            demotionJob?.cancel(); demotionJob = null
            if (promotionJob?.isActive != true) {
                val reason = when (status) {
                    MacBridgeStatus.RECONNECTING -> "Mac connection lost — resuming on Android"
                    MacBridgeStatus.DISABLED     -> "Mac bridge disabled — resuming on Android"
                    else                          -> "Mac unavailable — resuming on Android"
                }
                promotionJob = scope.launch {
                    delay(promotionDelayMs)
                    if (bridgeStatusProvider() != MacBridgeStatus.CONNECTED) {
                        commitRole(EffectiveRole.FULL_ASSISTANT, reason)
                    }
                }
            }
        }
    }

    private fun refreshDisplayFields() {
        val lastAt = MacBridgeClient.sharedLastActivityAtMs.get()
        val age    = if (lastAt == 0L) -1L else System.currentTimeMillis() - lastAt
        val cfg    = settingsRepo.snapshot()

        if (cfg.androidRole != AndroidRole.AUTO) {
            // Keep non-AUTO roles in sync if the setting changed while we weren't observing.
            val fixed = fixedEffectiveRole(cfg.androidRole)
            demotionJob?.cancel();  demotionJob  = null
            promotionJob?.cancel(); promotionJob = null
            _state.update { it.copy(
                configuredRole       = cfg.androidRole,
                effectiveRole        = fixed,
                reason               = "Fixed: ${cfg.androidRole.displayName}",
                macReachable         = bridgeStatusProvider() == MacBridgeStatus.CONNECTED,
                macAssistantActive   = MacBridgeClient.sharedMacAssistantActive,
                lastActivityAgeMs    = age,
                conversationalOwner  = if (fixed == EffectiveRole.BRIDGE_ONLY) "mac" else "android",
            ) }
            return
        }

        _state.update { it.copy(
            configuredRole     = cfg.androidRole,
            macReachable       = bridgeStatusProvider() == MacBridgeStatus.CONNECTED,
            macAssistantActive = MacBridgeClient.sharedMacAssistantActive,
            lastActivityAgeMs  = age,
        ) }
    }

    private fun commitRole(effective: EffectiveRole, reason: String) {
        Log.i(TAG, "role → $effective ($reason)")
        _state.update { it.copy(
            effectiveRole       = effective,
            reason              = reason,
            conversationalOwner = if (effective == EffectiveRole.BRIDGE_ONLY) "mac" else "android",
        ) }
    }

    private fun fixedEffectiveRole(role: AndroidRole) = when (role) {
        AndroidRole.BRIDGE_ONLY -> EffectiveRole.BRIDGE_ONLY
        else                     -> EffectiveRole.FULL_ASSISTANT
    }
}
