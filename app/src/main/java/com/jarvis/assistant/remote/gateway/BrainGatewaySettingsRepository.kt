package com.jarvis.assistant.remote.gateway

import com.jarvis.assistant.util.SettingsStore
import java.util.UUID

class BrainGatewaySettingsRepository(private val store: SettingsStore) {

    fun snapshot(): BrainGatewayConfig {
        val modeRaw = store.gatewayTransportMode
        val mode = runCatching { TransportMode.valueOf(modeRaw) }
            .getOrDefault(TransportMode.Auto)
        return BrainGatewayConfig(
            baseUrl         = store.gatewayBaseUrl,
            deviceId        = store.gatewayDeviceId.ifBlank { ensureDeviceId() },
            deviceName      = store.gatewayDeviceName,
            sessionToken    = store.gatewaySessionToken.ifBlank { null },
            paired          = store.gatewayPaired,
            lastConnectedAt = store.gatewayLastConnectedAt.takeIf { it > 0 },
            lastSeenMacAt   = store.gatewayLastSeenMacAt.takeIf { it > 0 },
            transportMode   = mode,
        )
    }

    fun save(config: BrainGatewayConfig) {
        store.gatewayBaseUrl         = config.baseUrl
        store.gatewayDeviceId        = config.deviceId
        store.gatewayDeviceName      = config.deviceName
        store.gatewaySessionToken    = config.sessionToken ?: ""
        store.gatewayPaired          = config.paired
        store.gatewayLastConnectedAt = config.lastConnectedAt ?: 0L
        store.gatewayLastSeenMacAt   = config.lastSeenMacAt ?: 0L
        store.gatewayTransportMode   = config.transportMode.name
    }

    fun savePaired(sessionToken: String, baseUrl: String) {
        store.gatewaySessionToken    = sessionToken
        store.gatewayPaired          = true
        store.gatewayBaseUrl         = baseUrl
        store.gatewayLastConnectedAt = System.currentTimeMillis()
    }

    fun recordMacSeen() {
        store.gatewayLastSeenMacAt = System.currentTimeMillis()
    }

    fun recordConnected() {
        store.gatewayLastConnectedAt = System.currentTimeMillis()
    }

    // ── Migration diagnostics ─────────────────────────────────────────────────

    /** Source that populated the base URL: "bridge" | "brain" | "none" | "" (not yet run). */
    val migratedFrom: String get() = store.gatewayMigratedFrom

    /** Epoch-ms when migration ran; 0 if not yet. */
    val migrationAt: Long get() = store.gatewayMigrationAt

    // ── Mutation helpers ──────────────────────────────────────────────────────

    /** Clears pairing state — requires re-pairing on next connection attempt. */
    fun clearPairing() {
        store.gatewaySessionToken = ""
        store.gatewayPaired       = false
    }

    /** Clears everything including the base URL — full factory reset. */
    fun clearAll() {
        store.gatewayBaseUrl         = ""
        store.gatewaySessionToken    = ""
        store.gatewayPaired          = false
        store.gatewayLastConnectedAt = 0L
        store.gatewayLastSeenMacAt   = 0L
    }

    /** Returns the stable device UUID, generating one if none has been persisted yet. */
    fun stableDeviceId(): String = store.gatewayDeviceId.ifBlank { ensureDeviceId() }

    private fun ensureDeviceId(): String {
        val id = UUID.randomUUID().toString()
        store.gatewayDeviceId = id
        return id
    }
}
