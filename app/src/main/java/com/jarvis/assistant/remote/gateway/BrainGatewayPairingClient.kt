package com.jarvis.assistant.remote.gateway

import android.util.Log
import com.jarvis.assistant.llm.LlmException
import com.jarvis.assistant.llm.NetworkClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

/**
 * Handles the one-shot HTTP pairing handshake with the Mac Brain Gateway.
 *
 * Pair flow:
 *   1. User scans QR code → gateway URL + one-time pairing code
 *   2. Android POSTs device info + pairing code to /v1/android/pair
 *   3. Gateway validates the code, returns a long-lived session token
 *   4. Token stored encrypted; used for all future HTTP + WebSocket auth
 *
 * No auth header is sent for the pairing request itself — the pairing code
 * is the one-time credential.  All subsequent requests use the returned
 * session token as a Bearer token.
 */
class BrainGatewayPairingClient {

    companion object {
        private const val TAG             = "BrainGatewayPairing"
        private const val PAIR_TIMEOUT_MS = 10_000L

        /** Capabilities this Android build advertises to the gateway. */
        val DEFAULT_CAPABILITIES = listOf("commands", "events", "bridge", "camera")
    }

    /**
     * POST /v1/android/pair.
     *
     * @param baseUrl      Gateway base URL, e.g. "https://100.91.42.7:8765"
     * @param pairingCode  One-time code from the Mac-side QR display
     * @param deviceId     Stable UUID for this Android device
     * @param deviceName   Human-readable name, e.g. "Chris's Pixel 7"
     * @param appVersion   App version string forwarded for diagnostics
     * @param capabilities List of capability names this device advertises
     */
    suspend fun pair(
        baseUrl: String,
        pairingCode: String,
        deviceId: String,
        deviceName: String,
        appVersion: String = "",
        capabilities: List<String> = DEFAULT_CAPABILITIES,
    ): PairResult = withContext(Dispatchers.IO) {
        if (baseUrl.isBlank() || pairingCode.isBlank()) {
            return@withContext PairResult.Failure(PairFailure.BadResponse)
        }

        val url  = "${baseUrl.trimEnd('/')}/v1/android/pair"
        val body = buildPairRequestJson(
            deviceId     = deviceId,
            deviceName   = deviceName,
            pairingCode  = pairingCode,
            appVersion   = appVersion,
            capabilities = capabilities,
        )

        Log.d(TAG, "[GATEWAY_PAIR_STARTED] url=$url deviceId=$deviceId")

        val result = withTimeoutOrNull(PAIR_TIMEOUT_MS) {
            try {
                val raw = NetworkClient.post(url = url, headers = emptyMap(), body = body)
                parsePairResponse(raw)
            } catch (e: LlmException) {
                val msg = e.message ?: ""
                when {
                    msg.startsWith("HTTP 401") -> PairResult.Failure(PairFailure.InvalidCode)
                    msg.startsWith("HTTP 409") -> PairResult.Failure(PairFailure.AlreadyPaired)
                    else -> {
                        Log.w(TAG, "[GATEWAY_PAIR_HTTP_ERROR] ${msg.take(80)}")
                        PairResult.Failure(PairFailure.MacUnavailable)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "[GATEWAY_PAIR_FAILED] ${e.javaClass.simpleName}: ${e.message?.take(80)}")
                PairResult.Failure(PairFailure.MacUnavailable)
            }
        } ?: run {
            Log.w(TAG, "[GATEWAY_PAIR_TIMEOUT]")
            PairResult.Failure(PairFailure.MacUnavailable)
        }

        when (result) {
            is PairResult.Success ->
                Log.d(TAG, "[GATEWAY_PAIR_SUCCEEDED] mac=${result.macDeviceName} ver=${result.serverVersion}")
            is PairResult.Failure ->
                Log.w(TAG, "[GATEWAY_PAIR_FAILED] reason=${result.reason}")
        }
        result
    }

    private fun buildPairRequestJson(
        deviceId: String,
        deviceName: String,
        pairingCode: String,
        appVersion: String,
        capabilities: List<String>,
    ): String = JSONObject().apply {
        put("deviceId",     deviceId)
        put("deviceName",   deviceName)
        put("code",         pairingCode)
        put("appVersion",   appVersion)
        put("platform",     "android")
        val caps = org.json.JSONArray()
        capabilities.forEach { caps.put(it) }
        put("capabilities", caps)
    }.toString()

    private fun parsePairResponse(raw: String): PairResult {
        return try {
            val json  = JSONObject(raw)
            val token = json.optString("sessionToken").ifBlank { return PairResult.Failure(PairFailure.BadResponse) }
            PairResult.Success(
                sessionToken   = token,
                macDeviceName  = json.optString("macDeviceName", "Mac Jarvis"),
                serverVersion  = json.optString("serverVersion", ""),
            )
        } catch (e: Exception) {
            Log.w(TAG, "[GATEWAY_PAIR_PARSE_ERROR] ${e.message?.take(60)}")
            PairResult.Failure(PairFailure.BadResponse)
        }
    }

}

sealed class PairResult {
    data class Success(
        val sessionToken: String,
        val macDeviceName: String,
        val serverVersion: String,
    ) : PairResult() {
        override fun toString(): String =
            "PairResult.Success(sessionToken=[REDACTED], macDeviceName=$macDeviceName, serverVersion=$serverVersion)"
    }
    data class Failure(val reason: PairFailure) : PairResult()
}

enum class PairFailure {
    /** Pairing code was wrong or expired (HTTP 401). */
    InvalidCode,
    /** Device is already paired (HTTP 409). */
    AlreadyPaired,
    /** Connection refused, timeout, or DNS failure. */
    MacUnavailable,
    /** Response could not be parsed. */
    BadResponse,
}
