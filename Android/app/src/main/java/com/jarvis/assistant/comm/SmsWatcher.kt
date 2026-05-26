package com.jarvis.assistant.comm

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.jarvis.assistant.remote.brain.MacBrainConnectionManager

/**
 * SmsWatcher — monitors the SMS inbox via ContentObserver for new unread messages
 * and broadcasts comm.event.received frames to the daemon.
 *
 * SECURITY: Raw phone addresses are never logged or transmitted.
 * All addresses are masked to "****NNNN" before use; message body content is
 * never forwarded — only a generic "New SMS" snippet hint is sent.
 *
 * Lifecycle: call [start] after the gateway is connected; call [stop] on service destruction.
 */
class SmsWatcher(
    private val context: Context,
    private val getGateway: () -> MacBrainConnectionManager?
) {
    private val TAG = "SmsWatcher"
    private val SMS_INBOX_URI = Uri.parse("content://sms/inbox")
    private var lastKnownCount = -1
    private var pendingEventId: String? = null

    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) {
            checkForNewSms()
        }
    }

    fun start() {
        context.contentResolver.registerContentObserver(SMS_INBOX_URI, true, observer)
        Log.i(TAG, "SmsWatcher started")
    }

    fun stop() {
        context.contentResolver.unregisterContentObserver(observer)
        Log.i(TAG, "SmsWatcher stopped")
    }

    private fun checkForNewSms() {
        try {
            val cursor = context.contentResolver.query(
                SMS_INBOX_URI,
                arrayOf("address", "body", "read", "date"),
                "read = 0",  // unread only
                null,
                "date DESC"
            ) ?: return

            cursor.use {
                val count = cursor.count
                if (count > 0 && count != lastKnownCount && cursor.moveToFirst()) {
                    // Mask the address — never log or transmit the raw number
                    val address = cursor.getString(cursor.getColumnIndexOrThrow("address")) ?: ""
                    val masked = maskAddress(address)

                    // Resolve contact name without storing address
                    val contactName = resolveContact(address)

                    // Use a generic snippet rather than actual message body content
                    val bodyLen = cursor.getString(cursor.getColumnIndexOrThrow("body"))?.length ?: 0
                    val snippet = if (bodyLen > 0) "New SMS" else null

                    pendingEventId = CommEventBroadcaster.sendReceived(
                        getGateway(),
                        "sms",
                        "incoming",
                        "unread",
                        contactName ?: "Unknown",
                        masked,
                        "android.sms",
                        snippet
                    )
                    Log.i(TAG, "New SMS: contact=${contactName ?: "Unknown"} handle=$masked unread=$count")
                }
                lastKnownCount = count
            }
        } catch (e: Exception) {
            Log.w(TAG, "SMS check failed: ${e.javaClass.simpleName}")
        }
    }

    /**
     * Masks an SMS address to "****NNNN" format.
     * Works for both numeric phone numbers and shortcodes.
     */
    private fun maskAddress(address: String): String {
        val digits = address.filter { it.isDigit() }
        return when {
            digits.length >= 4 -> "****${digits.takeLast(4)}"
            address.length >= 4 -> "****${address.takeLast(4)}"
            else -> "****"
        }
    }

    /**
     * Resolves an SMS address to a contact display name.
     * Returns null (not the address) if no contact found.
     */
    private fun resolveContact(address: String): String? {
        if (address.isBlank()) return null
        return try {
            val uri = android.net.Uri.withAppendedPath(
                android.provider.ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                android.net.Uri.encode(address)
            )
            context.contentResolver.query(
                uri,
                arrayOf(android.provider.ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
    }
}
