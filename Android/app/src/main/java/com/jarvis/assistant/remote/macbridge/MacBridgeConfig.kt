package com.jarvis.assistant.remote.macbridge

data class MacBridgeConfig(
    val enabled: Boolean = false,
    val host: String = "",
    val port: Int = 17872,
    val authToken: String = "",
    val enabledCapabilities: Set<String> = MacBridgeCapability.ALL,
    // Event broadcasting — Android → Mac proactive events
    val eventsEnabled: Boolean = true,
    val eventsCalls: Boolean = true,
    val eventsSms: Boolean = true,
    val eventsWhatsApp: Boolean = true,
    val eventsNotifications: Boolean = false,
    val eventsBattery: Boolean = true,
    // Privacy
    val shareCallerNames: Boolean = true,
    val shareMsgPreviews: Boolean = true,
    // Role — controls whether Android listens/speaks or acts as silent bridge executor
    val androidRole: AndroidRole = AndroidRole.FULL_ASSISTANT,
) {
    val isConfigured: Boolean get() = host.isNotBlank() && authToken.isNotBlank()
    val wsUrl: String get() = "ws://$host:$port"
}
