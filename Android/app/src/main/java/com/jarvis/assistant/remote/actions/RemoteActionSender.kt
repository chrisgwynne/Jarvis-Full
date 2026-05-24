package com.jarvis.assistant.remote.actions

import android.util.Log
import com.jarvis.assistant.remote.gateway.BrainGatewayWebSocketClient
import com.jarvis.assistant.remote.gateway.GatewayWsStatus
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume

/**
 * Sends remote.action.request frames through the daemon gateway and
 * awaits remote.action.result responses with a 30-second timeout.
 */
object RemoteActionSender {
    private const val TAG = "RemoteActionSender"
    private const val TIMEOUT_MS = 30_000L

    // Pending request continuations: requestId → continuation
    private val pending = ConcurrentHashMap<String, (RemoteActionResult) -> Unit>()

    /** Called by BrainGatewayWebSocketClient when remote.action.result arrives. */
    fun onResult(requestId: String, result: RemoteActionResult) {
        pending.remove(requestId)?.invoke(result)
    }

    /**
     * Sends a remote action and suspends until the result arrives or times out.
     * Returns the result, or a timeout result if no response within 30s.
     * Returns a mac_bridge_disconnected result if the gateway is not connected.
     */
    suspend fun send(
        gateway: BrainGatewayWebSocketClient,
        detection: RemoteActionIntent.DetectionResult,
        sourceDeviceId: String = "android"
    ): RemoteActionResult {
        if (gateway.status.value != GatewayWsStatus.Connected) {
            Log.w(TAG, "Gateway not connected — cannot send remote action")
            return RemoteActionResult(
                requestId = "",
                success = false,
                spokenSummary = "The Mac bridge is not connected.",
                errorCode = "mac_bridge_disconnected"
            )
        }

        val requestId = UUID.randomUUID().toString()
        val payload = RemoteActionIntent.buildRequestPayload(detection, requestId = requestId, sourceDeviceId = sourceDeviceId)

        val result = withTimeoutOrNull(TIMEOUT_MS) {
            suspendCancellableCoroutine<RemoteActionResult> { cont ->
                pending[requestId] = { res -> if (cont.isActive) cont.resume(res) }
                cont.invokeOnCancellation { pending.remove(requestId) }

                val frame = JSONObject().apply {
                    put("type", "remote.action.request")
                    put("requestId", requestId)
                    put("routeId", requestId)
                    put("sourceDeviceId", sourceDeviceId)
                    put("targetPlatform", "mac")
                    put("action", detection.action)
                    put("parameters", JSONObject(detection.parameters))
                    put("userVisibleText", detection.userVisibleText)
                    put("requiresConfirmation", false)
                    put("timestamp", System.currentTimeMillis())
                }
                gateway.sendTypedFrame(frame)
                Log.d(TAG, "Sent remote.action.request action=${detection.action} requestId=$requestId")
            }
        }

        return result ?: run {
            pending.remove(requestId)
            Log.w(TAG, "remote.action.request timed out after ${TIMEOUT_MS}ms requestId=$requestId")
            RemoteActionResult(
                requestId = requestId,
                success = false,
                spokenSummary = "The Mac didn't respond in time.",
                errorCode = "mac_action_timeout"
            )
        }
    }
}

data class RemoteActionResult(
    val requestId: String,
    val success: Boolean,
    val spokenSummary: String,
    val errorCode: String? = null,
    val errorMessage: String? = null
)
