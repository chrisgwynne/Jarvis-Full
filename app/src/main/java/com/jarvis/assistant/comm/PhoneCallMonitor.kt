package com.jarvis.assistant.comm

import android.content.Context
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import android.util.Log
import com.jarvis.assistant.remote.gateway.BrainGatewayWebSocketClient

/**
 * PhoneCallMonitor — detects telephony call state changes via TelephonyManager and
 * broadcasts comm.event.received / comm.event.resolved frames to the daemon.
 *
 * SECURITY: Raw phone numbers are never logged or transmitted.
 * All numbers are masked to "****NNNN" format before use.
 *
 * Lifecycle: call [start] after the gateway is connected; call [stop] on service destruction.
 */
class PhoneCallMonitor(
    private val context: Context,
    private val getGateway: () -> BrainGatewayWebSocketClient?
) {
    private val TAG = "PhoneCallMonitor"
    private val telephonyManager = context.getSystemService(TelephonyManager::class.java)

    // Track state transitions to detect missed calls vs answered calls
    private var lastCallState = TelephonyManager.CALL_STATE_IDLE
    private var incomingCallContact: String? = null  // display name only
    private var incomingCallHandle: String? = null   // masked handle only
    private var currentEventId: String? = null

    fun start() {
        @Suppress("DEPRECATION")
        telephonyManager?.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
        Log.i(TAG, "PhoneCallMonitor started")
    }

    fun stop() {
        @Suppress("DEPRECATION")
        telephonyManager?.listen(listener, PhoneStateListener.LISTEN_NONE)
        Log.i(TAG, "PhoneCallMonitor stopped")
    }

    @Suppress("DEPRECATION")
    private val listener = object : PhoneStateListener() {
        override fun onCallStateChanged(state: Int, phoneNumber: String?) {
            // Never log the raw phoneNumber
            val masked = maskPhoneNumber(phoneNumber)
            when (state) {
                TelephonyManager.CALL_STATE_RINGING -> {
                    // Incoming call — resolve contact name without storing the raw number
                    incomingCallContact = resolveContactName(context, phoneNumber)
                    incomingCallHandle = masked
                    currentEventId = CommEventBroadcaster.sendReceived(
                        getGateway(), "phone", "incoming", "received",
                        incomingCallContact ?: "Unknown",
                        masked ?: "****",
                        "android.telephony",
                        null
                    )
                    Log.i(TAG, "Incoming call: contact=${incomingCallContact ?: "Unknown"} handle=$masked")
                }
                TelephonyManager.CALL_STATE_OFFHOOK -> {
                    if (lastCallState == TelephonyManager.CALL_STATE_RINGING) {
                        // Call was answered — resolve the pending event
                        currentEventId?.let { id ->
                            CommEventBroadcaster.sendResolved(getGateway(), id, "called_back")
                            Log.i(TAG, "Call answered — resolved eventId=$id")
                        }
                        currentEventId = null
                    }
                }
                TelephonyManager.CALL_STATE_IDLE -> {
                    if (lastCallState == TelephonyManager.CALL_STATE_RINGING) {
                        // Phone went idle while ringing — missed call
                        currentEventId = CommEventBroadcaster.sendReceived(
                            getGateway(), "phone", "incoming", "missed",
                            incomingCallContact ?: "Unknown",
                            incomingCallHandle ?: "****",
                            "android.telephony",
                            null
                        )
                        Log.i(TAG, "Missed call from contact=${incomingCallContact ?: "Unknown"} handle=${incomingCallHandle ?: "****"}")
                    }
                    incomingCallContact = null
                    incomingCallHandle = null
                    // Note: currentEventId is left set for the missed call scenario;
                    // cleared when the user dismisses via comm.action.execute
                }
            }
            lastCallState = state
        }
    }

    /**
     * Masks a phone number to "****NNNN" format.
     * Returns null if the input is null/blank.
     * NEVER logs or returns the raw number.
     */
    private fun maskPhoneNumber(number: String?): String? {
        if (number.isNullOrBlank()) return null
        val digits = number.filter { it.isDigit() }
        return if (digits.length >= 4) "****${digits.takeLast(4)}" else "****"
    }

    /**
     * Resolves a phone number to a contact display name via ContentResolver.
     * Returns null (not the number) if no contact is found or an error occurs.
     */
    private fun resolveContactName(context: Context, number: String?): String? {
        if (number.isNullOrBlank()) return null
        return try {
            val uri = android.net.Uri.withAppendedPath(
                android.provider.ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                android.net.Uri.encode(number)
            )
            context.contentResolver.query(
                uri,
                arrayOf(android.provider.ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (e: Exception) {
            Log.w(TAG, "Contact lookup failed: ${e.javaClass.simpleName}")
            null
        }
    }
}
