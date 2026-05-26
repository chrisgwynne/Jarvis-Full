package com.jarvis.assistant.intelligence.heuristics

import com.jarvis.assistant.core.events.Event
import com.jarvis.assistant.core.events.EventKind
import com.jarvis.assistant.intelligence.model.RawSuggestion
import com.jarvis.assistant.proactive.ContextSnapshot
import java.util.Calendar

/**
 * BuiltInHeuristics — the eight shipped deterministic heuristics.
 *
 * Each is an object implementing [Heuristic].  New heuristics belong here
 * or in a companion file; register them in [BehaviouralHeuristicsRegistry].
 *
 * Heuristic catalogue:
 *  1. [LowBatteryNavigation]   — Maps foregrounded + battery < 30 %
 *  2. [NavigationBatteryWarning] — Navigation started + battery < 20 %
 *  3. [DriveTimeSpotify]       — Driving started + no media launched
 *  4. [BeforeCalendarEvent]    — Meeting in 5–20 min + no navigation active
 *  5. [IgnoredNotification]    — ≥ 2 unread notifications from messaging app
 *  6. [AwayUnlockedDoor]       — HA lock/door open + user is away
 *  7. [LateNightEarlyAlarm]    — After 23:00 + reminder within 7 hours
 *  8. [RoutineLowBattery]      — Driving started + battery < 40 % (not charging)
 */
object BuiltInHeuristics {

    // ── Maps package helpers ──────────────────────────────────────────────────

    private val MAP_PACKAGES = setOf(
        "com.google.android.apps.maps",
        "com.waze",
        "com.here.app.maps",
        "com.sygic.aura",
        "com.tomtom.gplay.speedcams",
    )

    private fun recentForegroundApp(events: List<Event>, maxAgeMs: Long = 10 * 60_000L): String? {
        val cutoff = System.currentTimeMillis() - maxAgeMs
        return events.lastOrNull {
            it.kind == EventKind.FOREGROUND_APP_CHANGED && it.tsMillis >= cutoff
        }?.payload?.get("app_package")
    }

    private fun hasDrivingStartedRecently(events: List<Event>, maxAgeMs: Long = 5 * 60_000L): Boolean {
        val cutoff = System.currentTimeMillis() - maxAgeMs
        return events.any { it.kind == EventKind.DRIVING_MODE_ON && it.tsMillis >= cutoff }
    }

    private fun hasNavigationStartedRecently(events: List<Event>, maxAgeMs: Long = 5 * 60_000L): Boolean {
        val cutoff = System.currentTimeMillis() - maxAgeMs
        return events.any {
            it.kind == EventKind.TOOL_EXECUTED &&
                it.payload["tool"] == "start_navigation" &&
                it.tsMillis >= cutoff
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. LowBatteryNavigation
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fires when the user opens a navigation app while the battery is below 30 %
     * and not charging.  They are about to drive somewhere; running out mid-route
     * is a real problem.
     */
    object LowBatteryNavigation : Heuristic {
        override val id = "low_battery_navigation"

        override fun evaluate(recentEvents: List<Event>, snapshot: ContextSnapshot?): RawSuggestion? {
            snapshot ?: return null
            if (snapshot.isCharging) return null
            if (snapshot.batteryLevel > 30) return null
            val fg = recentForegroundApp(recentEvents) ?: return null
            if (fg !in MAP_PACKAGES) return null

            return RawSuggestion(
                id         = id,
                title      = "Low battery for navigation",
                message    = "Battery at ${snapshot.batteryLevel}% — consider charging before driving.",
                confidence = 0.88f,
                urgency    = if (snapshot.batteryLevel <= 15) 0.90f else 0.65f,
                dedupeKey  = "low_bat_nav_${snapshot.batteryLevel / 10 * 10}",
                metadata   = mapOf("battery" to snapshot.batteryLevel.toString()),
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. NavigationBatteryWarning
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fires when turn-by-turn navigation has just started and battery is
     * critically low (< 20 %) — not charging.  More urgent than #1 because
     * navigation is already active.
     */
    object NavigationBatteryWarning : Heuristic {
        override val id = "navigation_battery_warning"

        override fun evaluate(recentEvents: List<Event>, snapshot: ContextSnapshot?): RawSuggestion? {
            snapshot ?: return null
            if (snapshot.isCharging) return null
            if (snapshot.batteryLevel >= 20) return null
            if (!hasNavigationStartedRecently(recentEvents)) return null

            return RawSuggestion(
                id         = id,
                title      = "Battery critical — navigation started",
                message    = "Only ${snapshot.batteryLevel}% left with navigation running.",
                confidence = 0.95f,
                urgency    = 0.92f,
                dedupeKey  = "nav_battery_critical",
                metadata   = mapOf("battery" to snapshot.batteryLevel.toString()),
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. DriveTimeSpotify
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fires when driving mode activates and no media / audio tool has been
     * used in the last 3 minutes.  Gentle suggestion to play something.
     */
    object DriveTimeSpotify : Heuristic {
        override val id = "drive_time_media"

        private val MEDIA_PACKAGES = setOf(
            "com.spotify.music",
            "com.google.android.apps.youtube.music",
            "com.apple.android.music",
            "com.amazon.music",
            "com.pandora.android",
            "com.soundcloud.android",
        )

        override fun evaluate(recentEvents: List<Event>, snapshot: ContextSnapshot?): RawSuggestion? {
            if (!hasDrivingStartedRecently(recentEvents, maxAgeMs = 3 * 60_000L)) return null

            // Don't suggest if they already opened a media app recently
            val fg = recentForegroundApp(recentEvents, maxAgeMs = 3 * 60_000L)
            if (fg != null && fg in MEDIA_PACKAGES) return null

            return RawSuggestion(
                id         = id,
                title      = "Start music for your drive?",
                message    = "You're on the road — want to put something on?",
                confidence = 0.60f,
                urgency    = 0.20f,
                dedupeKey  = "drive_time_media",
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. BeforeCalendarEvent
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fires when the next calendar meeting starts in 5–20 minutes and there
     * is no active navigation (they don't need both alerts).
     */
    object BeforeCalendarEvent : Heuristic {
        override val id = "before_calendar_event"

        override fun evaluate(recentEvents: List<Event>, snapshot: ContextSnapshot?): RawSuggestion? {
            snapshot ?: return null
            val nextMeeting = snapshot.nextMeetingAtMillis ?: return null
            val title = snapshot.nextMeetingTitle?.takeIf { it.isNotBlank() } ?: return null
            val msUntil = nextMeeting - snapshot.currentTimeMillis
            if (msUntil !in (5 * 60_000L)..(20 * 60_000L)) return null

            // Don't fire if navigation is already underway (implies they're on their way)
            if (hasNavigationStartedRecently(recentEvents, maxAgeMs = 30 * 60_000L)) return null

            val minutesUntil = (msUntil / 60_000L).toInt()
            return RawSuggestion(
                id         = id,
                title      = "\"$title\" in ${minutesUntil}m",
                message    = "Your next meeting starts in about $minutesUntil minutes.",
                confidence = 0.90f,
                urgency    = if (minutesUntil <= 8) 0.85f else 0.60f,
                dedupeKey  = "before_event_${nextMeeting / 60_000L}",
                metadata   = mapOf(
                    "meeting_title" to title,
                    "minutes_until" to minutesUntil.toString(),
                ),
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. IgnoredNotification
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fires when there are ≥ 2 unread notifications from a messaging app
     * that have been sitting unacknowledged.  Avoids re-announcing what the
     * phone's own notification shade already shows unless there are multiple
     * stacked messages.
     */
    object IgnoredNotification : Heuristic {
        override val id = "ignored_notification"

        private val MESSAGING_PACKAGES = setOf(
            "com.whatsapp",
            "org.telegram.messenger",
            "com.facebook.orca",
            "com.instagram.android",
            "com.snapchat.android",
            "com.google.android.apps.messaging",
            "com.android.mms",
            "com.viber.voip",
            "com.discord",
            "com.microsoft.teams",
            "com.slack",
        )

        override fun evaluate(recentEvents: List<Event>, snapshot: ContextSnapshot?): RawSuggestion? {
            snapshot ?: return null
            if (snapshot.unreadNotificationCount < 2) return null
            val app = snapshot.lastNotificationApp ?: return null
            if (app !in MESSAGING_PACKAGES) return null

            return RawSuggestion(
                id         = id,
                title      = "${snapshot.unreadNotificationCount} unread messages",
                message    = snapshot.lastNotificationText?.take(80) ?: "You have messages waiting.",
                confidence = 0.70f,
                urgency    = 0.40f,
                dedupeKey  = "ignored_notif_${app}",
                metadata   = mapOf(
                    "app"   to app,
                    "count" to snapshot.unreadNotificationCount.toString(),
                ),
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. AwayUnlockedDoor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fires when a Home Assistant lock or door sensor reports an open/unlocked
     * state and the device location indicates the user has left home (driving
     * mode or a PLACE_LEFT event for home in the recent event stream).
     */
    object AwayUnlockedDoor : Heuristic {
        override val id = "away_unlocked_door"

        private val UNLOCKED_STATES = setOf("on", "open", "unlocked", "true")
        private val DOOR_LOCK_ENTITY_RE = Regex(
            """(lock|door|gate|front|back|garage)""",
            RegexOption.IGNORE_CASE
        )

        override fun evaluate(recentEvents: List<Event>, snapshot: ContextSnapshot?): RawSuggestion? {
            // Check if user appears to be away
            val isDriving = snapshot?.isDriving == true
            val leftHome = recentEvents.any {
                it.kind == EventKind.PLACE_LEFT &&
                    it.payload["place"]?.lowercase()?.contains("home") == true &&
                    it.tsMillis >= System.currentTimeMillis() - 30 * 60_000L
            }
            if (!isDriving && !leftHome) return null

            // Look for an unlocked/open HA entity in recent events
            val alertEvent = recentEvents.lastOrNull { event ->
                event.kind == EventKind.SMART_HOME_STATE &&
                    event.tsMillis >= System.currentTimeMillis() - 15 * 60_000L &&
                    (event.payload["state"] ?: "").lowercase() in UNLOCKED_STATES &&
                    DOOR_LOCK_ENTITY_RE.containsMatchIn(event.payload["entity_id"] ?: "") &&
                    DOOR_LOCK_ENTITY_RE.containsMatchIn(event.payload["name"] ?: "")
            } ?: return null

            val name = alertEvent.payload["name"] ?: alertEvent.payload["entity_id"] ?: "Door"
            return RawSuggestion(
                id         = id,
                title      = "$name left open",
                message    = "You appear to be away but $name is still open.",
                confidence = 0.80f,
                urgency    = 0.78f,
                dedupeKey  = "away_unlocked_${alertEvent.payload["entity_id"]}",
                metadata   = mapOf("entity" to (alertEvent.payload["entity_id"] ?: "")),
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. LateNightEarlyAlarm
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fires when the user's screen is on after 23:00 and they have a reminder
     * or meeting starting within the next 7 hours.  A gentle nudge to not stay
     * up too late.
     */
    object LateNightEarlyAlarm : Heuristic {
        override val id = "late_night_early_alarm"

        override fun evaluate(recentEvents: List<Event>, snapshot: ContextSnapshot?): RawSuggestion? {
            snapshot ?: return null
            val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
            if (hour < 23) return null
            if (!snapshot.screenOn) return null

            // Check for early reminder
            val nextReminder = snapshot.nextReminderAtMillis
            val nextMeeting  = snapshot.nextMeetingAtMillis
            val soonestMs = when {
                nextReminder != null && nextMeeting != null -> minOf(nextReminder, nextMeeting)
                nextReminder != null -> nextReminder
                nextMeeting  != null -> nextMeeting
                else -> return null
            }
            val msUntil = soonestMs - snapshot.currentTimeMillis
            if (msUntil !in 60_000L..(7 * 60 * 60_000L)) return null

            val hoursUntil = (msUntil / 3_600_000L).toInt()
            val label = if (nextMeeting != null && nextMeeting == soonestMs)
                snapshot.nextMeetingTitle?.take(30) ?: "meeting"
            else
                "reminder"

            return RawSuggestion(
                id         = id,
                title      = "Early $label in ${hoursUntil}h",
                message    = "You have a $label in about $hoursUntil hours.",
                confidence = 0.72f,
                urgency    = 0.50f,
                dedupeKey  = "late_night_early_alarm_${hour}",
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. RoutineLowBattery
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fires when driving mode activates and battery is below 40 % but not
     * yet at the critical threshold (covered by the existing LowBatteryTrigger).
     * Bridges the gap between "fine" and "critical" so the user has time to
     * charge before a longer trip.
     */
    object RoutineLowBattery : Heuristic {
        override val id = "routine_low_battery"

        override fun evaluate(recentEvents: List<Event>, snapshot: ContextSnapshot?): RawSuggestion? {
            snapshot ?: return null
            if (snapshot.isCharging) return null
            // Let LowBatteryTrigger own the ≤ 20% range
            if (snapshot.batteryLevel <= 20 || snapshot.batteryLevel >= 40) return null
            if (!hasDrivingStartedRecently(recentEvents)) return null

            return RawSuggestion(
                id         = id,
                title      = "Battery at ${snapshot.batteryLevel}%",
                message    = "Might be worth charging before a longer drive.",
                confidence = 0.65f,
                urgency    = 0.45f,
                dedupeKey  = "routine_low_bat_drive_${snapshot.batteryLevel / 10 * 10}",
                metadata   = mapOf("battery" to snapshot.batteryLevel.toString()),
            )
        }
    }

    /** All eight shipped heuristics in evaluation order. */
    val all: List<Heuristic> = listOf(
        LowBatteryNavigation,
        NavigationBatteryWarning,
        DriveTimeSpotify,
        BeforeCalendarEvent,
        IgnoredNotification,
        AwayUnlockedDoor,
        LateNightEarlyAlarm,
        RoutineLowBattery,
    )
}
