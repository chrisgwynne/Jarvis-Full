package com.jarvis.assistant.remote.macbridge

import com.jarvis.assistant.util.SettingsStore

class MacBridgeSettingsRepository(private val store: SettingsStore) {

    fun snapshot(): MacBridgeConfig {
        val rawCaps = store.macBridgeCapabilities
        val enabledCaps = if (rawCaps.isBlank()) {
            MacBridgeCapability.ALL
        } else {
            rawCaps.split(",").map { it.trim() }.toSet()
        }
        val roleRaw = store.macBridgeAndroidRole
        val role = runCatching { AndroidRole.valueOf(roleRaw) }
            .getOrDefault(AndroidRole.FULL_ASSISTANT)
        return MacBridgeConfig(
            enabled             = store.macBridgeEnabled,
            host                = store.macBridgeHost,
            port                = store.macBridgePort,
            authToken           = store.macBridgeAuthToken,
            enabledCapabilities = enabledCaps,
            eventsEnabled       = store.macBridgeEventsEnabled,
            eventsCalls         = store.macBridgeEventsCalls,
            eventsSms           = store.macBridgeEventsSms,
            eventsWhatsApp      = store.macBridgeEventsWhatsApp,
            eventsNotifications = store.macBridgeEventsNotifications,
            eventsBattery       = store.macBridgeEventsBattery,
            shareCallerNames    = store.macBridgeShareCallerNames,
            shareMsgPreviews    = store.macBridgeShareMsgPreviews,
            androidRole         = role,
        )
    }

    fun save(config: MacBridgeConfig) {
        store.macBridgeEnabled      = config.enabled
        store.macBridgeHost         = config.host
        store.macBridgePort         = config.port
        store.macBridgeAuthToken    = config.authToken
        store.macBridgeCapabilities = config.enabledCapabilities.joinToString(",")
        store.macBridgeEventsEnabled       = config.eventsEnabled
        store.macBridgeEventsCalls         = config.eventsCalls
        store.macBridgeEventsSms           = config.eventsSms
        store.macBridgeEventsWhatsApp      = config.eventsWhatsApp
        store.macBridgeEventsNotifications = config.eventsNotifications
        store.macBridgeEventsBattery       = config.eventsBattery
        store.macBridgeShareCallerNames    = config.shareCallerNames
        store.macBridgeShareMsgPreviews    = config.shareMsgPreviews
        store.macBridgeAndroidRole         = config.androidRole.name
    }

    fun setEnabled(enabled: Boolean) { store.macBridgeEnabled = enabled }
    fun setCapabilities(caps: Set<String>) { store.macBridgeCapabilities = caps.joinToString(",") }

    /** Clears host and auth token and disables the bridge — call on explicit unpair. */
    fun clearPairing() {
        store.macBridgeEnabled   = false
        store.macBridgeHost      = ""
        store.macBridgeAuthToken = ""
    }
}
