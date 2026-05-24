package com.jarvis.assistant.comm

import android.content.Context
import android.util.Log
import com.jarvis.assistant.remote.gateway.BrainGatewayWebSocketClient
import org.json.JSONObject

/**
 * CommWatchdogManager — lifecycle coordinator for the Android communications watchdog.
 *
 * Owns and starts/stops:
 *   - [PhoneCallMonitor]: telephony call state tracking
 *   - [SmsWatcher]: SMS inbox content observer
 *
 * Also handles inbound comm.action.execute frames dispatched by the daemon,
 * returning comm.action.result with needsConfirmation=true — all comm actions
 * require explicit user confirmation on Android before execution.
 *
 * Wiring:
 *   val commWatchdog = CommWatchdogManager(context) { brainGatewayClient }
 *   commWatchdog.start()
 *   brainGatewayClient.commWatchdogManager = commWatchdog
 */
class CommWatchdogManager(
    private val context: Context,
    private val getGateway: () -> BrainGatewayWebSocketClient?
) {
    private val TAG = "CommWatchdogManager"

    /** Set to false to pause broadcasting without tearing down the monitors. */
    var isEnabled: Boolean = true

    private val phoneMonitor = PhoneCallMonitor(context, getGateway)
    private val smsWatcher   = SmsWatcher(context, getGateway)

    fun start() {
        if (!isEnabled) {
            Log.i(TAG, "CommWatchdogManager is disabled — not starting monitors")
            return
        }
        phoneMonitor.start()
        smsWatcher.start()
        Log.i(TAG, "CommWatchdogManager started")
    }

    fun stop() {
        phoneMonitor.stop()
        smsWatcher.stop()
        Log.i(TAG, "CommWatchdogManager stopped")
    }

    /**
     * Called by BrainGatewayWebSocketClient when a comm.action.execute frame arrives.
     *
     * All comm actions (call, SMS send, etc.) require explicit user confirmation on the
     * Android device before execution.  We always return needsConfirmation=true — the
     * actual execution path is future work (confirmation UI notification + deep-link).
     */
    fun handleActionExecute(payload: JSONObject) {
        val action    = payload.optString("action", "")
        val requestId = payload.optString("requestId", "")

        Log.i(TAG, "comm.action.execute action=$action requestId=$requestId")

        // Return a result frame indicating user confirmation is required on Android.
        // The daemon should surface this back to the user as a pending action.
        val resultFrame = JSONObject().apply {
            put("type", "comm.action.result")
            put("requestId", requestId)
            put("action", action)
            put("success", false)
            put("needsConfirmation", true)
            put("message", "User confirmation required on Android")
            put("timestamp", System.currentTimeMillis())
        }
        getGateway()?.sendTypedFrame(resultFrame)

        // TODO: Show a local Android notification with Accept/Decline actions
        // so the user can confirm the comm action directly from the device.
        Log.i(TAG, "comm.action pending user confirmation on Android — action=$action")
    }
}
