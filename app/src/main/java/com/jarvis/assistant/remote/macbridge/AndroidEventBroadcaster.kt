package com.jarvis.assistant.remote.macbridge

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import com.jarvis.assistant.core.events.EventBus
import com.jarvis.assistant.core.events.EventKind
import com.jarvis.assistant.notifications.JarvisNotificationListener
import com.jarvis.assistant.notifications.MessagingAppCapabilityRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.LinkedHashMap
import java.util.UUID

/**
 * AndroidEventBroadcaster — subscribes to the process-wide EventBus and relays
 * phone/notification/device events to Mac Jarvis over the WebSocket bridge.
 *
 * Event taxonomy (command field on the wire):
 *   incoming_call        CALL_RINGING
 *   call_answered        CALL_ANSWERED (incoming only)
 *   call_ended           CALL_ENDED (after being answered)
 *   missed_call          CALL_ENDED without prior CALL_ANSWERED
 *   sms_received         NOTIFICATION_POSTED from SMS app
 *   whatsapp_received    NOTIFICATION_POSTED from WhatsApp
 *   notification_received NOTIFICATION_POSTED from other app (opt-in)
 *   battery_low          BATTERY_LOW
 *   power_connected      POWER_CONNECTED
 *   power_disconnected   POWER_DISCONNECTED
 *
 * Caller name resolution (API 31+ has no phone number in telephony callback):
 *   Polls JarvisNotificationListener.peekCallerName() for up to CALLER_NAME_POLL_BUDGET_MS.
 *   Call notifications typically arrive within 300ms of RINGING; WhatsApp VoIP can
 *   take up to 1500ms.  The poll prevents "Unknown caller" on most calls.
 *
 * Logging: every pipeline stage logs with TAG so `adb logcat -s MacBridgeBroadcast`
 * shows the full trace.
 */
object AndroidEventBroadcaster {

    private const val TAG = "MacBridgeBroadcast"

    // Maximum time to wait for the call notification to deliver the caller name.
    private const val CALLER_NAME_POLL_BUDGET_MS = 1_500L
    private const val CALLER_NAME_POLL_STEP_MS   = 100L

    // ── Deduplication ─────────────────────────────────────────────────────────

    private val dedupLock = Any()
    private val dedupCache = object : LinkedHashMap<String, Long>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, Long>) = size > 200
    }

    private fun isDuplicate(fingerprint: String, windowMs: Long = 3_000L): Boolean {
        val now = System.currentTimeMillis()
        return synchronized(dedupLock) {
            val last = dedupCache[fingerprint]
            if (last != null && (now - last) < windowMs) {
                Log.d(TAG, "  [dedup] suppressed '$fingerprint' (last=${now - last}ms ago)")
                true
            } else {
                dedupCache[fingerprint] = now
                false
            }
        }
    }

    // ── Call state tracking ───────────────────────────────────────────────────

    @Volatile private var sawRinging  = false
    @Volatile private var sawAnswered = false
    @Volatile private var callerName  = ""

    // ── Diagnostics ───────────────────────────────────────────────────────────

    data class DiagnosticsState(
        val lastEventCommand: String = "",
        val lastEventSentAt: Long = 0L,
        val reconnectCount: Int = 0,
        val notificationListenerActive: Boolean = false,
        val eventsEnabled: Boolean = false,
    )

    private val _diagnostics = MutableStateFlow(DiagnosticsState())
    val diagnostics: StateFlow<DiagnosticsState> = _diagnostics.asStateFlow()

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    private var client: MacBridgeClient? = null
    private var settingsRepo: MacBridgeSettingsRepository? = null
    private var context: Context? = null
    private var scope: CoroutineScope? = null
    private var job: Job? = null

    fun attach(
        client: MacBridgeClient,
        settingsRepo: MacBridgeSettingsRepository,
        scope: CoroutineScope,
        context: Context,
    ) {
        if (job != null) {
            Log.d(TAG, "attach() called but already attached — ignoring")
            return
        }
        this.client       = client
        this.settingsRepo = settingsRepo
        this.context      = context
        this.scope        = scope

        job = scope.launch {
            Log.i(TAG, "▶ EventBus subscription started")
            EventBus.events.collect { event ->
                val cfg = settingsRepo.snapshot()

                // Gate 1: bridge must be enabled
                if (!cfg.enabled) {
                    Log.v(TAG, "Gate1: bridge disabled — skipping ${event.kind}")
                    return@collect
                }
                // Gate 2: event broadcasting must be enabled
                if (!cfg.eventsEnabled) {
                    Log.v(TAG, "Gate2: eventsEnabled=false — skipping ${event.kind}")
                    return@collect
                }

                when (event.kind) {
                    EventKind.CALL_RINGING           -> handleCallRinging(event.payload, cfg)
                    EventKind.CALL_ANSWERED          -> handleCallAnswered(event.payload, cfg)
                    EventKind.CALL_ENDED             -> handleCallEnded(event.payload, cfg)
                    EventKind.NOTIFICATION_POSTED    -> handleNotification(event.payload, cfg)
                    EventKind.BATTERY_LOW            -> handleBatteryLow(event.payload, cfg)
                    EventKind.POWER_CONNECTED        -> handlePower("power_connected", event.payload, cfg)
                    EventKind.POWER_DISCONNECTED     -> handlePower("power_disconnected", event.payload, cfg)
                    EventKind.FOREGROUND_APP_CHANGED -> handleForegroundAppChanged(event.payload, cfg)
                    else -> Unit
                }

                refreshDiagnostics(cfg)
            }
        }
        Log.i(TAG, "▶ Attached to EventBus (scope=$scope)")
    }

    fun detach() {
        job?.cancel()
        job          = null
        client       = null
        settingsRepo = null
        context      = null
        scope        = null
        sawRinging   = false
        sawAnswered  = false
        callerName   = ""
        Log.i(TAG, "■ Detached from EventBus")
    }

    // ── Test event (debug only) ───────────────────────────────────────────────

    /**
     * Fire a synthetic incoming_call event immediately.
     * Bypasses all gates except the WebSocket connection check.
     * Used by the "Send test event" button in diagnostics.
     */
    fun sendTestIncomingCall() {
        val c = client ?: run {
            Log.w(TAG, "sendTestIncomingCall: client is null — broadcaster not attached")
            return
        }
        val cfg = settingsRepo?.snapshot() ?: run {
            Log.w(TAG, "sendTestIncomingCall: settingsRepo is null")
            return
        }
        Log.i(TAG, "🧪 Sending TEST incoming_call event")
        val payload = JSONObject().apply {
            put("contactName", "Test Caller")
            put("app", "Phone")
            put("isTest", true)
        }
        emit("incoming_call", payload, cfg, forceEmit = true)
    }

    // ── Call handling ─────────────────────────────────────────────────────────

    private suspend fun handleCallRinging(payload: Map<String, String>, cfg: MacBridgeConfig) {
        Log.i(TAG, "handleCallRinging: eventsCalls=${cfg.eventsCalls}")
        if (!cfg.eventsCalls) {
            Log.d(TAG, "  → skipped: eventsCalls=false")
            return
        }

        // On API 31+, TelephonyCallback omits the phone number. Poll the notification
        // listener cache — call notifications typically arrive within 300ms.
        var nameFromCache = JarvisNotificationListener.peekCallerName()
        Log.d(TAG, "  notif cache on entry: '${nameFromCache ?: "<null>"}'")

        if (nameFromCache.isNullOrBlank()) {
            Log.d(TAG, "  polling notification cache up to ${CALLER_NAME_POLL_BUDGET_MS}ms…")
            var waitedMs = 0L
            while (nameFromCache.isNullOrBlank() && waitedMs < CALLER_NAME_POLL_BUDGET_MS) {
                delay(CALLER_NAME_POLL_STEP_MS)
                waitedMs += CALLER_NAME_POLL_STEP_MS
                nameFromCache = JarvisNotificationListener.peekCallerName()
            }
            Log.d(TAG, "  notif cache after ${waitedMs}ms poll: '${nameFromCache ?: "<null>"}'")
        }

        val nameFromPayload = payload["contact_name"]?.takeIf { it.isNotBlank() && it != "Unknown caller" }
            ?: payload["phone_number"]?.takeIf { it.isNotBlank() }
        Log.d(TAG, "  payload contact_name='${payload["contact_name"]}' phone_number='${payload["phone_number"]}'")

        val resolved = when {
            !nameFromCache.isNullOrBlank() -> nameFromCache
            !nameFromPayload.isNullOrBlank() -> nameFromPayload
            else -> "Unknown caller"
        }.let { if (!cfg.shareCallerNames) "Incoming call" else it }

        Log.i(TAG, "  resolved caller: '$resolved' (shareCallerNames=${cfg.shareCallerNames})")

        val fp = "call_ringing:$resolved"
        if (isDuplicate(fp, 2_000L)) return

        sawRinging  = true
        sawAnswered = false
        callerName  = resolved

        emit("incoming_call", buildCallPayload(resolved), cfg)
    }

    private fun handleCallAnswered(payload: Map<String, String>, cfg: MacBridgeConfig) {
        Log.i(TAG, "handleCallAnswered: sawRinging=$sawRinging eventsCalls=${cfg.eventsCalls}")
        if (!cfg.eventsCalls) return
        if (!sawRinging) {
            Log.d(TAG, "  → skipped: sawRinging=false (outgoing call)")
            return
        }

        val fp = "call_answered:$callerName"
        if (isDuplicate(fp, 2_000L)) return

        sawAnswered = true
        emit("call_answered", buildCallPayload(callerName), cfg)
    }

    private fun handleCallEnded(payload: Map<String, String>, cfg: MacBridgeConfig) {
        Log.i(TAG, "handleCallEnded: sawRinging=$sawRinging sawAnswered=$sawAnswered eventsCalls=${cfg.eventsCalls}")
        if (!cfg.eventsCalls) return

        val command = when {
            !sawRinging  -> { Log.d(TAG, "  → skipped: sawRinging=false (outgoing)"); return }
            !sawAnswered -> "missed_call"
            else         -> "call_ended"
        }
        Log.i(TAG, "  → command: $command  caller: '$callerName'")

        val fp = "$command:$callerName"
        if (isDuplicate(fp, 2_000L)) return

        sawRinging  = false
        sawAnswered = false

        emit(command, buildCallPayload(callerName), cfg)
        callerName = ""
    }

    private fun buildCallPayload(name: String) = JSONObject().apply {
        put("contactName", name)
        put("app", "Phone")
    }

    // ── Notification handling ─────────────────────────────────────────────────

    private val SMS_PACKAGES = setOf(
        "com.google.android.apps.messaging",
        "com.android.mms",
        "com.android.messaging",
    )
    private val WHATSAPP_PACKAGES = setOf("com.whatsapp", "com.whatsapp.w4b")

    private fun handleNotification(payload: Map<String, String>, cfg: MacBridgeConfig) {
        if (payload["is_call"] == "true") return
        if (payload["is_ha_alert"] == "true") return

        val pkg   = payload["app_package"] ?: return
        val title = payload["title"]  ?: ""
        val text  = payload["text"]   ?: ""
        val isMsg = payload["is_messaging"] == "true"

        val dedupeKey = payload["sbn_key"] ?: "$pkg:${title.take(30)}:${text.take(30)}"
        if (isDuplicate("notif:$dedupeKey", 5_000L)) return

        val command = when {
            pkg in WHATSAPP_PACKAGES && cfg.eventsWhatsApp -> "whatsapp_received"
            pkg in SMS_PACKAGES && cfg.eventsSms           -> "sms_received"
            isMsg && cfg.eventsNotifications               -> "notification_received"
            !isMsg && cfg.eventsNotifications              -> "notification_received"
            else -> {
                Log.d(TAG, "  notif suppressed: pkg=$pkg isMsg=$isMsg eventsNotif=${cfg.eventsNotifications}")
                return
            }
        }

        if (command == "whatsapp_received") {
            // Use MessagingStyle-extracted fields enriched by JarvisNotificationListener.
            // sender_name is null when extraction genuinely failed — Mac falls back to
            // "You've had a WhatsApp message." in that case (no fake "someone" sentinel).
            val senderName = payload["wa_sender_name"]?.takeIf { it.isNotBlank() }
            val groupName  = payload["wa_group_name"]?.takeIf { it.isNotBlank() }
            val messageBody = if (cfg.shareMsgPreviews) text.ifBlank { null } else null

            Log.i(TAG, "handleNotification: whatsapp_received  sender='${senderName ?: "—"}'  " +
                "group='${groupName ?: "—"}'  preview=${messageBody != null}  pkg=$pkg")

            val body = JSONObject().apply {
                put("event_id", UUID.randomUUID().toString())
                put("type", "whatsapp_received")
                if (senderName != null) put("sender_name", senderName)
                if (groupName  != null) put("group_name",  groupName)
                if (messageBody != null) put("message_body", messageBody.take(200))
                put("message_preview_enabled", cfg.shareMsgPreviews)
                put("timestamp", isoNow())
            }
            emit(command, body, cfg)
            return
        }

        val sender  = title.ifBlank { MessagingAppCapabilityRegistry.displayName(pkg) }
        val preview = if (cfg.shareMsgPreviews) text else null

        Log.i(TAG, "handleNotification: $command  sender='$sender'  pkg=$pkg")

        val body = JSONObject().apply {
            put("contactName", sender)
            put("app", MessagingAppCapabilityRegistry.displayName(pkg))
            put("packageName", pkg)
            if (preview != null) put("messagePreview", preview.take(200))
        }
        emit(command, body, cfg)
    }

    // ── Battery / power handling ──────────────────────────────────────────────

    private fun handleBatteryLow(payload: Map<String, String>, cfg: MacBridgeConfig) {
        if (!cfg.eventsBattery) return
        val pct = payload["battery_pct"] ?: "?"
        val fp  = "battery_low:${pct.take(3)}"
        if (isDuplicate(fp, 5 * 60_000L)) return

        emit("battery_status", JSONObject().apply {
            put("level", pct.toIntOrNull() ?: -1)
            put("charging", false)
            put("alert", "low")
        }, cfg)
    }

    private fun handlePower(command: String, payload: Map<String, String>, cfg: MacBridgeConfig) {
        if (!cfg.eventsBattery) return
        val fp = "power:$command"
        if (isDuplicate(fp, 5_000L)) return

        emit(command, JSONObject().apply {
            put("batteryLevel", payload["battery_pct"]?.toIntOrNull() ?: -1)
        }, cfg)
    }

    // ── Foreground app context ────────────────────────────────────────────────

    private fun handleForegroundAppChanged(payload: Map<String, String>, cfg: MacBridgeConfig) {
        val pkg = payload["app_package"] ?: return
        // Skip Jarvis itself appearing in the foreground (e.g. when settings open)
        if (pkg == context?.packageName) return
        if (isDuplicate("fg:$pkg", 3_000L)) return

        val body = JSONObject().apply {
            put("foregroundApp", appContextJson(pkg))
            payload["previous_app_package"]?.let { put("previousApp", appContextJson(it)) }
        }
        Log.d(TAG, "handleForegroundAppChanged: pkg=$pkg")
        emit("device_context_changed", body, cfg)
    }

    private fun appContextJson(pkg: String): JSONObject {
        val label = context?.let { ctx ->
            runCatching {
                ctx.packageManager.getApplicationLabel(
                    ctx.packageManager.getApplicationInfo(pkg, 0)
                ).toString()
            }.getOrElse { pkg }
        } ?: pkg
        return JSONObject().apply {
            put("package", pkg)
            put("label", label)
        }
    }

    // ── Emit ──────────────────────────────────────────────────────────────────

    private fun emit(
        command: String,
        payload: JSONObject,
        cfg: MacBridgeConfig,
        forceEmit: Boolean = false,
    ) {
        val c = client
        if (c == null) {
            Log.w(TAG, "emit('$command'): client is null — broadcaster not fully attached")
            return
        }
        val wrapped = JSONObject().apply {
            put("id", UUID.randomUUID().toString())
            put("source", "android")
            put("event", command)
            put("timestamp", isoNow())
            put("data", payload)
        }
        Log.i(TAG, "→ emit('$command') to MacBridgeClient  forceEmit=$forceEmit")
        c.emitEvent(command, wrapped)
    }

    // ── Diagnostics refresh ───────────────────────────────────────────────────

    private fun refreshDiagnostics(cfg: MacBridgeConfig) {
        val c = client ?: return
        _diagnostics.value = DiagnosticsState(
            lastEventCommand       = c.lastEventCommand,
            lastEventSentAt        = c.lastEventSentAtMs.get(),
            reconnectCount         = c.reconnectCount.get(),
            notificationListenerActive = JarvisNotificationListener.isConnected(),
            eventsEnabled          = cfg.eventsEnabled,
        )
    }

    // ── Permission check (called from diagnostics screen) ────────────────────

    fun logPermissionState(context: Context) {
        val readPhoneState = context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) ==
            PackageManager.PERMISSION_GRANTED
        val readContacts = context.checkSelfPermission(Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED
        val notifListener = JarvisNotificationListener.isGranted(context)
        val notifConnected = JarvisNotificationListener.isConnected()
        Log.i(TAG, "Permission state: READ_PHONE_STATE=$readPhoneState  READ_CONTACTS=$readContacts  " +
            "notifListener=$notifListener  notifConnected=$notifConnected")

        val cfg = settingsRepo?.snapshot()
        Log.i(TAG, "Bridge config: enabled=${cfg?.enabled}  eventsEnabled=${cfg?.eventsEnabled}  " +
            "eventsCalls=${cfg?.eventsCalls}  isConfigured=${cfg?.isConfigured}")
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun isoNow(): String =
        DateTimeFormatter.ISO_INSTANT.format(Instant.now().atOffset(ZoneOffset.UTC))
}
