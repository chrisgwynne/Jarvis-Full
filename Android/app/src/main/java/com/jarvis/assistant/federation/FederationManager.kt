package com.jarvis.assistant.federation

import android.content.Context
import android.provider.Settings
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "FederationManager"

enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, DEGRADED }

/**
 * FederationManager — owns the WebSocket connection between Android and the
 * Mac federation peer.
 *
 * Wire envelope: every frame is a JSON object
 * ```json
 * { "envelope": "federation", "payload": <FederationMessage.toJson()> }
 * ```
 *
 * Lifecycle:
 *  - [start] is idempotent: safe to call multiple times.
 *  - [stop]  is idempotent: cancels all jobs and closes the socket.
 *  - Exponential reconnect with jitter, bounded by [FederationConfig].
 *  - Outbound messages are buffered in [outboundQueue] while offline.
 *  - Proactive device/navigation events are throttled via [rateLimiter].
 */
class FederationManager(
    private val context: Context,
    private val config: FederationConfig,
    private val scope: CoroutineScope,
) {
    // ── Public state ──────────────────────────────────────────────────────────

    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    val outboundQueue = OutboundQueue(config.queueMaxSize)
    val rateLimiter   = EventRateLimiter()

    // ── Private state ─────────────────────────────────────────────────────────

    private val active = AtomicBoolean(false)
    private val stateMutex = Mutex()

    private var webSocket: WebSocket? = null
    private val wsLock = Any() // guards webSocket reference for okhttp callbacks (non-coroutine context)

    private var connectJob: Job? = null
    private var heartbeatJob: Job? = null
    private var reconnectAttempt = 0

    private val inboundHandlers = CopyOnWriteArrayList<(FederationMessage) -> Unit>()

    private val httpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0,  TimeUnit.SECONDS) // keep-alive — never times out on reads
            .writeTimeout(10, TimeUnit.SECONDS)
            .pingInterval(config.heartbeatIntervalMs, TimeUnit.MILLISECONDS)
            .build()
    }

    // ── Public API ────────────────────────────────────────────────────────────

    fun isConnected(): Boolean = _connectionState.value == ConnectionState.CONNECTED

    /**
     * Register a handler for inbound messages.
     * Handlers are called on the OkHttp dispatcher thread — keep them fast and
     * launch coroutines for any heavy work.
     */
    fun onInboundMessage(handler: (FederationMessage) -> Unit) {
        inboundHandlers.add(handler)
    }

    /**
     * Enqueue [message] and attempt an immediate flush if currently connected.
     * Returns true if the message was sent synchronously, false if buffered.
     */
    suspend fun send(message: FederationMessage): Boolean {
        if (!shouldRateLimit(message)) {
            outboundQueue.enqueue(message)
        } else {
            Log.d(TAG, "send: rate-limited ${message::class.simpleName} — dropped")
            return false
        }

        return if (isConnected()) {
            val flushed = outboundQueue.flush { msg -> sendRaw(msg) }
            flushed > 0
        } else {
            false
        }
    }

    /** Fire-and-forget variant of [send]. */
    fun sendAsync(message: FederationMessage) {
        scope.launch { send(message) }
    }

    /** Convenience: send a [ContextSnapshotEvent]. */
    fun sendContextSnapshot(snapshot: ContextSnapshot) {
        val deviceId = resolveDeviceId()
        sendAsync(FederationMessage.ContextSnapshotEvent(
            snapshot = snapshot,
            sourceDeviceId = deviceId,
        ))
    }

    /** Convenience: send a [WorkflowRequest] representing a [MacTaskRequest]. */
    fun requestMacTask(request: MacTaskRequest) {
        val deviceId = resolveDeviceId()
        sendAsync(FederationMessage.WorkflowRequest(
            workflowId = request.taskId,
            title = request.title,
            description = request.description,
            payload = request.payload + mapOf(
                "taskType"         to request.taskType.name,
                "urgency"          to request.urgency.name,
                "returnPreference" to request.returnPreference.name,
                "createdAtMs"      to request.createdAtMs.toString(),
            ),
            sourceDeviceId = deviceId,
        ))
    }

    /**
     * Start the federation connection. Idempotent — safe to call from
     * [onCreate] or similar; does nothing if already running.
     */
    fun start() {
        if (!config.enabled) {
            Log.d(TAG, "start: federation disabled in config — skipping")
            return
        }
        if (active.getAndSet(true)) {
            Log.d(TAG, "start: already active")
            return
        }
        Log.i(TAG, "start: federation manager starting (deviceId=${resolveDeviceId()})")
        reconnectAttempt = 0
        connectJob = scope.launch { connectLoop() }
    }

    /**
     * Stop the federation connection and cancel all background jobs.
     * Idempotent.
     */
    fun stop() {
        if (!active.getAndSet(false)) {
            Log.d(TAG, "stop: already stopped")
            return
        }
        Log.i(TAG, "stop: shutting down federation manager")
        heartbeatJob?.cancel()
        heartbeatJob = null
        connectJob?.cancel()
        connectJob = null
        synchronized(wsLock) {
            webSocket?.close(1000, "FederationManager stopped")
            webSocket = null
        }
        _connectionState.value = ConnectionState.DISCONNECTED
    }

    // ── Connection lifecycle ──────────────────────────────────────────────────

    private suspend fun connectLoop() {
        while (active.get() && scope.isActive) {
            val url = buildWsUrl()
            if (url == null) {
                Log.w(TAG, "connectLoop: no valid host configured — waiting ${config.reconnectBaseDelayMs}ms")
                delay(config.reconnectBaseDelayMs)
                continue
            }

            stateMutex.withLock {
                _connectionState.value = ConnectionState.CONNECTING
            }
            Log.i(TAG, "connectLoop: connecting to $url (attempt $reconnectAttempt)")

            val connected = openWebSocket(url)
            if (connected) {
                reconnectAttempt = 0
                startHeartbeat()
                flushQueue()
                // Wait here — the coroutine blocks until the WS closes or we stop.
                // OkHttp manages the socket on its own thread; we wait for state change.
                awaitDisconnect()
                heartbeatJob?.cancel()
                heartbeatJob = null
            }

            if (!active.get()) break

            val backoff = backoffDelay(reconnectAttempt)
            reconnectAttempt++
            Log.i(TAG, "connectLoop: reconnecting in ${backoff}ms (attempt $reconnectAttempt)")
            stateMutex.withLock {
                _connectionState.value = ConnectionState.DISCONNECTED
            }
            delay(backoff)
        }
    }

    private fun openWebSocket(url: String): Boolean {
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer ${config.authToken}")
            .header("X-Device-Id", resolveDeviceId())
            .header("X-Device-Name", config.deviceName)
            .build()

        val listener = FederationWebSocketListener()
        val ws = httpClient.newWebSocket(request, listener)
        synchronized(wsLock) { webSocket = ws }
        return true // OkHttp connects asynchronously; state is driven by listener callbacks
    }

    /**
     * Suspend until the connection transitions away from CONNECTED (or we stop).
     * Polls state every 500 ms; low overhead because disconnects are infrequent.
     */
    private suspend fun awaitDisconnect() {
        while (active.get() && _connectionState.value == ConnectionState.CONNECTED && scope.isActive) {
            delay(500)
        }
        // Also check CONNECTING — if we never reached CONNECTED we should fall through
        // immediately so the reconnect loop can fire.
    }

    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (active.get() && isActive) {
                delay(config.heartbeatIntervalMs)
                if (isConnected()) {
                    sendPing()
                }
            }
        }
    }

    private fun sendPing() {
        val ping = JSONObject().apply {
            put("envelope", "ping")
            put("deviceId", resolveDeviceId())
            put("timestampMs", System.currentTimeMillis())
        }
        val sent = synchronized(wsLock) {
            webSocket?.send(ping.toString())
        }
        if (sent != true) {
            Log.w(TAG, "sendPing: failed — socket unavailable")
        }
    }

    private suspend fun flushQueue() {
        val count = outboundQueue.flush { msg -> sendRaw(msg) }
        if (count > 0) Log.i(TAG, "flushQueue: flushed $count queued messages")
    }

    // ── Raw send ──────────────────────────────────────────────────────────────

    private fun sendRaw(message: FederationMessage): Boolean {
        val envelope = JSONObject().apply {
            put("envelope", "federation")
            put("payload", message.toJson())
        }
        val sent = synchronized(wsLock) {
            webSocket?.send(envelope.toString())
        }
        return sent == true
    }

    // ── Rate limiting ─────────────────────────────────────────────────────────

    /** Returns true if [message] should be suppressed by the rate limiter. */
    private fun shouldRateLimit(message: FederationMessage): Boolean {
        return when (message) {
            is FederationMessage.DeviceStateEvent -> {
                !rateLimiter.isAllowed("DeviceStateEvent", DefaultRateLimits.BATTERY_EVENT)
            }
            is FederationMessage.NavigationStateEvent -> {
                !rateLimiter.isAllowed("NavigationStateEvent", DefaultRateLimits.LOCATION_EVENT)
            }
            is FederationMessage.VoiceTranscriptEvent -> {
                !rateLimiter.isAllowed("VoiceTranscriptEvent", DefaultRateLimits.VOICE_TRANSCRIPT)
            }
            is FederationMessage.MacNotificationEvent -> {
                !rateLimiter.isAllowed("MacNotificationEvent", DefaultRateLimits.NOTIFICATION_EVENT)
            }
            // User-initiated messages are never rate-limited
            is FederationMessage.ContinueOnMacRequest,
            is FederationMessage.WorkflowRequest,
            is FederationMessage.ReminderRequest,
            is FederationMessage.MemoryCaptureRequest,
            is FederationMessage.PhotoCapturedEvent,
            is FederationMessage.HomeAssistantActionEvent,
            is FederationMessage.ContextSnapshotEvent,
            is FederationMessage.MacResponseEvent,
            is FederationMessage.MacTaskCompletedEvent -> false
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun buildWsUrl(): String? {
        val host = when {
            config.useTailscale && config.tailscaleHost.isNotBlank() -> config.tailscaleHost
            config.lanHost.isNotBlank() -> config.lanHost
            else -> return null
        }
        return "ws://$host:${config.lanPort}/federation"
    }

    private fun backoffDelay(attempt: Int): Long {
        val raw = config.reconnectBaseDelayMs * (1L shl minOf(attempt, 5))
        return minOf(raw, config.reconnectMaxDelayMs)
    }

    private fun resolveDeviceId(): String {
        return config.deviceId.takeIf { it.isNotBlank() }
            ?: try {
                Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: "unknown"
            } catch (e: Exception) {
                Log.w(TAG, "resolveDeviceId: failed to read ANDROID_ID", e)
                "unknown"
            }
    }

    // ── WebSocket listener ────────────────────────────────────────────────────

    private inner class FederationWebSocketListener : WebSocketListener() {

        override fun onOpen(webSocket: WebSocket, response: Response) {
            Log.i(TAG, "WS onOpen: connected")
            scope.launch {
                stateMutex.withLock {
                    _connectionState.value = ConnectionState.CONNECTED
                }
                flushQueue()
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            try {
                val envelope = JSONObject(text)
                when (val envelopeType = envelope.optString("envelope")) {
                    "federation" -> {
                        val payload = envelope.optJSONObject("payload") ?: return
                        val message = FederationMessage.fromJson(payload) ?: return
                        Log.d(TAG, "WS onMessage: received ${message::class.simpleName}")
                        inboundHandlers.forEach { handler ->
                            try { handler(message) } catch (e: Exception) {
                                Log.e(TAG, "WS onMessage: handler threw", e)
                            }
                        }
                    }
                    "pong" -> {
                        Log.d(TAG, "WS onMessage: pong received")
                    }
                    else -> {
                        Log.d(TAG, "WS onMessage: unknown envelope type '$envelopeType' — ignoring")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "WS onMessage: parse error", e)
            }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            // Binary frames not used — ignore
            Log.d(TAG, "WS onMessage: received binary frame (${bytes.size} bytes) — ignored")
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            Log.i(TAG, "WS onClosing: code=$code reason=$reason")
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            Log.i(TAG, "WS onClosed: code=$code reason=$reason")
            synchronized(wsLock) {
                if (this@FederationManager.webSocket === webSocket) {
                    this@FederationManager.webSocket = null
                }
            }
            scope.launch {
                stateMutex.withLock {
                    if (_connectionState.value != ConnectionState.DISCONNECTED) {
                        _connectionState.value = ConnectionState.DISCONNECTED
                    }
                }
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            Log.w(TAG, "WS onFailure: ${t.message} (response=${response?.code})")
            synchronized(wsLock) {
                if (this@FederationManager.webSocket === webSocket) {
                    this@FederationManager.webSocket = null
                }
            }
            scope.launch {
                stateMutex.withLock {
                    _connectionState.value = ConnectionState.DISCONNECTED
                }
            }
        }
    }
}
