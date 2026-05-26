package com.jarvis.assistant.overlay

import android.util.Log
import com.jarvis.assistant.overlay.model.OverlayCardType

/**
 * OverlayPolicy — the single gate every overlay card must pass through.
 *
 * Checked at the top of [OverlayCardManager.show].  If [canShow] returns false the
 * card is silently dropped before it reaches the queue.  This is the authoritative
 * enforcement point for:
 *
 * - **Master overlay toggle** — user's "overlays enabled" switch; blocks all types.
 * - **Bridge-mode suppression** — when Android is the secondary device, overlay
 *   clutter distracts from the Mac Jarvis experience.
 * - **HA alert toggle** — per-type guard for [OverlayCardType.HOME_ASSISTANT_ALERT].
 * - **Per-entity HA cooldown** (120 s) — prevents sensor-flap from spamming the same
 *   entity repeatedly.
 * - **Global HA cooldown** (15 s) — prevents back-to-back sensors flooding the screen.
 *
 * ## Wiring
 *   Call [configure] once in [com.jarvis.assistant.JarvisApp.onCreate] after
 *   SettingsStore and roleArbitrator are ready.  Pass lambdas so runtime setting
 *   changes take effect immediately without restarting the service.
 *
 * ## Thread safety
 *   Cooldown timestamps are read/written under [synchronized(this)].
 *   Lambda invocations are intentionally outside the lock — they never block.
 */
object OverlayPolicy {

    private const val TAG = "OverlayPolicy"

    /** Per-entity cooldown: same entity cannot show an HA overlay within this window. */
    private const val HA_ENTITY_COOLDOWN_MS = 120_000L

    /** Global HA overlay cooldown: no HA overlay of any kind within this window. */
    private const val HA_GLOBAL_COOLDOWN_MS = 15_000L

    // ── Configuration lambdas (set once at app start) ─────────────────────────

    @Volatile private var overlaysEnabledProvider:  () -> Boolean = { true }
    @Volatile private var haAlertsEnabledProvider:  () -> Boolean = { true }
    @Volatile private var bridgeModeActiveProvider: () -> Boolean = { false }

    // ── Per-entity and global HA cooldown state ───────────────────────────────

    private val entityLastShownMs = mutableMapOf<String, Long>()
    private var haGlobalLastShownMs: Long = 0L

    // ── Public API ────────────────────────────────────────────────────────────

    /**
     * Wire the policy to live settings providers.  Call once from
     * [com.jarvis.assistant.JarvisApp.onCreate] after all singletons are ready.
     *
     * @param overlaysEnabled   Returns `true` when the master overlay switch is on.
     * @param haAlertsEnabled   Returns `true` when the HA alert overlay category is on.
     * @param bridgeModeActive  Returns `true` when Android is currently in bridge (secondary) mode.
     */
    fun configure(
        overlaysEnabled:  () -> Boolean,
        haAlertsEnabled:  () -> Boolean,
        bridgeModeActive: () -> Boolean,
    ) {
        overlaysEnabledProvider  = overlaysEnabled
        haAlertsEnabledProvider  = haAlertsEnabled
        bridgeModeActiveProvider = bridgeModeActive
        Log.d(TAG, "configured")
    }

    /**
     * Returns `true` if the card should be shown, `false` if it should be silently dropped.
     *
     * Always returns `true` for non-HA card types when the master toggle is on and Android
     * is not in bridge mode — the existing [OverlayCardManager] dedupe/cap logic handles
     * the rest.
     *
     * @param type     The [OverlayCardType] being requested.
     * @param entityId Optional HA entity ID — drives per-entity cooldown for HA alerts.
     */
    fun canShow(type: OverlayCardType, entityId: String? = null): Boolean {
        // Record every attempt so the debug card can show the last overlay request.
        val attemptDesc = "type=$type entity=$entityId"
        com.jarvis.assistant.reliability.ListenerDiagnostics.lastOverlayAttempt = attemptDesc

        // DIAGNOSTICS cards bypass every gate — they are explicitly requested debug info.
        if (type == OverlayCardType.DIAGNOSTICS) return true

        // 1. Master overlay toggle — hard stop for every card type.
        if (!overlaysEnabledProvider()) {
            val reason = "master_disabled"
            Log.d(TAG, "[OVERLAY_BLOCKED] $reason type=$type")
            Log.d(TAG, "overlay_suppressed reason=$reason")
            com.jarvis.assistant.reliability.ListenerDiagnostics.lastOverlayBlockReason = reason
            return false
        }

        // 2. Bridge-mode suppression — Android is secondary; Mac owns the overlay experience.
        if (bridgeModeActiveProvider()) {
            val reason = "bridge_mode_active"
            Log.d(TAG, "[OVERLAY_BLOCKED] $reason type=$type")
            com.jarvis.assistant.reliability.ListenerDiagnostics.lastOverlayBlockReason = reason
            return false
        }

        // 3. HA-specific gates (only for HOME_ASSISTANT_ALERT cards).
        if (type == OverlayCardType.HOME_ASSISTANT_ALERT) {
            // 3a. HA alert category toggle.
            if (!haAlertsEnabledProvider()) {
                val reason = "ha_alerts_disabled"
                Log.d(TAG, "[OVERLAY_BLOCKED] $reason")
                com.jarvis.assistant.reliability.ListenerDiagnostics.lastOverlayBlockReason = reason
                return false
            }

            val now = System.currentTimeMillis()

            // 3b. Per-entity cooldown — checked before the global cooldown so we can bail
            //     early without holding the lock for the global check.
            if (entityId != null) {
                synchronized(this) {
                    val last = entityLastShownMs[entityId] ?: 0L
                    if (now - last < HA_ENTITY_COOLDOWN_MS) {
                        val remainingS = (HA_ENTITY_COOLDOWN_MS - (now - last)) / 1000
                        val reason = "entity_cooldown:${entityId}:${remainingS}s"
                        Log.d(TAG, "[OVERLAY_BLOCKED] $reason")
                        com.jarvis.assistant.reliability.ListenerDiagnostics.lastOverlayBlockReason = reason
                        return false
                    }
                }
            }

            // 3c. Global HA cooldown — if we pass, record both timestamps atomically so
            //     a concurrent call sees the updated state.
            synchronized(this) {
                val nowSync = System.currentTimeMillis()
                if (nowSync - haGlobalLastShownMs < HA_GLOBAL_COOLDOWN_MS) {
                    val remainingS = (HA_GLOBAL_COOLDOWN_MS - (nowSync - haGlobalLastShownMs)) / 1000
                    val reason = "global_ha_cooldown:${remainingS}s"
                    Log.d(TAG, "[OVERLAY_BLOCKED] $reason")
                    com.jarvis.assistant.reliability.ListenerDiagnostics.lastOverlayBlockReason = reason
                    return false
                }
                // Record timestamps inside the lock (TOCTOU safety).
                haGlobalLastShownMs = nowSync
                if (entityId != null) entityLastShownMs[entityId] = nowSync
            }
        }

        // Card passed all gates — clear the last block reason so the debug card shows "—".
        com.jarvis.assistant.reliability.ListenerDiagnostics.lastOverlayBlockReason = null
        return true
    }

    /**
     * Reset all HA cooldown state.  Useful in tests and when the user clears app data.
     * Does NOT reset the configuration lambdas.
     */
    fun resetCooldowns() {
        synchronized(this) {
            entityLastShownMs.clear()
            haGlobalLastShownMs = 0L
        }
        Log.d(TAG, "cooldowns reset")
    }
}
