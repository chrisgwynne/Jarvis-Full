package com.jarvis.assistant.remote.gateway

/**
 * Unified config for the Mac Brain Gateway — the single connection point
 * that replaces the separate Mac Bridge (WebSocket port 17872) and
 * Mac Brain (HTTP + separate port) connections.
 *
 * [baseUrl] is the only user-facing field. All derived URLs are computed
 * from it so the user never has to know about WebSocket paths or ports.
 *
 * Default gateway port: 8765.
 */
data class BrainGatewayConfig(
    val baseUrl: String = "",
    val deviceId: String = "",
    val deviceName: String = "",
    val sessionToken: String? = null,
    val paired: Boolean = false,
    val lastConnectedAt: Long? = null,
    val lastSeenMacAt: Long? = null,
    val transportMode: TransportMode = TransportMode.Auto,
) {

    val isPaired: Boolean get() = paired && !sessionToken.isNullOrBlank() && baseUrl.isNotBlank()

    // ── Derived URLs ──────────────────────────────────────────────────────────

    /**
     * WebSocket URL for the Android command channel.
     * http://host:port → ws://host:port/v1/android/ws
     * https://host:port → wss://host:port/v1/android/ws
     */
    val wsUrl: String get() = baseUrl
        .trimEnd('/')
        .replaceFirst("https://", "wss://")
        .replaceFirst("http://", "ws://")
        .plus("/v1/android/ws")

    /** Health check endpoint — no auth required. */
    val healthUrl: String get() = "${baseUrl.trimEnd('/')}/health"

    /** Pairing endpoint — POST with pairingCode, returns sessionToken. */
    val pairUrl: String get() = "${baseUrl.trimEnd('/')}/v1/android/pair"

    /** Status / heartbeat endpoint. */
    val statusUrl: String get() = "${baseUrl.trimEnd('/')}/v1/status"

    /** Chat / context endpoint (replaces /brain/context). */
    val chatUrl: String get() = "${baseUrl.trimEnd('/')}/v1/chat"

    /** Tool dispatch endpoint. */
    val toolsUrl: String get() = "${baseUrl.trimEnd('/')}/v1/tools"

    /** Device registry endpoint. */
    val devicesUrl: String get() = "${baseUrl.trimEnd('/')}/v1/devices"

    // Prevent accidental token exposure via Log.d("...", "cfg=$cfg") or similar.
    override fun toString(): String =
        "BrainGatewayConfig(baseUrl=$baseUrl, deviceId=$deviceId, deviceName=$deviceName, " +
        "sessionToken=${if (sessionToken != null) "[REDACTED]" else "null"}, " +
        "paired=$paired, transportMode=$transportMode)"
}

enum class TransportMode { Auto, Tailscale, LocalNetwork }
