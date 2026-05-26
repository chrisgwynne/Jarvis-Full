package com.jarvis.assistant.overlay.model

import java.util.UUID

// ── Card type ─────────────────────────────────────────────────────────────────

/**
 * Every category of overlay Jarvis can show.
 * [defaultAutoDismissMs] == 0 means the card persists until explicitly dismissed.
 */
enum class OverlayCardType(val defaultAutoDismissMs: Long) {
    ACTION_SUCCESS       (2_500L),
    ACTION_FAILED        (4_000L),
    CONFIRMATION         (8_000L),
    SMART_REPLY          (8_000L),
    NAVIGATION           (    0L),   // dismissed when navigation ends
    HOME_ASSISTANT_ALERT (6_000L),
    PROACTIVE_PROMPT     (6_000L),
    DEVICE_CONTEXT       (3_000L),
    LISTENING_STATE      (    0L),   // dismissed when mic closes
    DIAGNOSTICS          (    0L),   // persists until tapped; always bypasses OverlayPolicy gates
}

// ── Priority ──────────────────────────────────────────────────────────────────

enum class OverlayPriority { LOW, NORMAL, HIGH, CRITICAL }

// ── Action button ─────────────────────────────────────────────────────────────

/**
 * A tappable button rendered inside a card.
 * [actionKey] is looked up in [OverlayEventBridge]'s callback registry when tapped.
 */
data class OverlayAction(
    val label: String,
    val actionKey: String,
    val isPrimary: Boolean = false,
)

// ── Card ──────────────────────────────────────────────────────────────────────

/**
 * Immutable snapshot of a single overlay card.
 *
 * [dedupKey] — when set, a new card with the same key refreshes (replaces) the
 * existing one instead of stacking another card.  Use stable string constants.
 *
 * [entityId] — for [OverlayCardType.HOME_ASSISTANT_ALERT] cards, the HA entity
 * ID that triggered the alert (e.g. "binary_sensor.front_door_motion").  Used by
 * [com.jarvis.assistant.overlay.OverlayPolicy] for per-entity cooldown gating.
 *
 * [autoDismissMs] — overrides the type default when set explicitly.  Pass 0 for
 * a persistent card.
 */
data class OverlayCard(
    val id: String             = UUID.randomUUID().toString(),
    val type: OverlayCardType,
    val title: String,
    val message: String        = "",
    val actions: List<OverlayAction> = emptyList(),
    val priority: OverlayPriority   = OverlayPriority.NORMAL,
    val dedupKey: String?      = null,
    val entityId: String?      = null,
    val autoDismissMs: Long    = type.defaultAutoDismissMs,
    val createdAtMs: Long      = System.currentTimeMillis(),
)
