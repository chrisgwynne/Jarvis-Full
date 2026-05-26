package com.jarvis.assistant.remote.brain

data class MacBrainConfig(
    val macIpAddress: String = "",
    val deviceId: String = "",
    val deviceName: String = "",
    val deviceToken: String? = null,
    val paired: Boolean = false,
    val lastConnectedAt: Long? = null,
    val lastSeenMacAt: Long? = null,
) {
    val isPaired: Boolean get() = paired && !deviceToken.isNullOrBlank() && macIpAddress.isNotBlank()
    val baseUrl: String get() = if (macIpAddress.isBlank()) "" else "http://$macIpAddress:8765"
    val wsUrl: String get() = if (macIpAddress.isBlank()) "" else "ws://$macIpAddress:8765/v1/android/ws"
    val healthUrl: String get() = "$baseUrl/health"
    val pairUrl: String get() = "$baseUrl/v1/android/pair"
    val chatUrl: String get() = "$baseUrl/v1/chat"
    val interactionsUrl: String get() = "$baseUrl/v1/interactions"
    override fun toString() = "MacBrainConfig(macIpAddress=$macIpAddress, deviceId=$deviceId, paired=$paired, deviceToken=${if (deviceToken != null) "[REDACTED]" else "null"})"
}
