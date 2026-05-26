package com.jarvis.assistant.overlay

import android.util.Log
import com.jarvis.assistant.overlay.model.OverlayCard
import com.jarvis.assistant.overlay.model.OverlayCardType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * OverlayCardManager — the authoritative queue of currently visible overlay cards.
 *
 * ## Rules
 *   • Max [MAX_VISIBLE] non-listening cards at once.  On overflow the oldest is
 *     silently dropped before the new one is added.
 *   • [LISTENING_STATE] cards are exempt from the cap and always shown.
 *   • Cards with a matching [OverlayCard.dedupKey] refresh in-place (reset the
 *     dismiss timer) rather than stacking a duplicate.
 *   • Cards with [OverlayCard.autoDismissMs] > 0 are automatically removed after
 *     their timeout using a coroutine job per card.
 *
 * All state is published via [cards] — a [StateFlow] the Compose UI collects.
 * Every mutation runs on [Dispatchers.Main.immediate] to guarantee that the UI
 * reflects changes in the same frame they are requested.
 */
object OverlayCardManager {

    private const val TAG = "OverlayCards"
    private const val MAX_VISIBLE = 2

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _cards = MutableStateFlow<List<OverlayCard>>(emptyList())
    val cards: StateFlow<List<OverlayCard>> = _cards.asStateFlow()

    private val dismissJobs = mutableMapOf<String, Job>()

    // ── Public API ────────────────────────────────────────────────────────────

    fun show(card: OverlayCard) {
        // Policy gate — checked before any queue mutation so a suppressed card
        // leaves zero trace: no dedup refresh, no cap eviction, no log noise.
        if (!OverlayPolicy.canShow(card.type, card.entityId)) return

        val current = _cards.value

        // Dedup: same key → refresh existing card in-place
        if (card.dedupKey != null) {
            val existing = current.firstOrNull { it.dedupKey == card.dedupKey }
            if (existing != null) {
                _cards.value = current.map {
                    if (it.id == existing.id) card.copy(id = existing.id) else it
                }
                rescheduleAutoDismiss(existing.id, card.autoDismissMs)
                Log.d(TAG, "refreshed dedup=${card.dedupKey}")
                return
            }
        }

        // Enforce cap on non-listening cards
        val nonListening = current.filter { it.type != OverlayCardType.LISTENING_STATE }
        val toDrop = if (nonListening.size >= MAX_VISIBLE) {
            nonListening.minByOrNull { it.createdAtMs }
        } else null

        val base = if (toDrop != null) {
            dismissJobs.remove(toDrop.id)?.cancel()
            current.filter { it.id != toDrop.id }
        } else current

        _cards.value = base + card
        Log.d(TAG, "show type=${card.type} id=${card.id} total=${_cards.value.size}")

        if (card.autoDismissMs > 0) scheduleAutoDismiss(card.id, card.autoDismissMs)
    }

    fun dismiss(id: String) {
        dismissJobs.remove(id)?.cancel()
        val before = _cards.value.size
        _cards.value = _cards.value.filter { it.id != id }
        if (_cards.value.size < before) Log.d(TAG, "dismissed id=$id")
    }

    fun dismissByDedupKey(key: String) {
        _cards.value.filter { it.dedupKey == key }.forEach { dismiss(it.id) }
    }

    fun dismissByType(type: OverlayCardType) {
        _cards.value.filter { it.type == type }.forEach { dismiss(it.id) }
    }

    fun dismissAll() {
        dismissJobs.values.forEach { it.cancel() }
        dismissJobs.clear()
        _cards.value = emptyList()
        Log.d(TAG, "dismissAll")
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    private fun scheduleAutoDismiss(id: String, delayMs: Long) {
        dismissJobs.remove(id)?.cancel()
        dismissJobs[id] = scope.launch {
            delay(delayMs)
            dismiss(id)
        }
    }

    private fun rescheduleAutoDismiss(id: String, delayMs: Long) {
        if (delayMs > 0) scheduleAutoDismiss(id, delayMs)
        else dismissJobs.remove(id)?.cancel()
    }
}
