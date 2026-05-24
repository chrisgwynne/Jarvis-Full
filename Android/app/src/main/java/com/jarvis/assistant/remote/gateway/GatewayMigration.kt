package com.jarvis.assistant.remote.gateway

import android.util.Log
import com.jarvis.assistant.util.SettingsStore

/**
 * One-shot migration that derives the Brain Gateway base URL from existing
 * legacy settings (Mac Bridge host / Mac Brain URL) so users upgrading from
 * the pre-gateway build see a pre-populated URL in the new Gateway settings
 * screen without having to re-configure anything manually.
 *
 * Migration is idempotent: if [SettingsStore.gatewayBaseUrl] is already set,
 * or if [SettingsStore.gatewayMigratedFrom] records a prior run (even "none"),
 * the function returns immediately without touching any key.
 *
 * What is migrated:
 *   - Gateway base URL — derived from Bridge host or Brain URL (see below)
 *   - Device ID — reused from [macBrainDeviceId] so the Mac identifies the
 *     same device across the upgrade
 *
 * What is NOT migrated:
 *   - The Bridge auth token — it is a per-frame credential, not a session
 *     token.  The user must complete a QR pairing to get a gateway session
 *     token.
 *   - The Brain API key — same reason.
 *   - Pairing state — the device is not considered paired until a real
 *     /v1/android/pair handshake completes.
 *
 * URL derivation priority:
 *   1. [macBridgeHost] + DEFAULT_GATEWAY_PORT — best signal; most users who
 *      have Bridge configured have a precise Tailscale IP here.
 *   2. Host extracted from [macBrainBaseUrl] + DEFAULT_GATEWAY_PORT — fallback
 *      for users who had Brain but not Bridge.
 *   3. Nothing to migrate — first install, no prior legacy settings.
 */
object GatewayMigration {

    private const val TAG = "GatewayMigration"

    fun migrateIfNeeded(store: SettingsStore): MigrationResult {
        // Already migrated (URL is set) or migration was already recorded
        if (store.gatewayBaseUrl.isNotBlank()) {
            Log.d(TAG, "skip — gateway URL already set")
            return MigrationResult.AlreadyMigrated
        }
        if (store.gatewayMigratedFrom.isNotBlank()) {
            Log.d(TAG, "skip — migration already ran (source=${store.gatewayMigratedFrom})")
            return MigrationResult.AlreadyMigrated
        }

        val now = System.currentTimeMillis()

        // ── Priority 1: Mac Bridge host ───────────────────────────────────────
        val bridgeHost = store.macBridgeHost.trim()
        if (bridgeHost.isNotBlank()) {
            val url = "http://$bridgeHost:${SettingsStore.DEFAULT_GATEWAY_PORT}"
            store.gatewayBaseUrl      = url
            store.gatewayMigratedFrom = "bridge"
            store.gatewayMigrationAt  = now
            ensureDeviceId(store)
            Log.i(TAG, "[GATEWAY_MIGRATED] source=bridge url=$url")
            return MigrationResult.MigratedFromBridge(url)
        }

        // ── Priority 2: Mac Brain base URL ────────────────────────────────────
        val brainUrl = store.macBrainBaseUrl.trim()
        if (brainUrl.isNotBlank()) {
            val host = extractHost(brainUrl)
            if (host != null) {
                val url = "http://$host:${SettingsStore.DEFAULT_GATEWAY_PORT}"
                store.gatewayBaseUrl      = url
                store.gatewayMigratedFrom = "brain"
                store.gatewayMigrationAt  = now
                ensureDeviceId(store)
                Log.i(TAG, "[GATEWAY_MIGRATED] source=brain url=$url")
                return MigrationResult.MigratedFromBrain(url)
            }
        }

        // ── Nothing to migrate ────────────────────────────────────────────────
        store.gatewayMigratedFrom = "none"
        store.gatewayMigrationAt  = now
        ensureDeviceId(store)
        Log.d(TAG, "[GATEWAY_MIGRATED] source=none (first install)")
        return MigrationResult.NothingToMigrate
    }

    /**
     * Extract just the hostname from a URL like "http://100.91.42.7:7474/path".
     * Returns null if parsing fails or the host is blank.
     */
    internal fun extractHost(url: String): String? {
        return runCatching {
            val withoutScheme = url.substringAfter("://").ifBlank { return null }
            val withoutPath   = withoutScheme.substringBefore("/")
            val host          = withoutPath.substringBefore(":")   // strip port
            host.ifBlank { null }
        }.getOrNull()
    }

    /** Copy macBrainDeviceId → gatewayDeviceId if gateway doesn't have one yet. */
    private fun ensureDeviceId(store: SettingsStore) {
        if (store.gatewayDeviceId.isBlank()) {
            val legacyId = store.macBrainDeviceId  // generates UUID if blank
            store.gatewayDeviceId = legacyId
        }
    }
}

sealed class MigrationResult {
    /** [gatewayBaseUrl] was already set or migration had already run — nothing changed. */
    object AlreadyMigrated : MigrationResult()

    /** URL derived from [macBridgeHost]. */
    data class MigratedFromBridge(val derivedUrl: String) : MigrationResult()

    /** URL derived from host portion of [macBrainBaseUrl]. */
    data class MigratedFromBrain(val derivedUrl: String) : MigrationResult()

    /** No legacy data found — first install or clean state. */
    object NothingToMigrate : MigrationResult()
}
