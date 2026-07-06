package com.jarvis.assistant.federation

data class FederationConfig(
    val enabled: Boolean = false,
    val deviceId: String = "",          // filled at runtime from ANDROID_ID
    val deviceName: String = "Android", // human label
    val lanHost: String = "",           // e.g. "jarvis-mac.local"
    val lanPort: Int = 8765,
    val tailscaleHost: String = "",     // e.g. "100.x.y.z"
    val useTailscale: Boolean = false,
    val authToken: String = "",
    val reconnectBaseDelayMs: Long = 2_000L,
    val reconnectMaxDelayMs: Long = 60_000L,
    val heartbeatIntervalMs: Long = 30_000L,
    val queueMaxSize: Int = 200,
    val queueFlushTimeoutMs: Long = 5_000L,
    // When true, connect over ws:// instead of wss://. Only enable if the Mac
    // daemon is not serving TLS. A warning is shown in Settings when this is on.
    val usePlaintextLan: Boolean = false,
)

enum class ConnectionPreference { LAN_FIRST, TAILSCALE_FIRST, LAN_ONLY, TAILSCALE_ONLY }
