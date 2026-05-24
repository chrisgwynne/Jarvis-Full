package com.jarvis.assistant.remote.macbrain

import android.util.Log
import com.jarvis.assistant.llm.NetworkClient
import com.jarvis.assistant.util.SettingsStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * HttpMacBrainClient — production [MacBrainClient] implementation.
 *
 * PROTECTION LAYERS (applied in order):
 *   1. Feature flag    — returns null immediately when Brain is disabled.
 *   2. URL validation  — rejects non-http/https base URLs before any network touch.
 *   3. Circuit breaker — returns null immediately when the Brain has been repeatedly
 *                        unreachable; auto-recovers after [BrainCircuitBreaker.openDurationMs].
 *   4. Result cache    — returns a recent response without touching the network.
 *   5. In-flight dedup — drops identical concurrent requests rather than stacking them.
 *   6. Hard timeout    — [FETCH_TIMEOUT_MS] (2 s) ensures speech is never stalled.
 *
 * TELEMETRY
 *   Every significant event is recorded via [MacBrainStats.record] so
 *   [MacBrainDiagnosticsScreen] always reflects the current state.
 *
 * SECURITY
 *   API key is injected as a Bearer header — never logged.
 *   Responses larger than [MAX_RESPONSE_BYTES] are discarded to prevent prompt injection.
 *   Base URL is validated for http/https scheme before any network call.
 *
 * VERSIONING
 *   Every request body carries a [meta] block with apiVersion, androidAppVersion,
 *   deviceId, requestId, and timestamp. The server ignores unknown fields, so this
 *   is additive and backward-compatible with unversioned server implementations.
 */
class HttpMacBrainClient(
    private val settings:       SettingsStore,
    /** Android app version string forwarded in request metadata, e.g. "1.4.2". */
    private val appVersion:     String              = "",
    private val circuitBreaker: BrainCircuitBreaker = BrainCircuitBreaker(),
    private val cache:          BrainContextCache   = BrainContextCache(),
    private val deduper:        BrainRequestDeduper = BrainRequestDeduper(),
) : MacBrainClient {

    companion object {
        private const val TAG                = "MacBrainHttp"
        private const val FETCH_TIMEOUT_MS   = 2_000L
        private const val HEALTH_TIMEOUT_MS  = 750L
        internal const val MAX_RESPONSE_BYTES = 32 * 1024
        /** Wire protocol version. Increment when the request/response schema changes. */
        private const val API_VERSION        = 1

        // ── URL validation ─────────────────────────────────────────────────────

        /**
         * Returns true when [url] starts with a supported http or https scheme
         * (case-insensitive). Rejects blank, relative, ws://, ftp:// etc.
         *
         * Called before any network attempt so a misconfigured URL fails fast and
         * silently rather than producing a confusing connection error.
         */
        internal fun isValidBaseUrl(url: String): Boolean =
            url.startsWith("http://", ignoreCase = true) ||
            url.startsWith("https://", ignoreCase = true)

        // ── Response parsing ───────────────────────────────────────────────────

        /**
         * Parse a raw /brain/context response body into a [BrainContextResponse].
         *
         * CONTRACT SAFETY — this function guarantees:
         *   • Unknown JSON fields are silently ignored (org.json skips unrecognised keys).
         *   • Missing optional arrays/objects fall back to empty via opt* methods.
         *   • A null or missing projectSummary is returned as null (not empty string).
         *   • Blank individual items in arrays are filtered out.
         *   • Any parse exception returns null — the caller treats null as "no context".
         *
         * Exposed as internal so the companion can be tested without Android context.
         */
        internal fun parseResponseBody(raw: String): BrainContextResponse? = try {
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
            Log.w(TAG, "[BRAIN_REQUEST_FAILED] reason=parse_error msg=${e.message?.take(60)}")
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

    init {
        // Register with the global stats hub so the diagnostics screen can read
        // live values (cache size, circuit state, in-flight count) and the
        // SettingsViewModel can trigger clear/reset operations.
        MacBrainStats.register(cache, circuitBreaker, deduper)
        MacBrainStats.record { copy(enabled = settings.macBrainEnabled) }
    }

    // ── fetchContext ───────────────────────────────────────────────────────────

    override suspend fun fetchContext(request: BrainContextRequest): BrainContextResponse? =
        withContext(Dispatchers.IO) {
            if (!settings.macBrainEnabled) return@withContext null

            val baseUrl = settings.macBrainBaseUrl.trimEnd('/')
            val apiKey  = settings.macBrainApiKey
            if (baseUrl.isBlank()) {
                MacBrainStats.record { copy(lastRequestResult = "skipped", totalSkipped = totalSkipped + 1) }
                Log.d(TAG, "[BRAIN_REQUEST_SKIPPED] reason=no_url")
                return@withContext null
            }

            // URL scheme guard — reject ftp://, ws://, bare hostnames, etc.
            if (!isValidBaseUrl(baseUrl)) {
                MacBrainStats.record { copy(lastRequestResult = "skipped", totalSkipped = totalSkipped + 1) }
                Log.w(TAG, "[BRAIN_REQUEST_SKIPPED] reason=invalid_scheme url_prefix=${baseUrl.take(12)}")
                return@withContext null
            }

            // Circuit breaker
            if (circuitBreaker.isOpen()) {
                MacBrainStats.record { copy(lastRequestResult = "skipped", totalSkipped = totalSkipped + 1) }
                Log.d(TAG, "[BRAIN_CIRCUIT_OPEN] skipping fetch intent=${request.intentHint}")
                return@withContext null
            }

            val cacheKey = BrainContextCache.cacheKey(request.transcript, request.intentHint)

            // Result cache
            val cached = cache.get(cacheKey)
            if (cached != null) {
                val now = System.currentTimeMillis()
                MacBrainStats.record {
                    copy(
                        lastRequestIntent = request.intentHint,
                        lastRequestResult = "cache_hit",
                        lastCacheHitAt    = now,
                        totalCacheHits    = totalCacheHits + 1,
                    )
                }
                Log.d(TAG, "[BRAIN_REQUEST_CACHE_HIT] intent=${request.intentHint}")
                return@withContext cached
            }
            Log.d(TAG, "[BRAIN_REQUEST_CACHE_MISS] intent=${request.intentHint}")

            // In-flight dedup
            if (!deduper.tryAcquire(cacheKey)) {
                MacBrainStats.record { copy(lastRequestResult = "skipped", totalSkipped = totalSkipped + 1) }
                return@withContext null
            }

            val requestId = UUID.randomUUID().toString()
            val now0      = System.currentTimeMillis()
            MacBrainStats.record {
                copy(
                    lastRequestIntent = request.intentHint,
                    totalRequests     = totalRequests + 1,
                )
            }
            Log.d(TAG, "[BRAIN_REQUEST_STARTED] intent=${request.intentHint} " +
                "requestId=$requestId transcript_len=${request.transcript.length}")

            try {
                var failureReason: String? = null

                val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                    try {
                        val raw = NetworkClient.post(
                            url     = "$baseUrl/brain/context",
                            headers = if (apiKey.isNotBlank()) mapOf("Authorization" to "Bearer $apiKey") else emptyMap(),
                            body    = buildRequestJson(request, requestId),
                        )
                        if (raw.toByteArray(Charsets.UTF_8).size > MAX_RESPONSE_BYTES) {
                            failureReason = "response_too_large"
                            return@withTimeoutOrNull null
                        }
                        parseResponseBody(raw)
                    } catch (e: Exception) {
                        failureReason = "${e.javaClass.simpleName}: ${e.message?.take(80)}"
                        null
                    }
                }

                val latency = System.currentTimeMillis() - now0
                when {
                    result != null -> {
                        Log.d(TAG, "[BRAIN_REQUEST_SUCCEEDED] latency_ms=$latency requestId=$requestId " +
                            "memories=${result.memories.size} " +
                            "has_project=${result.projectSummary != null} " +
                            "prefs=${result.preferences.size}")
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
                        Log.w(TAG, "[BRAIN_REQUEST_FAILED] reason=$failureReason " +
                            "latency_ms=$latency requestId=$requestId")
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
                        Log.w(TAG, "[BRAIN_REQUEST_TIMEOUT] latency_ms=$latency requestId=$requestId")
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
        if (!settings.macBrainEnabled) return@withContext false
        val baseUrl = settings.macBrainBaseUrl.trimEnd('/')
        val apiKey  = settings.macBrainApiKey
        if (baseUrl.isBlank()) return@withContext false
        if (!isValidBaseUrl(baseUrl)) return@withContext false

        val t0 = System.currentTimeMillis()
        val up = withTimeoutOrNull(HEALTH_TIMEOUT_MS) {
            try {
                NetworkClient.get(
                    url     = "$baseUrl/brain/health",
                    headers = if (apiKey.isNotBlank()) mapOf("Authorization" to "Bearer $apiKey") else emptyMap(),
                )
                true
            } catch (e: Exception) {
                Log.d(TAG, "[BRAIN_HEALTH] status=unreachable msg=${e.message?.take(60)}")
                false
            }
        } ?: false

        val latency = System.currentTimeMillis() - t0
        Log.d(TAG, "[BRAIN_HEALTH] status=${if (up) "ok" else "down"} latency_ms=$latency")
        MacBrainStats.record {
            copy(
                lastHealthCheckedAt = System.currentTimeMillis(),
                lastHealthLatencyMs = latency,
                lastHealthOk        = up,
            )
        }
        up
    }

    // ── Serialisation ──────────────────────────────────────────────────────────

    /**
     * Build the /brain/context request body.
     *
     * The [meta] block carries tracing metadata. The server ignores unknown fields,
     * so adding this block does not break unversioned server implementations.
     * API key is deliberately absent — it travels as a Bearer header only.
     */
    private fun buildRequestJson(request: BrainContextRequest, requestId: String): String =
        JSONObject().apply {
            put("transcript",  request.transcript.take(512))
            put("intentHint",  request.intentHint)
            request.recentSummary?.let { put("recentSummary", it.take(256)) }
            request.activeApp?.let    { put("activeApp", it) }
            // Request metadata — additive, backward-compatible.
            put("meta", JSONObject().apply {
                put("apiVersion",        API_VERSION)
                put("androidAppVersion", appVersion)
                put("deviceId",          settings.macBrainDeviceId)
                put("requestId",         requestId)
                put("timestamp",         System.currentTimeMillis())
            })
        }.toString()

    // ── reportEvent / reportEvents ──────────────────────────────────────────────

    override suspend fun reportEvent(event: AndroidInteractionEvent): Boolean =
        reportEvents(listOf(event)).isNotEmpty()

    override suspend fun reportEvents(events: List<AndroidInteractionEvent>): List<String> =
        withContext(Dispatchers.IO) {
            if (!settings.macBrainEnabled) return@withContext emptyList()
            val baseUrl = settings.macBrainBaseUrl.trimEnd('/')
            val apiKey  = settings.macBrainApiKey
            if (baseUrl.isBlank() || apiKey.isBlank()) return@withContext emptyList()
            if (!isValidBaseUrl(baseUrl)) return@withContext emptyList()
            if (circuitBreaker.isOpen()) return@withContext emptyList()

            try {
                NetworkClient.post(
                    url     = "$baseUrl/brain/interactions",
                    headers = mapOf("Authorization" to "Bearer $apiKey"),
                    body    = buildReportJson(events),
                )
                Log.d(TAG, "[BRAIN_SYNC_REPORTED] count=${events.size}")
                events.map { it.id }   // all accepted
            } catch (e: Exception) {
                Log.w(TAG, "[BRAIN_SYNC_REPORT_FAILED] ${e.message?.take(80)}")
                emptyList()
            }
        }

    /**
     * Build the /brain/interactions batch body.
     *
     * Top-level [meta] carries batch-level tracing metadata. Individual events
     * already contain deviceId and timestamp. API key is in the header only.
     */
    private fun buildReportJson(events: List<AndroidInteractionEvent>): String {
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
            // Batch-level metadata — additive, backward-compatible.
            put("meta", JSONObject().apply {
                put("apiVersion",        API_VERSION)
                put("androidAppVersion", appVersion)
                put("batchId",           UUID.randomUUID().toString())
                put("timestamp",         System.currentTimeMillis())
            })
        }.toString()
    }
}
