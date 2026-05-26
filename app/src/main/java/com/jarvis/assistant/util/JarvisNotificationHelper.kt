package com.jarvis.assistant.util

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import kotlin.math.abs

/**
 * JarvisNotificationHelper — centralised helper for posting system notifications.
 *
 * Channels are created lazily on first use.  The object is thread-safe because
 * [ensureChannels] is idempotent and [NotificationManager.createNotificationChannel]
 * is safe to call from any thread.
 *
 * ## Channel IDs
 *
 * | ID                    | Constant              | Importance | Sound | Use case                         |
 * |-----------------------|-----------------------|------------|-------|----------------------------------|
 * | `jarvis_proactive`    | [CHANNEL_PROACTIVE]   | LOW        | No    | Proactive alerts, HA suggestions |
 * | `jarvis_reminders`    | [CHANNEL_REMINDERS]   | HIGH       | Yes   | User-set reminders and timers    |
 * | `jarvis_alerts`       | [CHANNEL_ALERTS]      | DEFAULT    | Yes   | (legacy — no new code should use)|
 *
 * ### Why a separate `jarvis_proactive` channel?
 *
 * Android notification channel importance is cached at creation time and cannot be
 * downgraded by the app after the user has seen the channel.  The legacy
 * `jarvis_alerts` channel was created with `IMPORTANCE_DEFAULT`, which means every
 * notification makes an audible sound.  That sound triggers an
 * `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` event; JarvisRuntime calls `silence()` when
 * it receives a duck event during `IdleWake` state, which stops the wake-word
 * detector.  The result: Jarvis listens, an HA notification fires, and Jarvis goes
 * idle — the "listens then stops" bug.
 *
 * Creating a new channel ID (`jarvis_proactive`) with `IMPORTANCE_LOW` fixes this:
 * `IMPORTANCE_LOW` shows the notification silently in the shade with no sound and no
 * heads-up, producing zero audio-focus events.
 */
object JarvisNotificationHelper {

    /**
     * Silent proactive-alert channel.  `IMPORTANCE_LOW` = no sound, no heads-up,
     * no audio-focus event.  All [postProactiveAlert] and [postMissedCallAlert]
     * calls use this channel.
     */
    private const val CHANNEL_PROACTIVE = "jarvis_proactive"
    private const val CHANNEL_REMINDERS = "jarvis_reminders"

    /**
     * Legacy alerts channel kept for backward compatibility only.
     * Already registered on existing installs with IMPORTANCE_DEFAULT.
     * No new notifications should be posted to this channel.
     */
    private const val CHANNEL_ALERTS    = "jarvis_alerts"

    /** Base offset so alert IDs never collide with system or other Jarvis IDs. */
    private const val ALERT_ID_BASE    = 2000
    /** Base offset for reminder IDs. */
    private const val REMINDER_ID_BASE = 3000

    // ── Channel setup ─────────────────────────────────────────────────────────

    /**
     * Create all notification channels if they do not already exist.
     * Safe to call multiple times — Android is a no-op for duplicate channel IDs.
     */
    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // "jarvis_proactive" — silent proactive alerts.
        // IMPORTANCE_LOW: shown in the shade but no sound and no heads-up notification.
        // This prevents AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK events that would otherwise
        // call silence() in IdleWake and kill the wake-word detector.
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_PROACTIVE,
                "Jarvis Proactive Alerts",
                NotificationManager.IMPORTANCE_LOW
            ).also { ch ->
                ch.setShowBadge(false)
                ch.setSound(null, null)   // no sound → no audio-focus event
            }
        )

        // "jarvis_reminders" — time-sensitive reminders and timers, high importance + vibration
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_REMINDERS,
                "Reminders & Timers",
                NotificationManager.IMPORTANCE_HIGH
            ).also { ch ->
                ch.enableVibration(true)
                ch.vibrationPattern = longArrayOf(0, 250, 150, 250)
            }
        )

        // "jarvis_alerts" — legacy channel; kept so existing installs don't lose history.
        // No new code posts here.  Created at IMPORTANCE_DEFAULT so the channel appears
        // in system settings and users can manage any lingering notifications.
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ALERTS,
                "Jarvis Alerts (legacy)",
                NotificationManager.IMPORTANCE_DEFAULT
            )
        )
    }

    // ── Notification ID helper ────────────────────────────────────────────────

    /**
     * Derive a stable, non-zero notification ID from a title string.
     * Using abs() of hashCode avoids negative IDs; clamping to the base
     * range prevents collisions with other Jarvis notifications.
     */
    private fun alertId(title: String): Int    = ALERT_ID_BASE    + (abs(title.hashCode()) % 1000)
    private fun reminderId(title: String): Int = REMINDER_ID_BASE + (abs(title.hashCode()) % 1000)

    // ── Public API ────────────────────────────────────────────────────────────

    /**
     * Post a silent proactive alert on the [CHANNEL_PROACTIVE] channel.
     *
     * Uses `IMPORTANCE_LOW` / `PRIORITY_LOW` so no sound is emitted and no
     * audio-focus event is triggered.  This prevents the notification from
     * duck-interrupting the wake-word detector (the "listens then stops" bug).
     *
     * @param context Application or service context.
     * @param title   Short notification title shown in bold.
     * @param body    Expanded notification body text.
     */
    fun postProactiveAlert(context: Context, title: String, body: String) {
        ensureChannels(context)
        val notification = NotificationCompat.Builder(context, CHANNEL_PROACTIVE)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)
            .setAutoCancel(true)
            .build()

        NotificationManagerCompat.from(context).notify(alertId(title), notification)
    }

    /**
     * Post a high-priority reminder or timer notification on the [CHANNEL_REMINDERS] channel.
     *
     * @param context Application or service context.
     * @param title   Short notification title (e.g. "Reminder: Call dentist").
     * @param body    Expanded body text (e.g. "Time for: Call dentist").
     */
    fun postReminder(context: Context, title: String, body: String) {
        ensureChannels(context)
        val notification = NotificationCompat.Builder(context, CHANNEL_REMINDERS)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVibrate(longArrayOf(0, 250, 150, 250))
            .setAutoCancel(true)
            .build()

        NotificationManagerCompat.from(context).notify(reminderId(title), notification)
    }

    /**
     * Post a missed-call alert using [postProactiveAlert].
     *
     * @param context    Application or service context.
     * @param callerName Display name of the caller, or null if unavailable.
     */
    fun postMissedCallAlert(context: Context, callerName: String?) {
        val displayName = callerName ?: "unknown"
        val title       = "Missed call"
        val body        = "Missed call from $displayName"
        postProactiveAlert(context, title, body)
    }
}
