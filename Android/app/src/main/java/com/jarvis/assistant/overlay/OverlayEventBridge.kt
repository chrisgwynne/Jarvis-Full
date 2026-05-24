package com.jarvis.assistant.overlay

import com.jarvis.assistant.overlay.model.OverlayAction
import com.jarvis.assistant.overlay.model.OverlayCard
import com.jarvis.assistant.overlay.model.OverlayCardType
import com.jarvis.assistant.overlay.model.OverlayPriority

/**
 * OverlayEventBridge — the single static entry point through which any layer of
 * the app can enqueue an overlay card.
 *
 * ## Design
 *   Tools, the runtime, and the Mac Bridge all call [show] or one of the
 *   typed convenience methods.  The bridge delegates to [OverlayCardManager] so
 *   callers never import the manager directly.
 *
 * ## Action callbacks
 *   Cards with [OverlayAction] items carry an [OverlayAction.actionKey].  Callers
 *   pre-register a handler via [onAction] before showing the card.  The Compose
 *   UI calls [fireAction] when the button is tapped, which dismisses the card and
 *   invokes the handler.  Use [clearAction] to un-register when the action is no
 *   longer relevant.
 */
object OverlayEventBridge {

    // ── Listening state (fast show/hide path used by JarvisRuntime) ───────────

    private const val LISTENING_DEDUP = "jarvis_listening"

    fun showListening() {
        OverlayCardManager.show(
            OverlayCard(
                type      = OverlayCardType.LISTENING_STATE,
                title     = "Listening…",
                dedupKey  = LISTENING_DEDUP,
                priority  = OverlayPriority.HIGH,
            )
        )
    }

    fun hideListening() = OverlayCardManager.dismissByDedupKey(LISTENING_DEDUP)

    // ── Navigation overlay ────────────────────────────────────────────────────

    private const val NAV_DEDUP = "navigation_active"

    fun showNavigation(title: String, message: String = "") {
        OverlayCardManager.show(
            OverlayCard(
                type      = OverlayCardType.NAVIGATION,
                title     = title,
                message   = message,
                dedupKey  = NAV_DEDUP,
                priority  = OverlayPriority.HIGH,
            )
        )
    }

    fun hideNavigation() = OverlayCardManager.dismissByDedupKey(NAV_DEDUP)

    // ── Generic typed helpers ─────────────────────────────────────────────────

    fun show(card: OverlayCard) = OverlayCardManager.show(card)

    fun success(title: String, message: String = "", dedupKey: String? = null) {
        OverlayCardManager.show(
            OverlayCard(
                type     = OverlayCardType.ACTION_SUCCESS,
                title    = title,
                message  = message,
                dedupKey = dedupKey,
            )
        )
    }

    fun failure(title: String, message: String = "", dedupKey: String? = null) {
        OverlayCardManager.show(
            OverlayCard(
                type     = OverlayCardType.ACTION_FAILED,
                title    = title,
                message  = message,
                dedupKey = dedupKey,
                priority = OverlayPriority.HIGH,
            )
        )
    }

    /**
     * Show a Home Assistant alert overlay.
     *
     * @param title    Alert title (usually the entity friendly name).
     * @param message  Alert body (usually the new state).
     * @param entityId Optional HA entity ID (e.g. "binary_sensor.front_door_motion").
     *                 Used by [OverlayPolicy] for per-entity cooldown and as a stable
     *                 [OverlayCard.dedupKey] so rapid flap from the same sensor refreshes
     *                 the existing card rather than stacking duplicates.
     */
    fun haAlert(title: String, message: String = "", entityId: String? = null) {
        OverlayCardManager.show(
            OverlayCard(
                type     = OverlayCardType.HOME_ASSISTANT_ALERT,
                title    = title,
                message  = message,
                priority = OverlayPriority.HIGH,
                entityId = entityId,
                dedupKey = entityId?.let { "ha_$it" },
            )
        )
    }

    fun proactive(title: String, message: String = "") {
        OverlayCardManager.show(
            OverlayCard(
                type    = OverlayCardType.PROACTIVE_PROMPT,
                title   = title,
                message = message,
            )
        )
    }

    fun smartReply(
        title: String,
        message: String = "",
        actions: List<OverlayAction> = emptyList(),
        dedupKey: String? = null,
    ) {
        OverlayCardManager.show(
            OverlayCard(
                type     = OverlayCardType.SMART_REPLY,
                title    = title,
                message  = message,
                actions  = actions,
                dedupKey = dedupKey,
                priority = OverlayPriority.HIGH,
            )
        )
    }

    // ── Diagnostics card ─────────────────────────────────────────────────────

    private const val DIAGNOSTICS_DEDUP = "jarvis_diagnostics"

    /**
     * Show (or refresh) a persistent debug overlay card containing a snapshot of
     * [com.jarvis.assistant.reliability.ListenerDiagnostics].
     *
     * The card bypasses all [OverlayPolicy] gates (including the master toggle)
     * so it is always visible when called explicitly — e.g. from Settings or a
     * debug broadcast.  Tap the card to dismiss it.
     */
    fun showDiagnostics() {
        val snap = com.jarvis.assistant.reliability.ListenerDiagnostics.snapshot()
        OverlayCardManager.show(
            OverlayCard(
                type     = OverlayCardType.DIAGNOSTICS,
                title    = "Jarvis Diagnostics",
                message  = snap.toDebugCard(),
                dedupKey = DIAGNOSTICS_DEDUP,
                priority = OverlayPriority.NORMAL,
            )
        )
    }

    fun hideDiagnostics() = OverlayCardManager.dismissByDedupKey(DIAGNOSTICS_DEDUP)

    // ── Action key callbacks ──────────────────────────────────────────────────

    private val actionHandlers = mutableMapOf<String, () -> Unit>()

    fun onAction(key: String, handler: () -> Unit) {
        actionHandlers[key] = handler
    }

    fun clearAction(key: String) {
        actionHandlers.remove(key)
    }

    /**
     * Called by the Compose UI when a card action button is tapped.
     * Dismisses the card then invokes the registered handler (if any).
     */
    fun fireAction(cardId: String, actionKey: String) {
        OverlayCardManager.dismiss(cardId)
        actionHandlers[actionKey]?.invoke()
    }
}
