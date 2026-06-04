package com.jarvis.assistant.reminders

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.jarvis.assistant.memory.db.JarvisDatabase
import com.jarvis.assistant.service.JarvisService
import com.jarvis.assistant.util.JarvisNotificationHelper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * ReminderAlarmReceiver — receives AlarmManager broadcasts when a
 * [ScheduledItem] is due and forwards them to [JarvisService] for delivery.
 *
 * Must be registered in AndroidManifest.xml.
 */
class ReminderAlarmReceiver : BroadcastReceiver() {

    companion object {
        const val EXTRA_ITEM_ID = "reminder_item_id"
        private const val TAG   = "ReminderAlarmReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val itemId = intent.getLongExtra(EXTRA_ITEM_ID, -1L)
        if (itemId < 0L) {
            Log.w(TAG, "Received alarm broadcast with no item id — ignoring")
            return
        }
        Log.d(TAG, "Alarm fired for reminder id=$itemId")

        // Start (or wake) JarvisService to deliver the reminder aloud
        val serviceIntent = Intent(context, JarvisService::class.java).apply {
            action = JarvisService.ACTION_REMINDER_TRIGGER
            putExtra(JarvisService.EXTRA_REMINDER_ID, itemId)
        }
        try {
            context.startForegroundService(serviceIntent)
        } catch (e: Exception) {
            // Android 12+ can deny a FG start from a receiver when the app is
            // in a restricted state (ForegroundServiceStartNotAllowedException,
            // SecurityException on some OEMs). #35: instead of silently losing
            // the reminder, fall back to a high-priority notification so the
            // user still gets it.
            Log.e(TAG, "startForegroundService denied for reminder id=$itemId — posting notification", e)
            val pending = goAsync()
            CoroutineScope(Dispatchers.IO).launch {
                val label = try {
                    JarvisDatabase.getInstance(context).scheduledItemDao()
                        .getById(itemId)?.label?.takeIf { it.isNotBlank() }
                } catch (t: Throwable) {
                    Log.w(TAG, "reminder lookup failed: ${t.message}"); null
                } ?: "You have a reminder."
                try {
                    JarvisNotificationHelper.postReminder(context, "Reminder", label)
                } catch (t: Throwable) {
                    Log.w(TAG, "reminder fallback notification failed: ${t.message}")
                } finally {
                    pending.finish()
                }
            }
        }
    }
}
