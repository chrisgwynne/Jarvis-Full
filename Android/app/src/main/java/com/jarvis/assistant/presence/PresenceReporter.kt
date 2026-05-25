package com.jarvis.assistant.presence

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.media.AudioManager
import android.os.BatteryManager
import android.content.Intent
import android.content.IntentFilter
import android.app.KeyguardManager
import com.jarvis.assistant.remote.gateway.BrainGatewayWebSocketClient
import org.json.JSONObject
import java.util.UUID
import java.time.Instant

object PresenceReporter {

    fun sendUpdate(context: Context, gateway: BrainGatewayWebSocketClient, isAppForeground: Boolean) {
        val batteryIntent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val batteryPct = if (level >= 0 && scale > 0) (level * 100 / scale) else -1
        val plugged = batteryIntent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val isCharging = plugged != 0

        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val hasWiredHeadset = audioManager.isWiredHeadsetOn
        val hasBtHeadset = isBtA2dpConnected()
        val hasHeadset = hasWiredHeadset || hasBtHeadset

        val km = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val isScreenLocked = km.isKeyguardLocked

        val payload = JSONObject().apply {
            put("batteryPercent", batteryPct)
            put("isCharging", isCharging)
            put("hasHeadset", hasHeadset)
            put("isScreenLocked", isScreenLocked)
            put("isAppForeground", isAppForeground)
            put("activityState", if (isScreenLocked) "locked" else "active")
        }

        val envelope = JSONObject().apply {
            put("id", UUID.randomUUID().toString())
            put("type", "presence.update")
            put("sourceDeviceId", gateway.deviceId ?: "android")
            put("sourcePlatform", "android")
            put("target", JSONObject().put("type", "daemon"))
            put("timestamp", Instant.now().toString())
            put("payload", payload)
        }
        gateway.sendTypedFrame(envelope)
    }

    private fun isBtA2dpConnected(): Boolean {
        return try {
            val adapter = BluetoothAdapter.getDefaultAdapter() ?: return false
            adapter.getProfileConnectionState(BluetoothProfile.A2DP) == BluetoothProfile.STATE_CONNECTED
        } catch (e: SecurityException) {
            false
        }
    }
}
