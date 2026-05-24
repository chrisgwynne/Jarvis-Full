package com.jarvis.assistant.remote.macbridge

import android.Manifest
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.location.Location
import android.location.LocationManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationServices
import com.jarvis.assistant.notifications.JarvisNotificationListener
import com.jarvis.assistant.notifications.NotificationEntry
import com.jarvis.assistant.notifications.RecentMessageContext
import com.jarvis.assistant.tools.ContactLookup
import com.jarvis.assistant.tools.device.WhatsAppCallAdapter
import com.jarvis.assistant.tools.framework.ToolResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume

/**
 * MacBridgeCommandExecutor — maps every bridge command name to an Android action.
 *
 * All methods are suspend functions and safe to call from a coroutine dispatcher.
 * UI-bound actions (intents, ringtone) are dispatched on the main thread via Handler.
 */
class MacBridgeCommandExecutor(
    private val context: Context,
    private val contacts: ContactLookup,
) {
    companion object {
        private const val TAG = "MacBridgeExec"
        private const val RING_DURATION_MS = 10_000L
    }

    // ── Entry point ───────────────────────────────────────────────────────────

    suspend fun execute(
        command: String,
        payload: JSONObject,
        cfg: MacBridgeConfig,
    ): BridgeResult = when (command) {
        "ping"                -> ping()
        "call_contact"        -> callContact(payload)
        "send_sms"            -> sendSms(payload)
        "send_whatsapp"       -> sendWhatsApp(payload)
        "find_contact"        -> findContact(payload)
        "ring_phone"          -> ringPhone()
        "phone_location"      -> phoneLocation()
        "start_navigation"    -> startNavigation(payload)
        "read_notifications"  -> readNotifications()
        "query_notification"  -> queryNotification(payload)
        "capture_camera"      -> captureCamera()
        "get_capabilities"    -> getCapabilities(cfg)
        "speakerphone_on"     -> setSpeakerphone(true)
        "speakerphone_off"    -> setSpeakerphone(false)
        "whatsapp_voice_call" -> whatsAppCall(payload, isVideo = false)
        "whatsapp_video_call" -> whatsAppCall(payload, isVideo = true)
        "reply_to_contact"    -> replyToContact(payload)
        "reply_last_message"  -> replyLastMessage(payload)
        else -> BridgeResult(false, "unknown_command", "Unknown command: $command")
    }

    // ── Command implementations ───────────────────────────────────────────────

    private fun ping() = BridgeResult(true, null, "pong")

    // ─── call_contact ──────────────────────────────────────────────────────────

    private suspend fun callContact(payload: JSONObject): BridgeResult = withContext(Dispatchers.Main) {
        if (!hasPermission(Manifest.permission.CALL_PHONE))
            return@withContext BridgeResult(false, "permission_denied",
                "CALL_PHONE permission not granted")

        val contactName = payload.optString("contact").ifBlank {
            return@withContext BridgeResult(false, "missing_param", "contact name required")
        }

        // Direct call by contactId (disambiguation response)
        val contactId = payload.optString("contactId").takeIf { it.isNotBlank() }
        if (contactId != null) {
            val contact = resolveById(contactId)
                ?: return@withContext BridgeResult(false, "not_found",
                    "Contact ID $contactId not found")
            placeCall(contact.number)
            return@withContext BridgeResult(true, "calling", "Calling ${contact.displayName}")
        }

        // Standard name lookup
        val found = contacts.find(contactName)
        if (found != null) {
            placeCall(found.number)
            return@withContext BridgeResult(true, "calling", "Calling ${found.displayName}")
        }

        // Disambiguation
        val ambiguous = contacts.lastAmbiguousMatches
        if (ambiguous.size in 2..4) {
            val contactsJson = JSONArray(ambiguous.map { c ->
                JSONObject().apply {
                    put("id", c.name)
                    put("name", c.name)
                    put("phone", c.phoneNumber)
                }
            })
            return@withContext BridgeResult(
                ok      = false,
                status  = "needs_clarification",
                message = contacts.disambiguationPrompt(),
                payload = JSONObject().apply { put("contacts", contactsJson) },
            )
        }

        BridgeResult(false, "not_found", "No contact found for '$contactName'")
    }

    private fun placeCall(number: String) {
        context.startActivity(
            Intent(Intent.ACTION_CALL, Uri.parse("tel:$number"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    private fun resolveById(id: String): ContactLookup.Contact? =
        contacts.find(id)

    // ─── send_sms ─────────────────────────────────────────────────────────────

    private suspend fun sendSms(payload: JSONObject): BridgeResult = withContext(Dispatchers.IO) {
        if (!hasPermission(Manifest.permission.SEND_SMS))
            return@withContext BridgeResult(false, "permission_denied",
                "SEND_SMS permission not granted")

        val recipient = payload.optString("recipient").ifBlank {
            return@withContext BridgeResult(false, "missing_param", "recipient required")
        }
        val message = payload.optString("message").ifBlank {
            return@withContext BridgeResult(false, "missing_param", "message required")
        }

        val contact = contacts.find(recipient)
            ?: return@withContext BridgeResult(false, "not_found",
                "No contact found for '$recipient'")

        try {
            @Suppress("DEPRECATION")
            val sm = SmsManager.getDefault()
            val parts = sm.divideMessage(message)
            sm.sendMultipartTextMessage(contact.number, null, parts, null, null)
            Log.d(TAG, "SMS sent to ${contact.displayName}")
            BridgeResult(true, "sent", "SMS sent to ${contact.displayName}")
        } catch (e: Exception) {
            Log.w(TAG, "SMS failed: ${e.message}")
            BridgeResult(false, "error", "Failed to send SMS: ${e.message}")
        }
    }

    // ─── send_whatsapp ────────────────────────────────────────────────────────

    private suspend fun sendWhatsApp(payload: JSONObject): BridgeResult = withContext(Dispatchers.Main) {
        val recipient = payload.optString("recipient").ifBlank {
            return@withContext BridgeResult(false, "missing_param", "recipient required")
        }
        val message = payload.optString("message").ifBlank {
            return@withContext BridgeResult(false, "missing_param", "message required")
        }

        val contact = contacts.find(recipient)
            ?: return@withContext BridgeResult(false, "not_found",
                "No contact found for '$recipient'")

        // Normalise number: strip leading zeros, ensure + prefix
        val e164 = normalisePhone(contact.number)
        return@withContext try {
            val uri = Uri.parse("https://api.whatsapp.com/send?phone=$e164&text=${Uri.encode(message)}")
            val intent = Intent(Intent.ACTION_VIEW, uri)
                .setPackage("com.whatsapp")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (intent.resolveActivity(context.packageManager) != null) {
                context.startActivity(intent)
                BridgeResult(true, "sent", "WhatsApp message sent to ${contact.displayName}")
            } else {
                BridgeResult(false, "app_not_found", "WhatsApp is not installed")
            }
        } catch (e: Exception) {
            BridgeResult(false, "error", "Failed to open WhatsApp: ${e.message}")
        }
    }

    // ─── find_contact ─────────────────────────────────────────────────────────

    private suspend fun findContact(payload: JSONObject): BridgeResult = withContext(Dispatchers.IO) {
        if (!hasPermission(Manifest.permission.READ_CONTACTS))
            return@withContext BridgeResult(false, "permission_denied",
                "READ_CONTACTS permission not granted")

        val query = payload.optString("query").ifBlank {
            return@withContext BridgeResult(false, "missing_param", "query required")
        }

        val results = contacts.fuzzyLookup(query)
        val arr = JSONArray(results.map { r ->
            JSONObject().apply {
                put("id", r.name)
                put("name", r.name)
                put("phone", r.phoneNumber)
            }
        })
        BridgeResult(
            ok      = true,
            payload = JSONObject().apply { put("contacts", arr) },
        )
    }

    // ─── ring_phone ───────────────────────────────────────────────────────────

    private fun ringPhone(): BridgeResult {
        return try {
            val am = context.getSystemService(AudioManager::class.java)!!
            @Suppress("DEPRECATION")
            am.ringerMode = AudioManager.RINGER_MODE_NORMAL
            am.setStreamVolume(
                AudioManager.STREAM_RING,
                am.getStreamMaxVolume(AudioManager.STREAM_RING),
                0,
            )
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val ring = RingtoneManager.getRingtone(context, uri)!!
            ring.play()
            Handler(Looper.getMainLooper()).postDelayed({
                try { ring.stop() } catch (_: Exception) {}
                // Also try to strobe flash for visibility
                try { flashStrobe(RING_DURATION_MS) } catch (_: Exception) {}
            }, 50)
            BridgeResult(true, null, "Ringing for 10 seconds")
        } catch (e: Exception) {
            BridgeResult(false, "error", "Could not ring phone: ${e.message}")
        }
    }

    private fun flashStrobe(durationMs: Long) {
        val cm = context.getSystemService(CameraManager::class.java) ?: return
        val flashId = cm.cameraIdList.firstOrNull { id ->
            cm.getCameraCharacteristics(id)
                .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return
        val handler = Handler(Looper.getMainLooper())
        val end = System.currentTimeMillis() + durationMs
        var on = false
        lateinit var tick: Runnable
        tick = Runnable {
            try { on = !on; cm.setTorchMode(flashId, on) } catch (_: Exception) {}
            if (System.currentTimeMillis() < end) handler.postDelayed(tick, 300)
            else try { cm.setTorchMode(flashId, false) } catch (_: Exception) {}
        }
        handler.post(tick)
    }

    // ─── phone_location ───────────────────────────────────────────────────────

    private suspend fun phoneLocation(): BridgeResult {
        val hasFine   = hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
        val hasCoarse = hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
        if (!hasFine && !hasCoarse)
            return BridgeResult(false, "permission_denied", "Location permission not granted")

        val loc = bestLastLocation()
            ?: return BridgeResult(false, "unavailable", "Location not available")

        val latStr = "%.4f".format(loc.latitude)
        val lonStr = "%.4f".format(loc.longitude)
        val dir = if (loc.latitude >= 0) "N" else "S"
        val dirLon = if (loc.longitude >= 0) "E" else "W"
        val msg = "${Math.abs(loc.latitude.toFloat())}°$dir, ${Math.abs(loc.longitude.toFloat())}°$dirLon"
        return BridgeResult(true, null, "$latStr°$dir, $lonStr°$dirLon")
    }

    private suspend fun bestLastLocation(): Location? = withContext(Dispatchers.IO) {
        // Try FusedLocationProviderClient first (best accuracy)
        val loc = suspendCancellableCoroutine<Location?> { cont ->
            try {
                val fused = LocationServices.getFusedLocationProviderClient(context)
                fused.lastLocation
                    .addOnSuccessListener { cont.resume(it) }
                    .addOnFailureListener { cont.resume(null) }
            } catch (_: Exception) {
                cont.resume(null)
            }
        }
        if (loc != null) return@withContext loc

        // Fallback: LocationManager
        try {
            val lm = context.getSystemService(LocationManager::class.java) ?: return@withContext null
            val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            providers.firstNotNullOfOrNull { p ->
                try { lm.getLastKnownLocation(p) } catch (_: Exception) { null }
            }
        } catch (_: Exception) { null }
    }

    // ─── start_navigation ─────────────────────────────────────────────────────

    private fun startNavigation(payload: JSONObject): BridgeResult {
        val destination = payload.optString("destination").ifBlank {
            return BridgeResult(false, "missing_param", "destination required")
        }
        return try {
            val geoUri = Uri.parse("google.navigation:q=${Uri.encode(destination)}&mode=d")
            val intent = Intent(Intent.ACTION_VIEW, geoUri)
                .setPackage("com.google.android.apps.maps")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (intent.resolveActivity(context.packageManager) != null) {
                context.startActivity(intent)
            } else {
                // Fallback: plain geo: URI without Maps constraint
                val fallback = Intent(Intent.ACTION_VIEW,
                    Uri.parse("geo:0,0?q=${Uri.encode(destination)}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(fallback)
            }
            BridgeResult(true, null, "Navigation started to $destination")
        } catch (e: Exception) {
            BridgeResult(false, "error", "Could not open navigation: ${e.message}")
        }
    }

    // ─── read_notifications ───────────────────────────────────────────────────

    private fun readNotifications(): BridgeResult {
        if (!JarvisNotificationListener.isGranted(context))
            return BridgeResult(false, "permission_denied",
                "Notification access not granted — enable in Settings → Notification Access")
        if (!JarvisNotificationListener.isConnected())
            return BridgeResult(false, "unavailable", "Notification listener not connected yet")

        val entries = JarvisNotificationListener.getRecent()
        val count = entries.size
        val text = if (count == 0) "No new notifications." else {
            val lines = entries.take(5).joinToString(". ") { e ->
                val app = e.packageName.substringAfterLast(".")
                val title = e.title.take(60).ifBlank { app }
                val body = e.text.take(100).ifBlank { "" }
                if (body.isBlank()) "$app: $title" else "$title — $body"
            }
            "You have $count notifications. $lines"
        }
        return BridgeResult(
            ok      = true,
            payload = JSONObject().apply {
                put("notificationCount", count)
                put("notificationText", text)
                put("notificationApp", JSONNull.instance)
            },
            message = text,
        )
    }

    // ─── query_notification ───────────────────────────────────────────────────

    private fun queryNotification(payload: JSONObject): BridgeResult {
        if (!JarvisNotificationListener.isGranted(context))
            return BridgeResult(false, "permission_denied",
                "Notification access not granted")

        val appFilter = payload.optString("app").ifBlank {
            return BridgeResult(false, "missing_param", "app required")
        }

        val entries = JarvisNotificationListener.getFromApp(appFilter)
            .ifEmpty {
                // Fuzzy: find any notification whose package contains the filter
                JarvisNotificationListener.getRecent().filter {
                    it.packageName.contains(appFilter, ignoreCase = true) ||
                    it.title.contains(appFilter, ignoreCase = true)
                }
            }

        val text = if (entries.isEmpty()) "No notifications from $appFilter." else {
            entries.take(3).joinToString(". ") { e ->
                val title = e.title.take(60).ifBlank { appFilter }
                val body  = e.text.take(100)
                if (body.isBlank()) title else "$title — $body"
            }
        }
        return BridgeResult(
            ok      = true,
            payload = JSONObject().apply {
                put("notificationCount", entries.size)
                put("notificationText", text)
                put("notificationApp", appFilter)
            },
            message = text,
        )
    }

    // ─── capture_camera ───────────────────────────────────────────────────────

    private suspend fun captureCamera(): BridgeResult {
        if (!hasPermission(Manifest.permission.CAMERA))
            return BridgeResult(false, "permission_denied", "CAMERA permission not granted")

        return withTimeoutOrNull(12_000L) {
            try {
                val manager = com.jarvis.assistant.camera.CameraCaptureManager(context)
                val result  = manager.capturePhoto(
                    androidx.camera.core.CameraSelector.LENS_FACING_BACK
                )
                when (result) {
                    is com.jarvis.assistant.camera.CaptureResult.Success ->
                        BridgeResult(true, null, "Camera captured: ${result.file.name}")
                    is com.jarvis.assistant.camera.CaptureResult.Failure ->
                        BridgeResult(false, "capture_failed", result.reason)
                }
            } catch (e: Exception) {
                BridgeResult(false, "error", "Camera capture failed: ${e.message}")
            }
        } ?: BridgeResult(false, "timeout", "Camera capture timed out")
    }

    // ─── get_capabilities ────────────────────────────────────────────────────

    private fun getCapabilities(cfg: MacBridgeConfig): BridgeResult {
        // Per spec: don't respond directly — the client will fire capabilities_report
        // The caller (MacBridgeClient) handles this specially — we return a sentinel
        // result that signals the client to send the event instead.
        return BridgeResult(
            ok      = true,
            status  = "capabilities_sent",
            payload = JSONObject().apply {
                put("capabilities",
                    JSONArray(cfg.enabledCapabilities.filter { it in MacBridgeCapability.ALL }))
            },
        )
    }

    // ─── speakerphone_on / speakerphone_off ──────────────────────────────────

    private fun setSpeakerphone(enable: Boolean): BridgeResult {
        val audioMgr = context.getSystemService(AudioManager::class.java)!!
        val inCall = audioMgr.mode == AudioManager.MODE_IN_CALL ||
                     audioMgr.mode == AudioManager.MODE_IN_COMMUNICATION
        if (!inCall) return BridgeResult(false, "no_active_call", "No active call in progress")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val type = if (enable) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                       else        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            val target = audioMgr.availableCommunicationDevices
                .firstOrNull { it.type == type }
            if (target != null) audioMgr.setCommunicationDevice(target)
        } else {
            @Suppress("DEPRECATION")
            audioMgr.isSpeakerphoneOn = enable
        }

        val route = when {
            audioMgr.isBluetoothA2dpOn  -> "bluetooth"
            audioMgr.isWiredHeadsetOn   -> "wired_headset"
            @Suppress("DEPRECATION")
            audioMgr.isSpeakerphoneOn   -> "speaker"
            else                         -> "earpiece"
        }
        Log.d(TAG, "setSpeakerphone: enable=$enable  route=$route")
        return BridgeResult(
            ok      = true,
            status  = "completed",
            payload = JSONObject().apply {
                put("audioRoute",         route)
                @Suppress("DEPRECATION")
                put("speakerEnabled",     audioMgr.isSpeakerphoneOn)
                put("bluetoothActive",    audioMgr.isBluetoothA2dpOn)
                put("wiredHeadsetActive", audioMgr.isWiredHeadsetOn)
            },
        )
    }

    // ─── whatsapp_voice_call / whatsapp_video_call ────────────────────────────

    private suspend fun whatsAppCall(payload: JSONObject, isVideo: Boolean): BridgeResult =
        withContext(Dispatchers.Main) {
            if (!isPackageInstalled("com.whatsapp")) {
                return@withContext BridgeResult(false, "whatsapp_not_installed",
                    "WhatsApp is not installed")
            }
            if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
                return@withContext BridgeResult(false, "permission_denied",
                    "READ_CONTACTS permission not granted")
            }

            val contactName = payload.optString("contact").ifBlank {
                return@withContext BridgeResult(false, "missing_param", "contact name required")
            }

            // Direct call by contactId (comes back from a needs_clarification response)
            val contactId = payload.optString("contactId").takeIf { it.isNotBlank() }
            val contact: ContactLookup.Contact? = if (contactId != null) {
                resolveById(contactId)
                    ?: return@withContext BridgeResult(false, "not_found",
                        "Contact ID $contactId not found")
            } else {
                contacts.find(contactName)
            }

            if (contact == null) {
                val ambiguous = contacts.lastAmbiguousMatches
                if (ambiguous.size in 2..4) {
                    val arr = JSONArray(ambiguous.map { c ->
                        JSONObject().apply {
                            put("id", c.name)
                            put("name", c.name)
                            put("phone", c.phoneNumber)
                        }
                    })
                    return@withContext BridgeResult(
                        ok      = false,
                        status  = "needs_clarification",
                        message = contacts.disambiguationPrompt(),
                        payload = JSONObject().apply { put("contacts", arr) },
                    )
                }
                return@withContext BridgeResult(false, "contact_not_found",
                    "No contact found for '$contactName'")
            }

            val mode   = if (isVideo) WhatsAppCallAdapter.Mode.VIDEO else WhatsAppCallAdapter.Mode.VOICE
            val result = WhatsAppCallAdapter(context).call(contact, mode)
            when (result) {
                is ToolResult.Success -> BridgeResult(
                    ok      = true,
                    status  = "calling",
                    payload = JSONObject().apply {
                        put("contact", contact.displayName)
                        put("type",    if (isVideo) "video" else "voice")
                    },
                )
                is ToolResult.Failure -> BridgeResult(false, "contact_not_found", result.spokenFeedback)
                else                  -> BridgeResult(false, "error", "Unexpected call result")
            }
        }

    // ─── reply_to_contact ─────────────────────────────────────────────────────

    private suspend fun replyToContact(payload: JSONObject): BridgeResult =
        withContext(Dispatchers.IO) {
            val contactName = payload.optString("contact").ifBlank {
                return@withContext BridgeResult(false, "missing_param", "contact required")
            }
            val message = payload.optString("message").ifBlank {
                return@withContext BridgeResult(false, "needs_body",
                    "What do you want to say to $contactName?")
            }

            val candidates = JarvisNotificationListener.getRecent().filter { it.canReply }
            if (candidates.isEmpty())
                return@withContext BridgeResult(false, "no_recent_message",
                    "No replyable messages in your notifications right now.")

            val matches = candidates.filter { e ->
                e.displaySender.contains(contactName, ignoreCase = true) ||
                e.title.contains(contactName, ignoreCase = true)
            }
            val entry: NotificationEntry = when {
                matches.size == 1 -> matches.first()
                matches.size > 1  -> {
                    return@withContext BridgeResult(
                        ok      = false,
                        status  = "contact_ambiguous",
                        message = "Multiple messages from contacts matching '$contactName'. Which one?",
                        payload = JSONObject().apply {
                            put("matches", JSONArray(matches.take(4).map { e ->
                                JSONObject().apply {
                                    put("sender", e.displaySender)
                                    put("app",    e.appName)
                                    put("key",    e.sbnKey)
                                }
                            }))
                        },
                    )
                }
                else -> return@withContext BridgeResult(false, "no_recent_message",
                    "No recent message from '$contactName' to reply to.")
            }

            sendBridgeReply(entry, message)
        }

    // ─── reply_last_message ───────────────────────────────────────────────────

    private suspend fun replyLastMessage(payload: JSONObject): BridgeResult =
        withContext(Dispatchers.IO) {
            val message = payload.optString("message").ifBlank {
                return@withContext BridgeResult(false, "needs_body",
                    "What do you want to reply?")
            }

            val entry = RecentMessageContext.getLastReplyable()
                ?: JarvisNotificationListener.getRecent()
                    .firstOrNull { it.canReply }
                ?: return@withContext BridgeResult(false, "no_recent_message",
                    "No replyable messages in your notifications right now.")

            sendBridgeReply(entry, message)
        }

    private fun sendBridgeReply(entry: NotificationEntry, message: String): BridgeResult {
        if (!entry.canReply)
            return BridgeResult(false, "inline_reply_unavailable",
                "This message can't be replied to inline.")
        return try {
            val intent = Intent()
            val bundle = Bundle()
            for (ri in entry.replyRemoteInputs) {
                bundle.putCharSequence(ri.resultKey, message)
            }
            RemoteInput.addResultsToIntent(entry.replyRemoteInputs.toTypedArray(), intent, bundle)
            entry.replyPendingIntent!!.send(context, 0, intent)
            Log.d(TAG, "Bridge reply sent to ${entry.displaySender} via ${entry.appName}")
            BridgeResult(
                ok      = true,
                status  = "sent",
                message = "Replied to ${entry.displaySender}.",
                payload = JSONObject().apply {
                    put("to",  entry.displaySender)
                    put("app", entry.appName)
                },
            )
        } catch (e: Exception) {
            Log.e(TAG, "Bridge reply failed", e)
            BridgeResult(false, "error", "Couldn't send the reply.")
        }
    }

    private fun isPackageInstalled(packageName: String): Boolean = try {
        context.packageManager.getPackageInfo(packageName, 0)
        true
    } catch (_: Exception) { false }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    private fun normalisePhone(raw: String): String {
        val digits = raw.filter { it.isDigit() || it == '+' }
        return if (digits.startsWith("+")) digits
        else if (digits.startsWith("0")) "+44" + digits.drop(1)
        else "+$digits"
    }
}

private object JSONNull {
    val instance: Any get() = JSONObject.NULL
}
