package com.jarvis.assistant.remote.brain

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import com.jarvis.assistant.core.events.EventBus
import com.jarvis.assistant.core.events.EventKind
import com.jarvis.assistant.llm.LlmException
import com.jarvis.assistant.llm.NetworkClient
import com.jarvis.assistant.notifications.JarvisNotificationListener
import com.jarvis.assistant.notifications.MessagingAppCapabilityRegistry
import com.jarvis.assistant.remote.macbrain.AndroidInteractionEvent
import com.jarvis.assistant.remote.macbrain.BrainContextRequest
import com.jarvis.assistant.remote.macbrain.BrainContextResponse
import com.jarvis.assistant.tools.ContactLookup
import com.jarvis.assistant.util.LatencyTracker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume

/**
 * MacBrainConnectionManager — single authoritative networking class for all
 * Mac Jarvis communication.
 *
 * Consolidates:
 *  - WebSocket lifecycle (previously BrainGatewayWebSocketClient)
 *  - HTTP context/health/events (previously BrainGatewayHttpClient)
 *  - Pairing handshake (previously BrainGatewayPairingClient)
 *  - Network reconnect (previously NetworkChangeObserver)
 *  - Event relay (previously AndroidEventBroadcaster)
 *  - Remote action request/response (previously RemoteActionSender)
 */
class MacBrainConnectionManager(
    private val context: Context,
    val settingsRepo: MacBrainSettingsRepository,
) : com.jarvis.assistant.remote.macbrain.MacBrainClient {
    companion object {
        private const val TAG                = "MacBrainManager"
        private const val HEARTBEAT_MS       = 30_000L
        private const val MAX_BACKOFF_MS     = 30_000L
        private const val FETCH_TIMEOUT_MS   = 2_000L
        private const val HEALTH_TIMEOUT_MS  = 750L
        private const val PAIR_TIMEOUT_MS    = 10_000L
        private const val REMOTE_ACTION_TIMEOUT_MS = 30_000L
        private const val MAX_RESPONSE_BYTES = 32 * 1024
        private const val API_VERSION        = 1
        private const val RECONNECT_DELAY_MS = 1_000L
        private const val NETWORK_RECONNECT_DELAY_MS = 1_000L

        val DEFAULT_CAPABILITIES = listOf("commands", "events", "bridge", "camera")

        private val _sharedStatus = MutableStateFlow(MacBrainStatus.Disconnected)
        val sharedStatus: StateFlow<MacBrainStatus> = _sharedStatus.asStateFlow()
        val sharedLastActivityAtMs = AtomicLong(0L)

        @Volatile var sharedMacAssistantActive: Boolean = true
            private set
        @Volatile var lastSharedInboundCommand: String = ""
            private set
        @Volatile var lastSharedInboundStatus: String = ""
            private set
    }

    val status: StateFlow<MacBrainStatus> get() = _sharedStatus

    val isPaired: Boolean get() = settingsRepo.snapshot().isPaired

    // ── Callbacks (set by JarvisRuntime) ─────────────────────────────────────
    var onReplyFinal: ((text: String, correlationId: String?) -> Unit)? = null
    var onNack: ((correlationId: String?) -> Unit)? = null
    var onReplyPartial: ((String) -> Unit)? = null
    var onOrchestrateSpeak: ((String) -> Unit)? = null
    var onOrchestrateSilent: ((String) -> Unit)? = null
    var onProactiveNotify: ((String, String) -> Unit)? = null
    var onProactiveCommPrompt: ((JSONObject) -> Unit)? = null
    var onHandoffReceived: ((JSONObject) -> Unit)? = null
    var onNotificationForward: ((JSONObject) -> Unit)? = null
    var onClipboardUpdate: ((String) -> Unit)? = null
    var commWatchdogManager: com.jarvis.assistant.comm.CommWatchdogManager? = null

    // ── Diagnostics ───────────────────────────────────────────────────────────
    val reconnectCount = AtomicInteger(0)
    val lastEventSentAtMs = AtomicLong(0L)
    @Volatile var lastInboundCommand: String = ""; private set
    val lastInboundAtMs = AtomicLong(0L)
    @Volatile var lastInboundStatus: String = ""; private set
    @Volatile var macAssistantActive: Boolean = true; private set
    val lastEventCommand: String get() = lastInboundCommand

    // ── WS internals ──────────────────────────────────────────────────────────
    private val running = AtomicBoolean(false)
    @Volatile private var ws: WebSocket? = null
    @Volatile private var serverInitiatedClose = false
    @Volatile private var scope: CoroutineScope = newScope()
    @Volatile private var heartbeatJob: Job? = null

    private val httpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .connectTimeout(15, TimeUnit.SECONDS)
            .pingInterval(30, TimeUnit.SECONDS)
            .build()
    }

    // ── HTTP state (simple circuit breaker + cache + deduper) ─────────────────
    private var cbFailures = 0
    private var cbOpenUntilMs = 0L
    private val contextCache = mutableMapOf<String, Pair<Long, BrainContextResponse>>()
    private val contextCacheTtlMs = 60_000L
    private val inFlightKeys = ConcurrentHashMap.newKeySet<String>()

    // ── Network observer ─────────────────────────────────────────────────────
    private val networkRegistered = AtomicBoolean(false)
    @Volatile private var wasNetworkConnected = false
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── Event broadcaster ────────────────────────────────────────────────────
    private var broadcasterJob: Job? = null
    private var broadcasterScope: CoroutineScope? = null

    // ── Deduplication for events ──────────────────────────────────────────────
    private val dedupLock = Any()
    private val dedupCache = object : LinkedHashMap<String, Long>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, Long>) = size > 200
    }
    @Volatile private var sawRinging  = false
    @Volatile private var sawAnswered = false
    @Volatile private var callerName  = ""

    // ── Remote action pending continuations ───────────────────────────────────
    private val pendingActions = ConcurrentHashMap<String, (RemoteActionOutcome) -> Unit>()

    // ── Executor ──────────────────────────────────────────────────────────────
    private val executor: MacRemoteCommandExecutor by lazy {
        MacRemoteCommandExecutor(
            context  = context,
            contacts = ContactLookup(context),
        )
    }

    private fun newScope() = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // ────────────────────────────────────────────────────────────────────────
    // Lifecycle
    // ────────────────────────────────────────────────────────────────────────

    fun start() {
        if (running.getAndSet(true)) return
        if (!scope.coroutineContext[Job]!!.isActive) scope = newScope()
        _sharedStatus.value = MacBrainStatus.Connecting
        scope.launch { connectLoop() }
        registerNetworkCallback()
    }

    fun stop() {
        running.set(false)
        heartbeatJob?.cancel()
        heartbeatJob = null
        ws?.close(1000, "Service stopping")
        ws = null
        serverInitiatedClose = false
        _sharedStatus.value = MacBrainStatus.Disconnected
        scope.cancel()
        reconnectCount.set(0)
        unregisterNetworkCallback()
    }

    fun restart() {
        stop()
        scope = newScope()
        start()
    }

    // ────────────────────────────────────────────────────────────────────────
    // WebSocket connection loop
    // ────────────────────────────────────────────────────────────────────────

    private suspend fun connectLoop() {
        var backoffMs = 1_000L
        while (running.get()) {
            val cfg = settingsRepo.snapshot()
            if (!cfg.isPaired) {
                _sharedStatus.value = MacBrainStatus.NotPaired
                Log.d(TAG, "Not paired — stopping connect loop")
                running.set(false)
                return
            }
            _sharedStatus.value = MacBrainStatus.Connecting
            val outcome = connect(cfg)

            if (!running.get()) break

            when (outcome) {
                ConnectOutcome.Unauthorized -> {
                    Log.w(TAG, "Session token rejected — clearing pairing")
                    settingsRepo.clearPairing()
                    _sharedStatus.value = MacBrainStatus.Unauthorized
                    running.set(false)
                    return
                }
                ConnectOutcome.TokenRevoked -> {
                    Log.w(TAG, "Token revoked by gateway — clearing pairing")
                    settingsRepo.clearPairing()
                    _sharedStatus.value = MacBrainStatus.Unauthorized
                    running.set(false)
                    return
                }
                ConnectOutcome.Disconnected -> {
                    val waitMs = if (serverInitiatedClose) {
                        serverInitiatedClose = false
                        MAX_BACKOFF_MS
                    } else {
                        backoffMs
                    }
                    _sharedStatus.value = MacBrainStatus.Reconnecting
                    reconnectCount.incrementAndGet()
                    Log.d(TAG, "Reconnecting in ${waitMs}ms (#${reconnectCount.get()})")
                    delay(waitMs)
                    backoffMs = (backoffMs * 2).coerceAtMost(MAX_BACKOFF_MS)
                }
            }
        }
    }

    private suspend fun connect(cfg: MacBrainConfig): ConnectOutcome =
        suspendCancellableCoroutine { cont ->
            val token = cfg.deviceToken ?: ""
            Log.d(TAG, "Connecting to ${cfg.wsUrl}")

            val req = Request.Builder()
                .url(cfg.wsUrl)
                .addHeader("Authorization", "Bearer $token")
                .addHeader("X-Platform", "android")
                .addHeader("X-Device-Id", settingsRepo.stableDeviceId())
                .build()

            ws = httpClient.newWebSocket(req, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    ws = webSocket
                    Log.d(TAG, "Connected to Mac Brain")
                    reconnectCount.set(0)
                    serverInitiatedClose = false
                    _sharedStatus.value = MacBrainStatus.Connected
                    settingsRepo.recordConnected()
                    sendCapabilitiesReport()
                    heartbeatJob?.cancel()
                    heartbeatJob = scope.launch { heartbeatLoop() }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    handleInbound(text)
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    serverInitiatedClose = true
                    if (code == 4401 || code == 4403) {
                        webSocket.close(1000, null)
                        if (cont.isActive) cont.resume(ConnectOutcome.TokenRevoked)
                    } else {
                        webSocket.close(1000, null)
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    val code = response?.code ?: 0
                    Log.w(TAG, "WS failure: ${t.javaClass.simpleName} http=$code ${t.message?.take(80)}")
                    val outcome = when (code) {
                        401, 403 -> ConnectOutcome.Unauthorized
                        else     -> ConnectOutcome.Disconnected
                    }
                    if (running.get()) _sharedStatus.value = MacBrainStatus.Reconnecting
                    if (cont.isActive) cont.resume(outcome)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    Log.d(TAG, "WS closed: $code $reason")
                    if (running.get()) _sharedStatus.value = MacBrainStatus.Reconnecting
                    if (cont.isActive) cont.resume(ConnectOutcome.Disconnected)
                }
            })

            cont.invokeOnCancellation { ws?.close(1000, "Service stopping") }
        }

    // ────────────────────────────────────────────────────────────────────────
    // Heartbeat
    // ────────────────────────────────────────────────────────────────────────

    private suspend fun heartbeatLoop() {
        while (running.get() && _sharedStatus.value == MacBrainStatus.Connected) {
            delay(HEARTBEAT_MS)
            if (_sharedStatus.value != MacBrainStatus.Connected) break
            sendHeartbeat()
        }
    }

    private fun sendHeartbeat() {
        val bm      = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val charging = bm?.isCharging ?: false
        val fgPkg   = com.jarvis.assistant.accessibility.JarvisAccessibilityService
            .currentForegroundPackage
        val fgLabel = if (fgPkg != null) resolveAppLabel(fgPkg) else null
        val frame = JSONObject().apply {
            put("type", "heartbeat")
            put("battery",    batteryLevel())
            put("charging",   charging)
            put("deviceName", deviceName())
            if (fgPkg != null) put("foregroundApp", JSONObject().apply {
                put("package", fgPkg)
                if (fgLabel != null) put("label", fgLabel)
            })
            put("permissions", JSONObject().apply {
                put("notificationListener",
                    JarvisNotificationListener.isGranted(context))
                put("readContacts",
                    context.checkSelfPermission(android.Manifest.permission.READ_CONTACTS) ==
                        android.content.pm.PackageManager.PERMISSION_GRANTED)
                put("readPhoneState",
                    context.checkSelfPermission(android.Manifest.permission.READ_PHONE_STATE) ==
                        android.content.pm.PackageManager.PERMISSION_GRANTED)
            })
        }
        sendFrame(frame)
    }

    private fun sendCapabilitiesReport() {
        val frame = JSONObject().apply {
            put("type", "capability.update")
            put("capabilities", JSONArray(DEFAULT_CAPABILITIES))
        }
        sendFrame(frame)
    }

    // ────────────────────────────────────────────────────────────────────────
    // Inbound dispatch
    // ────────────────────────────────────────────────────────────────────────

    private fun handleInbound(text: String) {
        val json = runCatching { JSONObject(text) }.getOrNull() ?: run {
            Log.w(TAG, "Malformed JSON frame — discarding")
            return
        }

        val frameType = json.optString("type")
        sharedLastActivityAtMs.set(System.currentTimeMillis())
        settingsRepo.recordMacSeen()

        when (frameType) {

            "mac_status" -> {
                val active = json.optBoolean("assistant_active", true)
                macAssistantActive = active
                sharedMacAssistantActive = active
                Log.d(TAG, "mac_status: assistant_active=$active")
                // NOTE: roleArbitrator has been removed — mac_status just updates local state
            }

            "auth_revoked" -> {
                Log.w(TAG, "Gateway sent auth_revoked — clearing pairing")
                settingsRepo.clearPairing()
                _sharedStatus.value = MacBrainStatus.Unauthorized
                running.set(false)
                ws?.close(1000, "auth_revoked")
            }

            "reply.final", "chat.reply.final" -> {
                LatencyTracker.mark(LatencyTracker.DAEMON_REPLY_RECEIVED)
                val replyText = json.optString("text").ifBlank { return }
                val correlationId = json.optString("correlationId").ifBlank { null }
                    ?: json.optString("messageId").ifBlank { null }
                Log.d(TAG, "reply.final: len=${replyText.length} correlationId=$correlationId")
                onReplyFinal?.invoke(replyText, correlationId)
            }

            "reply.partial", "chat.reply.partial" -> {
                LatencyTracker.mark(LatencyTracker.DAEMON_REPLY_RECEIVED)
                val partial = json.optString("text").ifBlank { return }
                onReplyPartial?.invoke(partial)
            }

            "orchestrate.speak" -> {
                LatencyTracker.mark(LatencyTracker.DAEMON_REPLY_RECEIVED)
                val speakText = json.optString("text").ifBlank { return }
                Log.d(TAG, "orchestrate.speak: ${speakText.take(80)}")
                onOrchestrateSpeak?.invoke(speakText)
            }

            "orchestrate.silent" -> {
                val reason = json.optString("reason", "mac_responding")
                Log.d(TAG, "orchestrate.silent: reason=$reason")
                onOrchestrateSilent?.invoke(reason)
            }

            "proactive.notify" -> {
                val title = json.optString("title", "Jarvis")
                val body  = json.optString("body").ifBlank { return }
                Log.d(TAG, "proactive.notify: $title — ${body.take(60)}")
                onProactiveNotify?.invoke(title, body)
            }

            "lease.grant" -> Log.d(TAG, "lease.grant received")
            "lease.deny", "lease.denied" -> Log.d(TAG, "lease.deny received")
            "heartbeat.ack", "pong" -> Log.v(TAG, "heartbeat ack")

            "capability.request" -> {
                Log.d(TAG, "capability.request — resending capabilities")
                sendCapabilitiesReport()
            }

            "session.start", "hello.ack" -> {
                Log.d(TAG, "Session established: type=$frameType")
            }

            "error", "nack" -> {
                val msg = json.optString("message", "unknown error")
                val correlationId = json.optString("correlationId").ifBlank { null }
                    ?: json.optString("messageId").ifBlank { null }
                Log.w(TAG, "Gateway $frameType frame: $msg correlationId=$correlationId")
                onNack?.invoke(correlationId)
            }

            "request" -> {
                val requestId = json.optString("id")
                val command   = json.optString("command")
                val payload   = json.optJSONObject("payload") ?: JSONObject()
                if (requestId.isBlank() || command.isBlank()) return

                lastInboundCommand = command
                lastSharedInboundCommand = command
                lastInboundAtMs.set(System.currentTimeMillis())

                scope.launch {
                    try {
                        val result = executor.execute(command, payload)
                        val statusStr = if (result.ok) result.status ?: "ok" else "error: ${result.message}"
                        lastInboundStatus = statusStr
                        lastSharedInboundStatus = statusStr
                        sendResponse(requestId, result.ok, result.status, result.message, result.payload)
                    } catch (e: Exception) {
                        val statusStr = "error: ${e.message}"
                        lastInboundStatus = statusStr
                        lastSharedInboundStatus = statusStr
                        Log.w(TAG, "Command '$command' threw: ${e.message}")
                        sendResponse(requestId, false, "error", e.message ?: "Unexpected error")
                    }
                }
            }

            "remote.action.result" -> {
                val payload = json.optJSONObject("payload") ?: json
                val requestId = payload.optString("requestId").ifBlank {
                    json.optString("correlationId")
                }
                val success = payload.optBoolean("success", false)
                val spokenSummary = payload.optString("spokenSummary", "Done.")
                val errorCode = payload.optString("errorCode").ifBlank { null }
                val errorMessage = payload.optString("errorMessage").ifBlank { null }
                Log.d(TAG, "remote.action.result: success=$success summary=${spokenSummary.take(60)}")
                if (requestId.isNotBlank()) {
                    pendingActions.remove(requestId)?.invoke(
                        RemoteActionOutcome(
                            requestId     = requestId,
                            success       = success,
                            spokenSummary = spokenSummary,
                            errorCode     = errorCode,
                            errorMessage  = errorMessage,
                        )
                    )
                }
                if (spokenSummary.isNotBlank()) {
                    onReplyFinal?.invoke(spokenSummary, requestId.ifBlank { null })
                }
            }

            "proactive.comm.prompt" -> {
                val payload = json.optJSONObject("payload") ?: JSONObject()
                onProactiveCommPrompt?.invoke(payload)
                Log.d(TAG, "proactive.comm.prompt received for channel=${payload.optString("channel")}")
            }
            "comm.action.execute" -> {
                val payload = json.optJSONObject("payload") ?: JSONObject()
                commWatchdogManager?.handleActionExecute(payload)
                Log.d(TAG, "comm.action.execute: action=${payload.optString("action")}")
            }
            "handoff.request" -> {
                val payload = json.optJSONObject("payload") ?: JSONObject()
                onHandoffReceived?.invoke(payload)
                Log.d(TAG, "handoff.request: key=${payload.optString("key")}")
            }
            "notification.forward" -> {
                val payload = json.optJSONObject("payload") ?: JSONObject()
                onNotificationForward?.invoke(payload)
                Log.d(TAG, "notification.forward: title=${payload.optString("title").take(40)}")
            }
            "clipboard.update" -> {
                val payload = json.optJSONObject("payload") ?: JSONObject()
                onClipboardUpdate?.invoke(payload.optString("text"))
                Log.d(TAG, "clipboard.update received")
            }

            else -> Log.w(TAG, "Unsupported inbound frame type: '$frameType' — not handled")
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Outbound
    // ────────────────────────────────────────────────────────────────────────

    fun emitEvent(command: String, payload: JSONObject) {
        if (_sharedStatus.value != MacBrainStatus.Connected) {
            Log.w(TAG, "emitEvent('$command') skipped — not connected (${_sharedStatus.value})")
            return
        }
        val frame = JSONObject().apply {
            put("type", "event")
            put("command", command)
            put("payload", payload)
        }
        val sent = sendFrame(frame)
        if (sent) {
            lastEventSentAtMs.set(System.currentTimeMillis())
            Log.i(TAG, "emitEvent('$command') sent")
            if (command.contains("transcript", ignoreCase = true)) {
                LatencyTracker.mark(LatencyTracker.TRANSCRIPT_SENT_TO_DAEMON)
            }
        } else {
            Log.w(TAG, "emitEvent('$command') — send returned false")
        }
    }

    fun sendTranscript(text: String, routeId: String = UUID.randomUUID().toString()) {
        if (_sharedStatus.value != MacBrainStatus.Connected) {
            Log.w(TAG, "sendTranscript skipped — not connected")
            return
        }
        val frame = JSONObject().apply {
            put("type",       "transcript.final")
            put("messageId",  routeId)
            put("transcript", text)
            put("deviceId",   deviceName())
            put("timestamp",  System.currentTimeMillis())
        }
        val sent = sendFrame(frame)
        if (sent) {
            LatencyTracker.mark(LatencyTracker.TRANSCRIPT_SENT_TO_DAEMON)
        }
        Log.d(TAG, "sendTranscript: len=${text.length}")
    }

    fun sendTypedFrame(frame: JSONObject): Boolean = sendFrame(frame)

    private fun sendResponse(
        id: String,
        ok: Boolean,
        status: String?,
        message: String?,
        payload: JSONObject = JSONObject(),
    ) {
        val frame = JSONObject().apply {
            put("id", id)
            put("type", "response")
            put("ok", ok)
            if (status != null) put("status", status)
            if (message != null) put("message", message)
            put("payload", payload)
        }
        sendFrame(frame)
    }

    private fun sendFrame(frame: JSONObject): Boolean {
        return try {
            val json = frame.toString()
            require(json.toByteArray(Charsets.UTF_8).size <= 64 * 1024) {
                "Frame exceeds 64 KB — type=${frame.optString("type")}"
            }
            ws?.send(json) ?: false
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "sendFrame: ${e.message}")
            false
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // HTTP context (fetchContext)
    // ────────────────────────────────────────────────────────────────────────

    override suspend fun fetchContext(request: BrainContextRequest): BrainContextResponse? =
        withContext(Dispatchers.IO) {
            val cfg = settingsRepo.snapshot()
            if (!cfg.isPaired) return@withContext null
            val baseUrl = cfg.baseUrl.trimEnd('/')
            if (!isValidBaseUrl(baseUrl)) return@withContext null

            if (isCircuitOpen()) {
                Log.d(TAG, "[FETCH_SKIPPED] circuit_open intent=${request.intentHint}")
                return@withContext null
            }

            val cacheKey = contextCacheKey(request.transcript, request.intentHint)
            val cached = getCached(cacheKey)
            if (cached != null) return@withContext cached

            if (!inFlightKeys.add(cacheKey)) return@withContext null

            val requestId = UUID.randomUUID().toString()
            Log.d(TAG, "[FETCH_STARTED] intent=${request.intentHint} id=$requestId")

            try {
                var failureReason: String? = null
                val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                    try {
                        val raw = NetworkClient.post(
                            url     = cfg.chatUrl,
                            headers = authHeader(cfg.deviceToken),
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
                            Log.w(TAG, "[FETCH_TOKEN_REVOKED] clearing pairing")
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

                when {
                    result != null -> {
                        Log.d(TAG, "[FETCH_OK] memories=${result.memories.size}")
                        recordCircuitSuccess()
                        putCached(cacheKey, result)
                    }
                    failureReason != null -> {
                        Log.w(TAG, "[FETCH_FAILED] reason=$failureReason")
                        recordCircuitFailure()
                    }
                    else -> {
                        Log.w(TAG, "[FETCH_TIMEOUT]")
                        recordCircuitFailure()
                    }
                }
                result
            } finally {
                inFlightKeys.remove(cacheKey)
            }
        }

    // ────────────────────────────────────────────────────────────────────────
    // HTTP health
    // ────────────────────────────────────────────────────────────────────────

    override suspend fun health(): Boolean = withContext(Dispatchers.IO) {
        val cfg = settingsRepo.snapshot()
        if (!cfg.isPaired) return@withContext false
        if (!isValidBaseUrl(cfg.baseUrl)) return@withContext false

        val up = withTimeoutOrNull(HEALTH_TIMEOUT_MS) {
            try {
                NetworkClient.get(url = cfg.healthUrl, headers = emptyMap())
                true
            } catch (e: Exception) {
                Log.d(TAG, "[HEALTH] down: ${e.message?.take(60)}")
                false
            }
        } ?: false
        Log.d(TAG, "[HEALTH] status=${if (up) "ok" else "down"}")
        up
    }

    // ────────────────────────────────────────────────────────────────────────
    // HTTP events
    // ────────────────────────────────────────────────────────────────────────

    override suspend fun reportEvent(event: AndroidInteractionEvent): Boolean =
        reportEvents(listOf(event)).isNotEmpty()

    override suspend fun reportEvents(events: List<AndroidInteractionEvent>): List<String> =
        withContext(Dispatchers.IO) {
            val cfg = settingsRepo.snapshot()
            if (!cfg.isPaired) return@withContext emptyList()
            if (!isValidBaseUrl(cfg.baseUrl)) return@withContext emptyList()
            if (isCircuitOpen()) return@withContext emptyList()

            val url = "${cfg.baseUrl.trimEnd('/')}/v1/interactions"
            try {
                NetworkClient.post(
                    url     = url,
                    headers = authHeader(cfg.deviceToken),
                    body    = buildEventsJson(events),
                )
                Log.d(TAG, "[EVENTS_REPORTED] count=${events.size}")
                events.map { it.id }
            } catch (e: LlmException) {
                if (e.message?.startsWith("HTTP 401") == true ||
                    e.message?.startsWith("HTTP 403") == true) {
                    Log.w(TAG, "[EVENTS_TOKEN_REVOKED] clearing pairing")
                    settingsRepo.clearPairing()
                }
                emptyList()
            } catch (e: Exception) {
                Log.w(TAG, "[EVENTS_FAILED] ${e.message?.take(80)}")
                emptyList()
            }
        }

    // ────────────────────────────────────────────────────────────────────────
    // Pairing
    // ────────────────────────────────────────────────────────────────────────

    suspend fun pair(macIpAddress: String, pairingCode: String): PairResult =
        withContext(Dispatchers.IO) {
            if (macIpAddress.isBlank() || pairingCode.isBlank()) {
                return@withContext PairResult.Failure(PairFailure.BadResponse)
            }

            val baseUrl = "http://$macIpAddress:8765"
            val url     = "$baseUrl/v1/android/pair"
            val deviceId   = settingsRepo.stableDeviceId()
            val deviceName = deviceName()
            val body = buildPairRequestJson(
                deviceId     = deviceId,
                deviceName   = deviceName,
                pairingCode  = pairingCode,
                appVersion   = appVersion(),
                capabilities = DEFAULT_CAPABILITIES,
            )

            Log.d(TAG, "[PAIR_STARTED] url=$url deviceId=$deviceId")

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
                            Log.w(TAG, "[PAIR_HTTP_ERROR] ${msg.take(80)}")
                            PairResult.Failure(PairFailure.MacUnavailable)
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "[PAIR_FAILED] ${e.javaClass.simpleName}: ${e.message?.take(80)}")
                    PairResult.Failure(PairFailure.MacUnavailable)
                }
            } ?: run {
                Log.w(TAG, "[PAIR_TIMEOUT]")
                PairResult.Failure(PairFailure.MacUnavailable)
            }

            when (result) {
                is PairResult.Success -> {
                    settingsRepo.savePaired(result.sessionToken, macIpAddress)
                    Log.d(TAG, "[PAIR_SUCCEEDED] mac=${result.macDeviceName}")
                }
                is PairResult.Failure ->
                    Log.w(TAG, "[PAIR_FAILED] reason=${result.reason}")
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
        val caps = JSONArray()
        capabilities.forEach { caps.put(it) }
        put("capabilities", caps)
    }.toString()

    private fun parsePairResponse(raw: String): PairResult {
        return try {
            val json  = JSONObject(raw)
            val token = json.optString("sessionToken").ifBlank {
                return PairResult.Failure(PairFailure.BadResponse)
            }
            PairResult.Success(
                sessionToken   = token,
                macDeviceName  = json.optString("macDeviceName", "Mac Jarvis"),
                serverVersion  = json.optString("serverVersion", ""),
            )
        } catch (e: Exception) {
            Log.w(TAG, "[PAIR_PARSE_ERROR] ${e.message?.take(60)}")
            PairResult.Failure(PairFailure.BadResponse)
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Remote actions
    // ────────────────────────────────────────────────────────────────────────

    suspend fun sendRemoteAction(
        detection: com.jarvis.assistant.remote.actions.RemoteActionIntent.DetectionResult,
        sourceDeviceId: String = "android"
    ): RemoteActionOutcome {
        if (_sharedStatus.value != MacBrainStatus.Connected) {
            Log.w(TAG, "sendRemoteAction skipped — not connected")
            return RemoteActionOutcome(
                requestId     = "",
                success       = false,
                spokenSummary = "The Mac bridge is not connected.",
                errorCode     = "mac_bridge_disconnected",
            )
        }

        val requestId = UUID.randomUUID().toString()
        val frame = com.jarvis.assistant.remote.actions.RemoteActionIntent
            .buildRequestPayload(detection, requestId = requestId, sourceDeviceId = sourceDeviceId)

        val result = withTimeoutOrNull(REMOTE_ACTION_TIMEOUT_MS) {
            suspendCancellableCoroutine<RemoteActionOutcome> { cont ->
                pendingActions[requestId] = { res -> if (cont.isActive) cont.resume(res) }
                cont.invokeOnCancellation { pendingActions.remove(requestId) }
                sendFrame(frame)
                Log.d(TAG, "Sent remote.action.request action=${detection.action} requestId=$requestId")
            }
        }

        return result ?: run {
            pendingActions.remove(requestId)
            Log.w(TAG, "remote.action.request timed out after ${REMOTE_ACTION_TIMEOUT_MS}ms")
            RemoteActionOutcome(
                requestId     = requestId,
                success       = false,
                spokenSummary = "The Mac didn't respond in time.",
                errorCode     = "mac_action_timeout",
            )
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Event broadcaster
    // ────────────────────────────────────────────────────────────────────────

    fun attachEventBroadcaster(scope: CoroutineScope, ctx: Context) {
        if (broadcasterJob != null) {
            Log.d(TAG, "attachEventBroadcaster() already attached — ignoring")
            return
        }
        broadcasterScope = scope
        broadcasterJob = scope.launch {
            Log.i(TAG, "EventBus subscription started")
            EventBus.events.collect { event ->
                // Gate: only relay when connected
                if (_sharedStatus.value != MacBrainStatus.Connected) return@collect

                when (event.kind) {
                    EventKind.CALL_RINGING           -> handleCallRinging(event.payload)
                    EventKind.CALL_ANSWERED          -> handleCallAnswered(event.payload)
                    EventKind.CALL_ENDED             -> handleCallEnded(event.payload)
                    EventKind.NOTIFICATION_POSTED    -> handleNotification(event.payload, ctx)
                    EventKind.BATTERY_LOW            -> handleBatteryLow(event.payload)
                    EventKind.POWER_CONNECTED        -> handlePower("power_connected", event.payload)
                    EventKind.POWER_DISCONNECTED     -> handlePower("power_disconnected", event.payload)
                    EventKind.FOREGROUND_APP_CHANGED -> handleForegroundAppChanged(event.payload, ctx)
                    else -> Unit
                }
            }
        }
        Log.i(TAG, "attachEventBroadcaster attached")
    }

    fun detachEventBroadcaster() {
        broadcasterJob?.cancel()
        broadcasterJob  = null
        broadcasterScope = null
        sawRinging  = false
        sawAnswered = false
        callerName  = ""
        Log.i(TAG, "detachEventBroadcaster detached")
    }

    // ── Event handler helpers ─────────────────────────────────────────────────

    private val CALLER_NAME_POLL_BUDGET_MS = 1_500L
    private val CALLER_NAME_POLL_STEP_MS   = 100L

    private suspend fun handleCallRinging(payload: Map<String, String>) {
        var nameFromCache = JarvisNotificationListener.peekCallerName()
        if (nameFromCache.isNullOrBlank()) {
            var waitedMs = 0L
            while (nameFromCache.isNullOrBlank() && waitedMs < CALLER_NAME_POLL_BUDGET_MS) {
                delay(CALLER_NAME_POLL_STEP_MS)
                waitedMs += CALLER_NAME_POLL_STEP_MS
                nameFromCache = JarvisNotificationListener.peekCallerName()
            }
        }

        val nameFromPayload = payload["contact_name"]?.takeIf { it.isNotBlank() && it != "Unknown caller" }
            ?: payload["phone_number"]?.takeIf { it.isNotBlank() }

        val resolved = when {
            !nameFromCache.isNullOrBlank() -> nameFromCache
            !nameFromPayload.isNullOrBlank() -> nameFromPayload
            else -> "Unknown caller"
        }

        val fp = "call_ringing:$resolved"
        if (isDuplicate(fp, 2_000L)) return

        sawRinging  = true
        sawAnswered = false
        callerName  = resolved

        emitBroadcastEvent("incoming_call", JSONObject().apply {
            put("contactName", resolved)
            put("app", "Phone")
        })
    }

    private fun handleCallAnswered(payload: Map<String, String>) {
        if (!sawRinging) return
        val fp = "call_answered:$callerName"
        if (isDuplicate(fp, 2_000L)) return
        sawAnswered = true
        emitBroadcastEvent("call_answered", JSONObject().apply {
            put("contactName", callerName)
            put("app", "Phone")
        })
    }

    private fun handleCallEnded(payload: Map<String, String>) {
        if (!sawRinging) return
        val command = if (!sawAnswered) "missed_call" else "call_ended"
        val fp = "$command:$callerName"
        if (isDuplicate(fp, 2_000L)) return
        sawRinging  = false
        sawAnswered = false
        emitBroadcastEvent(command, JSONObject().apply {
            put("contactName", callerName)
            put("app", "Phone")
        })
        callerName = ""
    }

    private val SMS_PACKAGES = setOf(
        "com.google.android.apps.messaging",
        "com.android.mms",
        "com.android.messaging",
    )
    private val WHATSAPP_PACKAGES = setOf("com.whatsapp", "com.whatsapp.w4b")

    private fun handleNotification(payload: Map<String, String>, ctx: Context) {
        if (payload["is_call"] == "true") return
        if (payload["is_ha_alert"] == "true") return

        val pkg   = payload["app_package"] ?: return
        val title = payload["title"]  ?: ""
        val text  = payload["text"]   ?: ""
        val isMsg = payload["is_messaging"] == "true"

        val dedupeKey = payload["sbn_key"] ?: "$pkg:${title.take(30)}:${text.take(30)}"
        if (isDuplicate("notif:$dedupeKey", 5_000L)) return

        val command = when {
            pkg in WHATSAPP_PACKAGES -> "whatsapp_received"
            pkg in SMS_PACKAGES      -> "sms_received"
            isMsg                    -> "notification_received"
            else                     -> "notification_received"
        }

        if (command == "whatsapp_received") {
            val senderName  = payload["wa_sender_name"]?.takeIf { it.isNotBlank() }
            val groupName   = payload["wa_group_name"]?.takeIf { it.isNotBlank() }
            val body = JSONObject().apply {
                put("event_id", UUID.randomUUID().toString())
                put("type", "whatsapp_received")
                if (senderName != null) put("sender_name", senderName)
                if (groupName  != null) put("group_name",  groupName)
                put("timestamp", isoNow())
            }
            emitBroadcastEvent(command, body)
            return
        }

        val sender = title.ifBlank { MessagingAppCapabilityRegistry.displayName(pkg) }
        emitBroadcastEvent(command, JSONObject().apply {
            put("contactName", sender)
            put("app", MessagingAppCapabilityRegistry.displayName(pkg))
            put("packageName", pkg)
        })
    }

    private fun handleBatteryLow(payload: Map<String, String>) {
        val pct = payload["battery_pct"] ?: "?"
        val fp  = "battery_low:${pct.take(3)}"
        if (isDuplicate(fp, 5 * 60_000L)) return
        emitBroadcastEvent("battery_status", JSONObject().apply {
            put("level", pct.toIntOrNull() ?: -1)
            put("charging", false)
            put("alert", "low")
        })
    }

    private fun handlePower(command: String, payload: Map<String, String>) {
        val fp = "power:$command"
        if (isDuplicate(fp, 5_000L)) return
        emitBroadcastEvent(command, JSONObject().apply {
            put("batteryLevel", payload["battery_pct"]?.toIntOrNull() ?: -1)
        })
    }

    private fun handleForegroundAppChanged(payload: Map<String, String>, ctx: Context) {
        val pkg = payload["app_package"] ?: return
        if (pkg == ctx.packageName) return
        if (isDuplicate("fg:$pkg", 3_000L)) return

        val body = JSONObject().apply {
            put("foregroundApp", appContextJson(pkg, ctx))
            payload["previous_app_package"]?.let { put("previousApp", appContextJson(it, ctx)) }
        }
        emitBroadcastEvent("device_context_changed", body)
    }

    private fun appContextJson(pkg: String, ctx: Context): JSONObject {
        val label = runCatching {
            ctx.packageManager.getApplicationLabel(
                ctx.packageManager.getApplicationInfo(pkg, 0)
            ).toString()
        }.getOrElse { pkg }
        return JSONObject().apply {
            put("package", pkg)
            put("label", label)
        }
    }

    private fun emitBroadcastEvent(command: String, payload: JSONObject) {
        val wrapped = JSONObject().apply {
            put("id", UUID.randomUUID().toString())
            put("source", "android")
            put("event", command)
            put("timestamp", isoNow())
            put("data", payload)
        }
        emitEvent(command, wrapped)
    }

    private fun isDuplicate(fingerprint: String, windowMs: Long = 3_000L): Boolean {
        val now = System.currentTimeMillis()
        return synchronized(dedupLock) {
            val last = dedupCache[fingerprint]
            if (last != null && (now - last) < windowMs) {
                true
            } else {
                dedupCache[fingerprint] = now
                false
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Network observer
    // ────────────────────────────────────────────────────────────────────────

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            Log.d(TAG, "Network available")
            if (!wasNetworkConnected) {
                mainHandler.postDelayed({
                    if (_sharedStatus.value != MacBrainStatus.Connected) {
                        Log.i(TAG, "Connectivity restored — starting connection")
                        start()
                    }
                }, NETWORK_RECONNECT_DELAY_MS)
            }
            wasNetworkConnected = true
        }

        override fun onLost(network: Network) {
            Log.d(TAG, "Network lost")
            wasNetworkConnected = false
        }

        override fun onUnavailable() {
            Log.d(TAG, "Network unavailable")
            wasNetworkConnected = false
        }
    }

    @Suppress("DEPRECATION")
    private val legacyNetworkReceiver: BroadcastReceiver? =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            object : BroadcastReceiver() {
                override fun onReceive(ctx: Context, intent: Intent) {
                    val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
                    val networkInfo = cm.activeNetworkInfo
                    val isConnected = networkInfo?.isConnected == true
                    if (isConnected && !wasNetworkConnected) {
                        mainHandler.postDelayed({
                            if (_sharedStatus.value != MacBrainStatus.Connected) start()
                        }, NETWORK_RECONNECT_DELAY_MS)
                    }
                    wasNetworkConnected = isConnected
                }
            }
        } else null

    private fun registerNetworkCallback() {
        if (!networkRegistered.compareAndSet(false, true)) return
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val req = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            cm.registerNetworkCallback(req, networkCallback)
        } else {
            @Suppress("DEPRECATION")
            legacyNetworkReceiver?.let {
                context.registerReceiver(it, IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION))
            }
        }
    }

    private fun unregisterNetworkCallback() {
        if (!networkRegistered.compareAndSet(true, false)) return
        mainHandler.removeCallbacksAndMessages(null)
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try { cm?.unregisterNetworkCallback(networkCallback) } catch (_: Exception) {}
        } else {
            legacyNetworkReceiver?.let {
                try { context.unregisterReceiver(it) } catch (_: Exception) {}
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // HTTP circuit breaker helpers
    // ────────────────────────────────────────────────────────────────────────

    @Synchronized private fun isCircuitOpen(): Boolean {
        if (cbOpenUntilMs > 0 && System.currentTimeMillis() < cbOpenUntilMs) return true
        cbOpenUntilMs = 0
        return false
    }

    @Synchronized private fun recordCircuitFailure() {
        cbFailures++
        if (cbFailures >= 3) {
            cbOpenUntilMs = System.currentTimeMillis() + 30_000L
            cbFailures = 0
            Log.w(TAG, "Circuit breaker OPEN for 30s")
        }
    }

    @Synchronized private fun recordCircuitSuccess() {
        cbFailures = 0
        cbOpenUntilMs = 0
    }

    // ── Context cache helpers ─────────────────────────────────────────────────

    @Synchronized private fun getCached(key: String): BrainContextResponse? {
        val entry = contextCache[key] ?: return null
        if (System.currentTimeMillis() - entry.first > contextCacheTtlMs) {
            contextCache.remove(key)
            return null
        }
        return entry.second
    }

    @Synchronized private fun putCached(key: String, value: BrainContextResponse) {
        contextCache[key] = Pair(System.currentTimeMillis(), value)
    }

    private fun contextCacheKey(transcript: String, intentHint: String) =
        "${transcript.take(100)}|$intentHint"

    // ────────────────────────────────────────────────────────────────────────
    // HTTP serialisation helpers
    // ────────────────────────────────────────────────────────────────────────

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
            put("androidAppVersion", appVersion())
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
                put("androidAppVersion", appVersion())
                put("batchId",           UUID.randomUUID().toString())
                put("timestamp",         System.currentTimeMillis())
            })
        }.toString()
    }

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
        Log.w(TAG, "[PARSE_ERROR] ${e.message?.take(60)}")
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

    // ────────────────────────────────────────────────────────────────────────
    // Device info
    // ────────────────────────────────────────────────────────────────────────

    private fun batteryLevel(): Int {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager ?: return -1
        return bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
    }

    private fun deviceName(): String =
        Settings.Global.getString(context.contentResolver, "device_name")
            ?.takeIf { it.isNotBlank() }
            ?: android.os.Build.MODEL

    private fun resolveAppLabel(pkg: String): String? = runCatching {
        context.packageManager.getApplicationLabel(
            context.packageManager.getApplicationInfo(pkg, 0)
        ).toString()
    }.getOrNull()

    private fun appVersion(): String = try {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""
    } catch (_: Exception) { "" }

    private fun authHeader(token: String?): Map<String, String> =
        if (token.isNullOrBlank()) emptyMap()
        else mapOf("Authorization" to "Bearer $token")

    private fun isValidBaseUrl(url: String): Boolean =
        url.startsWith("http://", ignoreCase = true) ||
        url.startsWith("https://", ignoreCase = true)

    private fun isoNow(): String =
        DateTimeFormatter.ISO_INSTANT.format(Instant.now().atOffset(ZoneOffset.UTC))
}

// ── Status enum ──────────────────────────────────────────────────────────────

enum class MacBrainStatus {
    NotPaired,      // no session token — scan QR to pair
    Connecting,     // WS upgrade in progress
    Connected,      // live
    Reconnecting,   // transient failure, backing off
    Unauthorized,   // token rejected or revoked — re-pair required
    Disconnected,   // explicitly stopped
}

// ── Pairing result types ──────────────────────────────────────────────────────

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
    InvalidCode,
    AlreadyPaired,
    MacUnavailable,
    BadResponse,
}

// ── Remote action outcome ─────────────────────────────────────────────────────

data class RemoteActionOutcome(
    val requestId: String,
    val success: Boolean,
    val spokenSummary: String,
    val errorCode: String? = null,
    val errorMessage: String? = null,
)

// ── Internal connect outcome ──────────────────────────────────────────────────

private enum class ConnectOutcome {
    Disconnected,
    Unauthorized,
    TokenRevoked,
}
