package com.jarvis.assistant.remote.gateway

import android.content.Context
import android.os.BatteryManager
import android.provider.Settings
import android.util.Log
import com.jarvis.assistant.remote.macbridge.BridgeResult
import com.jarvis.assistant.remote.macbridge.MacBridgeCapability
import com.jarvis.assistant.remote.macbridge.MacBridgeCommandExecutor
import com.jarvis.assistant.remote.macbridge.MacBridgeConfig
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
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume

/**
 * WebSocket command channel for the unified Brain Gateway.
 *
 * ROLE MODEL
 * ----------
 * Android Jarvis is always the WebSocket CLIENT.  Mac Jarvis hosts the server.
 * Commands (speak, capture camera, run tool) flow Mac→Android as JSON frames.
 * Android sends heartbeats, capability reports, and command replies Mac→Android.
 * This client NEVER issues commands to itself — it only receives them.
 *
 * URL: `wss://<gateway>/v1/android/ws` (derived from [BrainGatewayConfig.wsUrl])
 * Auth: `Authorization: Bearer <sessionToken>` on the HTTP upgrade request.
 *
 * Unlike the legacy MacBridgeClient, auth is NOT injected into JSON frames —
 * it lives only in the upgrade header.  The gateway validates the token once
 * at connect time; subsequent frames are considered trusted for that session.
 *
 * Status lifecycle:
 *   NotPaired → (pair via QR) → Connecting → Connected
 *   Connected → (network drop) → Reconnecting → Connecting → Connected
 *   Connected → (server 401) → Unauthorized  (token revoked — re-pair required)
 *   * → (stop called) → Disconnected
 */
class BrainGatewayWebSocketClient(
    private val context: Context,
    private val settingsRepo: BrainGatewaySettingsRepository,
    private val executor: MacBridgeCommandExecutor,
) {
    companion object {
        private const val TAG                = "BrainGatewayWS"
        private const val HEARTBEAT_MS       = 30_000L
        private const val MAX_BACKOFF_MS     = 30_000L

        private val _sharedStatus = MutableStateFlow(GatewayWsStatus.Disconnected)
        val sharedStatus: StateFlow<GatewayWsStatus> = _sharedStatus.asStateFlow()

        @Volatile var sharedMacAssistantActive: Boolean = true
            private set
        val sharedLastActivityAtMs: AtomicLong = AtomicLong(0L)

        @Volatile var lastSharedInboundCommand: String = ""
            private set
        @Volatile var lastSharedInboundStatus: String = ""
            private set
    }

    val status: StateFlow<GatewayWsStatus> get() = _sharedStatus

    // ── Reply / orchestrate callbacks (set by JarvisRuntime) ─────────────────
    /** Fired with the text of a reply.final or chat.reply.final from Mac brain. */
    var onReplyFinal: ((String) -> Unit)? = null
    /** Fired with partial streaming text (reply.partial / chat.reply.partial). */
    var onReplyPartial: ((String) -> Unit)? = null
    /** Mac requests Android to speak this text via Android TTS. */
    var onOrchestrateSpeak: ((String) -> Unit)? = null
    /** Mac requests Android to stay silent (suppress local TTS). */
    var onOrchestrateSilent: ((String) -> Unit)? = null
    /** Proactive push: title + body from Mac. */
    var onProactiveNotify: ((String, String) -> Unit)? = null

    var onProactiveCommPrompt: ((org.json.JSONObject) -> Unit)? = null
    var onHandoffReceived: ((org.json.JSONObject) -> Unit)? = null
    var onNotificationForward: ((org.json.JSONObject) -> Unit)? = null
    var onClipboardUpdate: ((String) -> Unit)? = null
    var commWatchdogManager: com.jarvis.assistant.comm.CommWatchdogManager? = null

    var deviceId: String? = null

    // ── Diagnostics ───────────────────────────────────────────────────────────
    val reconnectCount: AtomicInteger = AtomicInteger(0)
    val lastEventSentAtMs: AtomicLong = AtomicLong(0L)
    @Volatile var lastInboundCommand: String = ""
        private set
    val lastInboundAtMs: AtomicLong = AtomicLong(0L)
    @Volatile var lastInboundStatus: String = ""
        private set
    @Volatile var macAssistantActive: Boolean = true
        private set

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

    private fun newScope() = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    fun start() {
        if (running.getAndSet(true)) return
        if (!scope.coroutineContext[Job]!!.isActive) scope = newScope()
        _sharedStatus.value = GatewayWsStatus.Connecting
        scope.launch { connectLoop() }
    }

    fun stop() {
        running.set(false)
        heartbeatJob?.cancel()
        heartbeatJob = null
        ws?.close(1000, "Service stopping")
        ws = null
        serverInitiatedClose = false
        _sharedStatus.value = GatewayWsStatus.Disconnected
        scope.cancel()
        reconnectCount.set(0)
    }

    fun emitEvent(command: String, payload: JSONObject) {
        if (_sharedStatus.value != GatewayWsStatus.Connected) {
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
            // Mark latency for transcript frames sent to the daemon
            if (command.contains("transcript", ignoreCase = true)) {
                LatencyTracker.mark(LatencyTracker.TRANSCRIPT_SENT_TO_DAEMON)
            }
        } else {
            Log.w(TAG, "emitEvent('$command') — send returned false")
        }
    }

    // ── Connection loop ───────────────────────────────────────────────────────

    private suspend fun connectLoop() {
        var backoffMs = 1_000L
        while (running.get()) {
            val cfg = settingsRepo.snapshot()
            if (!cfg.isPaired) {
                _sharedStatus.value = GatewayWsStatus.NotPaired
                Log.d(TAG, "Not paired — stopping connect loop")
                running.set(false)
                return
            }
            _sharedStatus.value = GatewayWsStatus.Connecting
            val outcome = connect(cfg)

            if (!running.get()) break

            when (outcome) {
                ConnectOutcome.Unauthorized -> {
                    Log.w(TAG, "Session token rejected — clearing pairing, re-pair required")
                    settingsRepo.clearPairing()
                    _sharedStatus.value = GatewayWsStatus.Unauthorized
                    running.set(false)
                    return
                }
                ConnectOutcome.TokenRevoked -> {
                    Log.w(TAG, "Token revoked by gateway — clearing pairing")
                    settingsRepo.clearPairing()
                    _sharedStatus.value = GatewayWsStatus.Unauthorized
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
                    _sharedStatus.value = GatewayWsStatus.Reconnecting
                    reconnectCount.incrementAndGet()
                    Log.d(TAG, "Reconnecting in ${waitMs}ms (#${reconnectCount.get()})")
                    delay(waitMs)
                    backoffMs = (backoffMs * 2).coerceAtMost(MAX_BACKOFF_MS)
                }
            }
        }
    }

    private suspend fun connect(cfg: BrainGatewayConfig): ConnectOutcome =
        suspendCancellableCoroutine { cont ->
            val token = cfg.sessionToken ?: ""
            Log.d(TAG, "Connecting to ${cfg.wsUrl}")

            val req = Request.Builder()
                .url(cfg.wsUrl)
                .addHeader("Authorization", "Bearer $token")
                .build()

            ws = httpClient.newWebSocket(req, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    ws = webSocket
                    Log.d(TAG, "Connected to Mac Brain Gateway")
                    reconnectCount.set(0)
                    serverInitiatedClose = false
                    _sharedStatus.value = GatewayWsStatus.Connected
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
                        // Gateway-issued auth close codes
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
                    if (running.get()) _sharedStatus.value = GatewayWsStatus.Reconnecting
                    if (cont.isActive) cont.resume(outcome)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    Log.d(TAG, "WS closed: $code $reason")
                    if (running.get()) _sharedStatus.value = GatewayWsStatus.Reconnecting
                    if (cont.isActive) cont.resume(ConnectOutcome.Disconnected)
                }
            })

            cont.invokeOnCancellation { ws?.close(1000, "Service stopping") }
        }

    // ── Heartbeat ─────────────────────────────────────────────────────────────

    private suspend fun heartbeatLoop() {
        while (running.get() && _sharedStatus.value == GatewayWsStatus.Connected) {
            delay(HEARTBEAT_MS)
            if (_sharedStatus.value != GatewayWsStatus.Connected) break
            sendHeartbeat()
        }
    }

    // ── Outbound frames ───────────────────────────────────────────────────────

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
                    com.jarvis.assistant.notifications.JarvisNotificationListener.isGranted(context))
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
            put("capabilities", org.json.JSONArray(BrainGatewayPairingClient.DEFAULT_CAPABILITIES))
        }
        sendFrame(frame)
    }

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

    // ── Inbound dispatch ──────────────────────────────────────────────────────

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
                com.jarvis.assistant.JarvisApp.roleArbitrator.onMacStatusReceived(active)
            }

            "auth_revoked" -> {
                Log.w(TAG, "Gateway sent auth_revoked — clearing pairing")
                settingsRepo.clearPairing()
                _sharedStatus.value = GatewayWsStatus.Unauthorized
                running.set(false)
                ws?.close(1000, "auth_revoked")
            }

            // Mac brain reply — full response, surface to Android TTS / UI.
            "reply.final", "chat.reply.final" -> {
                LatencyTracker.mark(LatencyTracker.DAEMON_REPLY_RECEIVED)
                val replyText = json.optString("text").ifBlank { return }
                Log.d(TAG, "reply.final: ${replyText.take(80)}")
                onReplyFinal?.invoke(replyText)
            }

            // Streaming partial — surface to UI for typing indicator.
            "reply.partial", "chat.reply.partial" -> {
                LatencyTracker.mark(LatencyTracker.DAEMON_REPLY_RECEIVED)
                val partial = json.optString("text").ifBlank { return }
                onReplyPartial?.invoke(partial)
            }

            // Mac instructs Android to speak a specific text via Android TTS.
            "orchestrate.speak" -> {
                LatencyTracker.mark(LatencyTracker.DAEMON_REPLY_RECEIVED)
                val speakText = json.optString("text").ifBlank { return }
                Log.d(TAG, "orchestrate.speak: ${speakText.take(80)}")
                onOrchestrateSpeak?.invoke(speakText)
            }

            // Mac instructs Android to suppress its local TTS response.
            "orchestrate.silent" -> {
                val reason = json.optString("reason", "mac_responding")
                Log.d(TAG, "orchestrate.silent: reason=$reason")
                onOrchestrateSilent?.invoke(reason)
            }

            // Mac pushes a proactive notification to Android.
            "proactive.notify" -> {
                val title = json.optString("title", "Jarvis")
                val body  = json.optString("body").ifBlank { return }
                Log.d(TAG, "proactive.notify: $title — ${body.take(60)}")
                onProactiveNotify?.invoke(title, body)
            }

            // TTS speaker lease — Android may start speaking.
            "lease.grant" -> Log.d(TAG, "lease.grant received")

            // TTS speaker lease denied — Mac is speaking.
            "lease.deny", "lease.denied" -> Log.d(TAG, "lease.deny received")

            // Server acknowledged our heartbeat.
            "heartbeat.ack", "pong" -> Log.v(TAG, "heartbeat ack")

            // Server is requesting our capability list — resend it.
            "capability.request" -> {
                Log.d(TAG, "capability.request — resending capabilities")
                sendCapabilitiesReport()
            }

            // Session established / hello acknowledged.
            "session.start", "hello.ack" -> {
                Log.d(TAG, "Session established: type=$frameType")
            }

            // Server-side error frame.
            "error" -> {
                val msg = json.optString("message", "unknown error")
                Log.w(TAG, "Gateway error frame: $msg")
            }

            // Mac requests Android to execute a command.
            "request" -> {
                val requestId = json.optString("id")
                val command   = json.optString("command")
                val payload   = json.optJSONObject("payload") ?: JSONObject()
                if (requestId.isBlank() || command.isBlank()) return

                lastInboundCommand = command
                lastSharedInboundCommand = command
                lastInboundAtMs.set(System.currentTimeMillis())

                val execCfg = MacBridgeConfig(enabledCapabilities = MacBridgeCapability.ALL)
                scope.launch {
                    try {
                        val result = executor.execute(command, payload, execCfg)
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

            // Remote action result from Mac — route to RemoteActionSender
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
                    com.jarvis.assistant.remote.actions.RemoteActionSender.onResult(
                        requestId,
                        com.jarvis.assistant.remote.actions.RemoteActionResult(
                            requestId = requestId,
                            success = success,
                            spokenSummary = spokenSummary,
                            errorCode = errorCode,
                            errorMessage = errorMessage
                        )
                    )
                }
                // Surface the spoken summary to JarvisRuntime for TTS
                if (spokenSummary.isNotBlank()) {
                    onReplyFinal?.invoke(spokenSummary)
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

    // ── Outbound transcript ───────────────────────────────────────────────────

    /**
     * Public wrapper for sendFrame — allows RemoteActionSender and other
     * feature modules to send typed frames without exposing the private method.
     */
    fun sendTypedFrame(frame: JSONObject): Boolean = sendFrame(frame)

    /**
     * Sends a transcript.final frame to Mac for processing by the brain pipeline.
     * Mac will respond with a reply.final frame which fires [onReplyFinal].
     */
    fun sendTranscript(text: String, routeId: String = java.util.UUID.randomUUID().toString()) {
        if (_sharedStatus.value != GatewayWsStatus.Connected) {
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
        Log.d(TAG, "sendTranscript: ${text.take(80)}")
    }

    // ── Send ──────────────────────────────────────────────────────────────────

    /**
     * Single outbound path. Auth is on the upgrade header — frames carry no
     * auth field.  Enforces 64 KB wire ceiling.
     */
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

    // ── Device info ───────────────────────────────────────────────────────────

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
}

/** Internal result of a single WebSocket connection attempt. */
private enum class ConnectOutcome {
    Disconnected,  // normal close or network failure — retry
    Unauthorized,  // HTTP 401/403 on upgrade — token invalid
    TokenRevoked,  // gateway close code 4401/4403 — token revoked mid-session
}

enum class GatewayWsStatus {
    NotPaired,      // no session token — scan QR to pair
    Connecting,     // WS upgrade in progress
    Connected,      // live
    Reconnecting,   // transient failure, backing off
    Unauthorized,   // token rejected or revoked — re-pair required
    Disconnected,   // explicitly stopped
}
