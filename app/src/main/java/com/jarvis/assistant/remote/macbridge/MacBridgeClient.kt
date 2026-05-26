package com.jarvis.assistant.remote.macbridge

import android.content.Context
import android.os.BatteryManager
import android.provider.Settings
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume

enum class MacBridgeStatus { DISABLED, CONNECTING, CONNECTED, RECONNECTING }

/**
 * MacBridgeClient — persistent WebSocket client that connects Android to the
 * Mac Jarvis server over Tailscale.
 *
 * Wire protocol:
 *   Inbound  (Mac → Android):  type="request"  → dispatch to [executor] → send type="response"
 *   Outbound (Android → Mac):  type="event"    → heartbeat / capabilities_report (unsolicited)
 *
 * Every outbound frame includes `"auth"` at the top level.
 * Auth token is never written to logcat.
 *
 * Reconnect: exponential backoff 1 s → 2 s → 4 s → … → 30 s cap.
 */
class MacBridgeClient(
    private val context: Context,
    private val settingsRepo: MacBridgeSettingsRepository,
    private val executor: MacBridgeCommandExecutor,
) {
    companion object {
        private const val TAG = "MacBridgeClient"
        private const val HEARTBEAT_INTERVAL_MS = 30_000L
        private const val MAX_BACKOFF_MS        = 30_000L
        private const val RESPONSE_TIMEOUT_MS   = 14_000L

        private val _sharedStatus = MutableStateFlow(MacBridgeStatus.DISABLED)
        val sharedStatus: StateFlow<MacBridgeStatus> = _sharedStatus.asStateFlow()

        /** Last inbound command from Mac — updated whenever a command is dispatched. */
        @Volatile var lastSharedInboundCommand: String = ""
            private set
        @Volatile var lastSharedInboundStatus: String = ""
            private set

        /**
         * Whether Mac Jarvis reported itself as actively listening/speaking.
         * Set when a mac_status frame arrives; defaults true so we conservatively
         * treat a connected Mac as active until it tells us otherwise.
         */
        @Volatile var sharedMacAssistantActive: Boolean = true
            private set

        /**
         * Epoch-ms of the last frame received from Mac (any type).
         * Used by [RoleArbitrator] to compute "last Mac activity age".
         */
        val sharedLastActivityAtMs: AtomicLong = AtomicLong(0L)
    }

    private val _status = MutableStateFlow(MacBridgeStatus.DISABLED)
    val status: StateFlow<MacBridgeStatus> = _status.asStateFlow()

    private fun setStatus(s: MacBridgeStatus) {
        _status.value = s
        _sharedStatus.value = s
    }

    @Volatile private var scope: CoroutineScope = newScope()
    private val running = AtomicBoolean(false)
    @Volatile private var ws: WebSocket? = null

    // Set true in onClosed (clean server-initiated close) so connectLoop waits
    // at least MAX_BACKOFF_MS before reconnecting — avoids tripping the Mac's
    // auth-failure rate limiter on repeated fast reconnects.
    @Volatile private var serverInitiatedClose = false

    // ── Diagnostics ───────────────────────────────────────────────────────────
    val reconnectCount: AtomicInteger = AtomicInteger(0)
    val lastEventSentAtMs: AtomicLong = AtomicLong(0L)
    @Volatile var lastEventCommand: String = ""
        private set

    /** Last command received FROM Mac (inbound request). */
    @Volatile var lastInboundCommand: String = ""
        private set
    val lastInboundAtMs: AtomicLong = AtomicLong(0L)
    @Volatile var lastInboundStatus: String = ""
        private set

    /** Whether Mac Jarvis is actively listening/speaking (from mac_status frames). */
    @Volatile var macAssistantActive: Boolean = true
        private set

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
        setStatus(MacBridgeStatus.CONNECTING)
        scope.launch { connectLoop() }
    }

    fun stop() {
        running.set(false)
        ws?.close(1000, "Service stopping")
        ws = null
        serverInitiatedClose = false
        setStatus(MacBridgeStatus.DISABLED)
        scope.cancel()
        reconnectCount.set(0)
    }

    fun notifyCapabilitiesChanged() {
        if (_status.value == MacBridgeStatus.CONNECTED) {
            sendCapabilitiesReport()
        }
    }

    /**
     * Emit a proactive event frame to Mac Jarvis (Android → Mac unsolicited).
     * No-op when not connected. Auth is injected by [sendFrame].
     */
    fun emitEvent(command: String, payload: JSONObject) {
        val currentStatus = _status.value
        if (currentStatus != MacBridgeStatus.CONNECTED) {
            Log.w(TAG, "emitEvent('$command') skipped — bridge not connected (status=$currentStatus)")
            return
        }
        if (settingsRepo.snapshot().authToken.isBlank()) {
            Log.w(TAG, "emitEvent('$command') skipped — auth token is blank")
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
            lastEventCommand = command
            Log.i(TAG, "✅ emitEvent('$command') sent OK")
        } else {
            Log.w(TAG, "❌ emitEvent('$command') — ws.send returned false (ws=${ws != null})")
        }
    }

    // ── Connection loop ───────────────────────────────────────────────────────

    private suspend fun connectLoop() {
        var backoffMs = 1_000L
        while (running.get()) {
            val cfg = settingsRepo.snapshot()
            if (!cfg.enabled || !cfg.isConfigured) {
                setStatus(MacBridgeStatus.DISABLED)
                return
            }
            setStatus(MacBridgeStatus.CONNECTING)
            connect(cfg)
            if (!running.get()) break
            // After a clean server-initiated close (e.g. auth rate-limit cut),
            // jump straight to the maximum wait so we don't re-trigger the limiter.
            val waitMs = if (serverInitiatedClose) {
                serverInitiatedClose = false
                MAX_BACKOFF_MS
            } else {
                backoffMs
            }
            Log.d(TAG, "Reconnecting in ${waitMs}ms (serverClose=${waitMs == MAX_BACKOFF_MS})")
            setStatus(MacBridgeStatus.RECONNECTING)
            reconnectCount.incrementAndGet()
            delay(waitMs)
            backoffMs = (backoffMs * 2).coerceAtMost(MAX_BACKOFF_MS)
        }
    }

    private suspend fun connect(cfg: MacBridgeConfig) = suspendCancellableCoroutine<Unit> { cont ->
        Log.d(TAG, "Connecting to ${cfg.wsUrl}")
        val req = Request.Builder().url(cfg.wsUrl).build()

        ws = httpClient.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                ws = webSocket
                Log.d(TAG, "Connected to Mac Jarvis bridge")
                reconnectCount.set(0)
                serverInitiatedClose = false
                setStatus(MacBridgeStatus.CONNECTED)
                sendCapabilitiesReport()
                scope.launch { heartbeatLoop() }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleInbound(text, cfg)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                serverInitiatedClose = true
                webSocket.close(1000, null)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "Bridge WS failure: ${t.javaClass.simpleName} ${t.message} " +
                    "http=${response?.code ?: "-"}")
                if (running.get()) setStatus(MacBridgeStatus.RECONNECTING)
                if (cont.isActive) cont.resume(Unit)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "Bridge WS closed: $code $reason")
                if (running.get()) setStatus(MacBridgeStatus.RECONNECTING)
                if (cont.isActive) cont.resume(Unit)
            }
        })

        cont.invokeOnCancellation { ws?.close(1000, "Service stopping") }
    }

    // ── Heartbeat ─────────────────────────────────────────────────────────────

    private suspend fun heartbeatLoop() {
        while (running.get() && _status.value == MacBridgeStatus.CONNECTED) {
            delay(HEARTBEAT_INTERVAL_MS)
            if (_status.value != MacBridgeStatus.CONNECTED) break
            sendHeartbeat()
        }
    }

    // ── Outbound frames ───────────────────────────────────────────────────────

    private fun sendHeartbeat() {
        val cfg     = settingsRepo.snapshot()
        val bm      = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val charging = bm?.isCharging ?: false
        val fgPkg   = com.jarvis.assistant.accessibility.JarvisAccessibilityService
            .currentForegroundPackage
        val fgLabel = if (fgPkg != null) resolveAppLabel(fgPkg) else null
        val frame = JSONObject().apply {
            put("type", "event")
            put("command", "heartbeat")
            put("payload", JSONObject().apply {
                put("battery", batteryLevel())
                put("charging", charging)
                put("deviceName", deviceName())
                put("eventBroadcasting", cfg.eventsEnabled)
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
            })
        }
        sendFrame(frame)
    }

    private fun resolveAppLabel(pkg: String): String? = runCatching {
        context.packageManager.getApplicationLabel(
            context.packageManager.getApplicationInfo(pkg, 0)
        ).toString()
    }.getOrNull()

    private fun sendCapabilitiesReport() {
        val cfg  = settingsRepo.snapshot()
        val caps = cfg.enabledCapabilities.filter { it in MacBridgeCapability.ALL }
        val frame = JSONObject().apply {
            put("type", "event")
            put("command", "capabilities_report")
            put("payload", JSONObject().apply {
                put("capabilities", JSONArray(caps))
            })
        }
        sendFrame(frame)
        Log.d(TAG, "Sent capabilities_report: ${caps.size} caps")
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

    private fun handleInbound(text: String, cfg: MacBridgeConfig) {
        val json = runCatching { JSONObject(text) }.getOrNull() ?: run {
            Log.w(TAG, "Bridge: malformed JSON frame")
            return
        }

        val frameType = json.optString("type")

        // mac_status — unsolicited frame from Mac reporting its own assistant state.
        // No auth check required (it carries no privileged action), just update display fields.
        if (frameType == "mac_status") {
            val active = json.optBoolean("assistant_active", true)
            macAssistantActive = active
            sharedMacAssistantActive = active
            sharedLastActivityAtMs.set(System.currentTimeMillis())
            Log.d(TAG, "mac_status: assistant_active=$active")
            com.jarvis.assistant.JarvisApp.roleArbitrator.onMacStatusReceived(active)
            return
        }

        if (frameType != "request") return

        val requestId = json.optString("id")
        val command   = json.optString("command")
        val payload   = json.optJSONObject("payload") ?: JSONObject()

        if (requestId.isBlank() || command.isBlank()) return

        // Auth check — reject frames with wrong or missing token
        val frameAuth = json.optString("auth")
        if (frameAuth != cfg.authToken) {
            Log.w(TAG, "Bridge: auth mismatch — dropping frame (cmd=$command)")
            sendResponse(requestId, false, "auth_failed", "Invalid auth token")
            return
        }

        if (command !in cfg.enabledCapabilities && command != "ping" && command != "get_capabilities") {
            sendResponse(requestId, false, "capability_disabled",
                "Capability '$command' is disabled on this device")
            return
        }

        lastInboundCommand = command
        lastSharedInboundCommand = command
        lastInboundAtMs.set(System.currentTimeMillis())
        sharedLastActivityAtMs.set(System.currentTimeMillis())

        scope.launch {
            try {
                val result = executor.execute(command, payload, cfg)
                val statusStr = if (result.ok) result.status ?: "ok" else "error: ${result.message}"
                lastInboundStatus = statusStr
                lastSharedInboundStatus = statusStr
                sendResponse(requestId, result.ok, result.status, result.message, result.payload)
            } catch (e: Exception) {
                val statusStr = "error: ${e.message}"
                lastInboundStatus = statusStr
                lastSharedInboundStatus = statusStr
                Log.w(TAG, "Bridge command '$command' threw: ${e.message}")
                sendResponse(requestId, false, "error", e.message ?: "Unexpected error")
            }
        }
    }

    // ── Single outbound chokepoint ────────────────────────────────────────────

    /**
     * The only path that writes to the WebSocket. Injects [auth] on every
     * frame, enforces the 64 KB wire ceiling, and logs auth presence (never
     * the token value). Returns true when OkHttp accepted the frame.
     */
    private fun sendFrame(frame: JSONObject): Boolean {
        val token = settingsRepo.snapshot().authToken
        return try {
            val json = buildAuthenticatedJson(frame, token)
            Log.d(TAG, "sendFrame: type=${frame.optString("type")} " +
                "command=${frame.optString("command")} auth_present=${token.isNotBlank()}")
            ws?.send(json) ?: false
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "sendFrame: ${e.message}")
            false
        }
    }

    // ── Device info ───────────────────────────────────────────────────────────

    private fun batteryLevel(): Int {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            ?: return -1
        return bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
    }

    private fun deviceName(): String =
        Settings.Global.getString(context.contentResolver, "device_name")
            ?.takeIf { it.isNotBlank() }
            ?: android.os.Build.MODEL
}

/** Result returned by [MacBridgeCommandExecutor.execute]. */
data class BridgeResult(
    val ok: Boolean,
    val status: String? = null,
    val message: String? = null,
    val payload: JSONObject = JSONObject(),
)

/**
 * Pure helper — injects [token] into [frame] and serialises it.
 *
 * Separated from [MacBridgeClient] so unit tests can call it directly
 * without Android context.  [MacBridgeClient.sendFrame] is the only
 * production call site.
 *
 * @throws IllegalArgumentException when the serialised frame exceeds 64 KB.
 */
internal fun buildAuthenticatedJson(frame: JSONObject, token: String): String {
    if (token.isNotBlank()) frame.put("auth", token)
    val json = frame.toString()
    require(json.toByteArray(Charsets.UTF_8).size <= 64 * 1024) {
        "Bridge frame exceeds 64 KB (${json.length} chars) — type=${frame.optString("type")}"
    }
    return json
}
