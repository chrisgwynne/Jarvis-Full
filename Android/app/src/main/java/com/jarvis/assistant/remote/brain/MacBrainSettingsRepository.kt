package com.jarvis.assistant.remote.brain

import com.jarvis.assistant.util.SettingsStore
import java.util.UUID

class MacBrainSettingsRepository(private val store: SettingsStore) {

    fun snapshot(): MacBrainConfig {
        // gatewayBaseUrl may store a bare IP ("192.168.1.5") or a full URL
        // ("http://192.168.1.5:8765"). Strip protocol + port when loading so
        // MacBrainConfig.baseUrl always adds them via its getter.
        val raw = store.gatewayBaseUrl
        val macIp = raw
            .removePrefix("http://")
            .removePrefix("https://")
            .removeSuffix(":8765")
            .trim()
        return MacBrainConfig(
            macIpAddress    = macIp,
            deviceId        = store.gatewayDeviceId.ifBlank { ensureDeviceId() },
            deviceName      = store.gatewayDeviceName,
            deviceToken     = store.gatewaySessionToken.ifBlank { null },
            paired          = store.gatewayPaired,
            lastConnectedAt = store.gatewayLastConnectedAt.takeIf { it > 0 },
            lastSeenMacAt   = store.gatewayLastSeenMacAt.takeIf { it > 0 },
        )
    }

    fun save(config: MacBrainConfig) {
        store.gatewayBaseUrl         = config.macIpAddress
        store.gatewayDeviceId        = config.deviceId
        store.gatewayDeviceName      = config.deviceName
        store.gatewaySessionToken    = config.deviceToken ?: ""
        store.gatewayPaired          = config.paired
        store.gatewayLastConnectedAt = config.lastConnectedAt ?: 0L
        store.gatewayLastSeenMacAt   = config.lastSeenMacAt ?: 0L
    }

    /**
     * Called after a successful pairing handshake.
     * [macIpAddress] is the bare IP/hostname (e.g. "192.168.1.5").
     */
    fun savePaired(deviceToken: String, macIpAddress: String) {
        store.gatewaySessionToken    = deviceToken
        store.gatewayPaired          = true
        store.gatewayBaseUrl         = macIpAddress
        store.gatewayLastConnectedAt = System.currentTimeMillis()
    }

    fun clearPairing() {
        store.gatewaySessionToken = ""
        store.gatewayPaired       = false
    }

    fun clearAll() {
        store.gatewayBaseUrl         = ""
        store.gatewaySessionToken    = ""
        store.gatewayPaired          = false
        store.gatewayLastConnectedAt = 0L
        store.gatewayLastSeenMacAt   = 0L
    }

    fun recordConnected() {
        store.gatewayLastConnectedAt = System.currentTimeMillis()
    }

    fun recordMacSeen() {
        store.gatewayLastSeenMacAt = System.currentTimeMillis()
    }

    fun stableDeviceId(): String = store.gatewayDeviceId.ifBlank { ensureDeviceId() }

    private fun ensureDeviceId(): String {
        val id = UUID.randomUUID().toString()
        store.gatewayDeviceId = id
        return id
    }
}
