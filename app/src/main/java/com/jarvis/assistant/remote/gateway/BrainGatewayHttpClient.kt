package com.jarvis.assistant.remote.gateway

import android.util.Log
import com.jarvis.assistant.llm.LlmException
import com.jarvis.assistant.llm.NetworkClient
import com.jarvis.assistant.remote.macbrain.AndroidInteractionEvent
import com.jarvis.assistant.remote.macbrain.BrainCircuitBreaker
import com.jarvis.assistant.remote.macbrain.BrainContextCache
import com.jarvis.assistant.remote.macbrain.BrainContextRequest
import com.jarvis.assistant.remote.macbrain.BrainContextResponse
import com.jarvis.assistant.remote.macbrain.BrainRequestDeduper
import com.jarvis.assistant.remote.macbrain.MacBrainClient
import com.jarvis.assistant.remote.macbrain.MacBrainStats
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * HTTP client for the unified Mac Brain Gateway.
 *
 * Implements [MacBrainClient] so it can replace [HttpMacBrainClient] wherever
 * the runtime or diagnostics need a Brain context source.
 *
 * ROLE MODEL
 * ----------
 * Android Jarvis is always the HTTP CLIENT.  Mac Jarvis hosts the Brain server.
 * Android sends context requests (transcript + intent) and receives enriched
 * memories, preferences, and project summaries in return.
 * Android also POSTs interaction events to /v1/interactions so Mac can learn.
 *
 * KEY DIFFERENCES vs [HttpMacBrainClient]:
 *   • Auth: `Authorization: Bearer <sessionToken>` (session token from pairing,
 *     not a separately configured API key)
 *   • Feature gate: `isPaired` (no separate enable toggle — paired = enabled)
 *   • Context endpoint: `/v1/chat`   (was `/brain/context`)
 *   • Health endpoint:  `/health`    (was `/brain/health`)
 *   • Events endpoint:  `/v1/interactions`
 *   • HTTP 401 on any call → token revoked → clears pairing in settings repository
 *
 * PROTECTION LAYERS (same as [HttpMacBrainClient]):
 *   1. Pairing gate    — returns null immediately when not paired
 *   2. URL validation  — rejects non-http/https base URLs
 *   3. Circuit breaker — drops requests while circuit is OPEN
 *   4. Result cache    — returns recent response without a network round-trip
 *   5. In-flight dedup — drops identical concurrent requests
 *   6. Hard timeout    — [FETCH_TIMEOUT_MS] keeps speech from stalling
 */
class BrainGatewayHttpClient(
    private val settingsRepo:   BrainGatewaySettingsRepository,
    private val appVersion:     String              = "",
    private val circuitBreaker: BrainCircuitBreaker = BrainCircuitBreaker(),
    private val cache:          BrainContextCache   = BrainContextCache(),
    private val deduper:        BrainRequestDeduper = BrainRequestDeduper(),
) : MacBrainClient {

    companion object {
        private const val TAG               = "BrainGatewayHttp"
        private const val FETCH_TIMEOUT_MS  = 2_000L
        private const val HEALTH_TIMEOUT_MS = 750L
        internal const val MAX_RESPONSE_BYTES = 32 * 1024
        private const val API_VERSION       = 1

        internal fun isValidBaseUrl(url: String): Boolean =
            url.startsWith("http://", ignoreCase = true) ||
            url.startsWith("https://", ignoreCase = true)
    }

    init {
        MacBrainStats.register(cache, circuitBreaker, deduper)
    }

    // ── fetchContext ───────────────────────────────────────────────────────────

    override suspend fun fetchContext(request: BrainContextRequest): BrainContextResponse? =
        withContext(Dispatchers.IO) {
            val cfg = settingsRepo.snapshot()
            if (!cfg.isPaired) {
                Log.d(TAG, "[GATEWAY_FETCH_SKIPPED] reason=not_paired")
                return@withContext null
            }

            val baseUrl = cfg.baseUrl.trimEnd('/')
            if (!isValidBaseUrl(baseUrl)) {
                Log.w(TAG, "[GATEWAY_FETCH_SKIPPED] reason=invalid_url")
                return@withContext null
            }

            if (circuitBreaker.isOpen()) {
                MacBrainStats.record { copy(lastRequestResult = "skipped", totalSkipped = totalSkipped + 1) }
                Log.d(TAG, "[GATEWAY_CIRCUIT_OPEN] intent=${request.intentHint}")
                return@withContext null
            }

            val cacheKey = BrainContextCache.cacheKey(request.transcript, request.intentHint)
            val cached = cache.get(cacheKey)
            if (cached != null) {
                MacBrainStats.record {
                    copy(
                        lastRequestIntent = request.intentHint,
                        lastRequestResult = "cache_hit",
                        lastCacheHitAt    = System.currentTimeMillis(),
                        totalCacheHits    = totalCacheHits + 1,
                    )
                }
                return@withContext cached
            }

            if (!deduper.tryAcquire(cacheKey)) {
                MacBrainStats.record { copy(lastRequestResult = "skipped", totalSkipped = totalSkipped + 1) }
                return@withContext null
            }

            val requestId = UUID.randomUUID().toString()
            val t0        = System.currentTimeMillis()
            MacBrainStats.record {
                copy(lastRequestIntent = request.intentHint, totalRequests = totalRequests + 1)
            }
            Log.d(TAG, "[GATEWAY_FETCH_STARTED] intent=${request.intentHint} id=$requestId")

            try {
                var failureReason: String? = null
                val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                    try {
                        val raw = NetworkClient.post(
                            url     = cfg.chatUrl,
                            headers = authHeader(cfg.sessionToken),
                            body    = buildContextJson(request, requestId, cfg.deviceId),
                        )
                        if (raw.toByteArray(Charsets.UTF_8).size > MAX_RESPONSE_BYTES) {
                            failureReason = "response_too_large"
                            return@withTimeoutOrNull null
                        }
                        parseContextResponse(raw)
                    } catch (e: LlmException) {
                        if (e.message?.startsWith("HTTP 401") == true ||
                            e.message?.startsWith("HTTP 403") == true) {
                            Log.w(TAG, "[GATEWAY_TOKEN_REVOKED] clearing pairing")
                            settingsRepo.clearPairing()
                            failureReason = "token_revoked"
                        } else {
                            failureReason = "${e.javaClass.simpleName}: ${e.message?.take(80)}"
                        }
                        null
                    } catch (e: Exception) {
                        failureReason = "${e.javaClass.simpleName}: ${e.message?.take(80)}"
                        null
                    }
                }

                val latency = System.currentTimeMillis() - t0
                when {
                    result != null -> {
                        Log.d(TAG, "[GATEWAY_FETCH_OK] latency_ms=$latency memories=${result.memories.size}")
                        circuitBreaker.recordSuccess()
                        cache.put(cacheKey, result)
                        MacBrainStats.record {
                            copy(
                                lastRequestResult = "succeeded",
                                lastSucceededAt   = System.currentTimeMillis(),
                                totalSuccesses    = totalSuccesses + 1,
                            )
                        }
                    }
                    failureReason != null -> {
                        Log.w(TAG, "[GATEWAY_FETCH_FAILED] reason=$failureReason latency_ms=$latency")
                        circuitBreaker.recordFailure()
                        MacBrainStats.record {
                            copy(
                                lastRequestResult = "failed",
                                lastFailureReason = failureReason ?: "unknown",
                                totalFailures     = totalFailures + 1,
                            )
                        }
                    }
                    else -> {
                        Log.w(TAG, "[GATEWAY_FETCH_TIMEOUT] latency_ms=$latency")
                        circuitBreaker.recordFailure()
                        MacBrainStats.record {
                            copy(
                                lastRequestResult = "timeout",
                                lastTimeoutAt     = System.currentTimeMillis(),
                                totalTimeouts     = totalTimeouts + 1,
                            )
                        }
                    }
                }
                result
            } finally {
                deduper.release(cacheKey)
            }
        }

    // ── health ─────────────────────────────────────────────────────────────────

    override suspend fun health(): Boolean = withContext(Dispatchers.IO) {
        val cfg = settingsRepo.snapshot()
        if (!cfg.isPaired) return@withContext false
        if (!isValidBaseUrl(cfg.baseUrl)) return@withContext false

        val t0 = System.currentTimeMillis()
        val up = withTimeoutOrNull(HEALTH_TIMEOUT_MS) {
            try {
                // Health endpoint is unauthenticated — no token needed
                NetworkClient.get(url = cfg.healthUrl, headers = emptyMap())
                true
            } catch (e: Exception) {
                Log.d(TAG, "[GATEWAY_HEALTH] down: ${e.message?.take(60)}")
                false
            }
        } ?: false

        val latency = System.currentTimeMillis() - t0
        Log.d(TAG, "[GATEWAY_HEALTH] status=${if (up) "ok" else "down"} latency_ms=$latency")
        MacBrainStats.record {
            copy(
                lastHealthCheckedAt = System.currentTimeMillis(),
                lastHealthLatencyMs = latency,
                lastHealthOk        = up,
            )
        }
        up
    }

    // ── reportEvents ───────────────────────────────────────────────────────────

    override suspend fun reportEvent(event: AndroidInteractionEvent): Boolean =
        reportEvents(listOf(event)).isNotEmpty()

    override suspend fun reportEvents(events: List<AndroidInteractionEvent>): List<String> =
        withContext(Dispatchers.IO) {
            val cfg = settingsRepo.snapshot()
            if (!cfg.isPaired) return@withContext emptyList()
            if (!isValidBaseUrl(cfg.baseUrl)) return@withContext emptyList()
            if (circuitBreaker.isOpen()) return@withContext emptyList()

            val url = "${cfg.baseUrl.trimEnd('/')}/v1/interactions"
            try {
                NetworkClient.post(
                    url     = url,
                    headers = authHeader(cfg.sessionToken),
                    body    = buildEventsJson(events),
                )
                Log.d(TAG, "[GATEWAY_EVENTS_REPORTED] count=${events.size}")
                events.map { it.id }
            } catch (e: LlmException) {
                if (e.message?.startsWith("HTTP 401") == true ||
                    e.message?.startsWith("HTTP 403") == true) {
                    Log.w(TAG, "[GATEWAY_TOKEN_REVOKED] on events — clearing pairing")
                    settingsRepo.clearPairing()
                }
                emptyList()
            } catch (e: Exception) {
                Log.w(TAG, "[GATEWAY_EVENTS_FAILED] ${e.message?.take(80)}")
                emptyList()
            }
        }

    // ── Serialisation ──────────────────────────────────────────────────────────

    private fun buildContextJson(
        request: BrainContextRequest,
        requestId: String,
        deviceId: String,
    ): String = JSONObject().apply {
        put("transcript",  request.transcript.take(512))
        put("intentHint",  request.intentHint)
        request.recentSummary?.let { put("recentSummary", it.take(256)) }
        request.activeApp?.let    { put("activeApp", it) }
        put("meta", JSONObject().apply {
            put("apiVersion",        API_VERSION)
            put("androidAppVersion", appVersion)
            put("deviceId",          deviceId)
            put("requestId",         requestId)
            put("timestamp",         System.currentTimeMillis())
        })
    }.toString()

    private fun buildEventsJson(events: List<AndroidInteractionEvent>): String {
        val arr = JSONArray()
        events.forEach { e ->
            arr.put(JSONObject().apply {
                put("id",                   e.id)
                put("timestamp",            e.timestamp)
                put("deviceId",             e.deviceId)
                put("transcript",           e.transcript.take(300))
                put("normalizedTranscript", e.normalizedTranscript.take(200))
                put("intent",               e.intent)
                put("actionTaken",          e.actionTaken)
                put("success",              e.success)
                put("confidence",           e.confidence.toDouble())
                put("eventType",            e.eventType.name)
                e.correction?.let { put("correction", it) }
                e.error?.let      { put("error",      it.take(100)) }
                e.appContext?.let  { put("appContext", it) }
                if (e.entities.isNotEmpty()) {
                    val ents = JSONObject()
                    e.entities.forEach { (k, v) -> ents.put(k, v) }
                    put("entities", ents)
                }
            })
        }
        return JSONObject().apply {
            put("events", arr)
            put("meta", JSONObject().apply {
                put("apiVersion",        API_VERSION)
                put("androidAppVersion", appVersion)
                put("batchId",           UUID.randomUUID().toString())
                put("timestamp",         System.currentTimeMillis())
            })
        }.toString()
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    private fun authHeader(token: String?): Map<String, String> =
        if (token.isNullOrBlank()) emptyMap()
        else mapOf("Authorization" to "Bearer $token")

    /** Same parsing logic as [HttpMacBrainClient.parseResponseBody]. */
    private fun parseContextResponse(raw: String): BrainContextResponse? = try {
        val json        = JSONObject(raw)
        val memories    = jsonStringArray(json.optJSONArray("memories"))
        val corrections = jsonStringArray(json.optJSONArray("corrections"))
        val preferences = jsonStringMap(json.optJSONObject("preferences"))
        val project     = json.optString("projectSummary").takeIf { it.isNotBlank() }
        BrainContextResponse(
            memories       = memories,
            preferences    = preferences,
            projectSummary = project,
            corrections    = corrections,
        )
    } catch (e: Exception) {
        Log.w(TAG, "[GATEWAY_PARSE_ERROR] ${e.message?.take(60)}")
        null
    }

    private fun jsonStringArray(arr: JSONArray?): List<String> {
        if (arr == null) return emptyList()
        return buildList {
            for (i in 0 until arr.length()) {
                arr.optString(i).takeIf { it.isNotBlank() }?.let { add(it) }
            }
        }
    }

    private fun jsonStringMap(obj: JSONObject?): Map<String, String> {
        if (obj == null) return emptyMap()
        val map = mutableMapOf<String, String>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            obj.optString(k).takeIf { it.isNotBlank() }?.let { map[k] = it }
        }
        return map
    }
}
