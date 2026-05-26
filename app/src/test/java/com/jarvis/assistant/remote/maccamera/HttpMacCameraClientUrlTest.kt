package com.jarvis.assistant.remote.maccamera

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [HttpMacCameraClient] URL resolution logic.
 *
 * [HttpMacCameraClient.buildBaseUrl] is extracted as an internal companion
 * function so it can be exercised without a SettingsStore (which requires
 * Android EncryptedSharedPreferences) or a live HTTP server.
 *
 * NOT covered here (require MockWebServer or Android framework):
 *   - Health check success / HTTP 200 parsing
 *   - Health check timeout
 *   - Authorization header presence and value
 *   - Snapshot byte decoding
 */
class HttpMacCameraClientUrlTest {

    // ── Bridge-creds mode ────────────────────────────────────────────────────

    @Test
    fun `bridge mode with host uses bridge host and default camera port`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = true,
            bridgeHost     = "100.91.42.7",
            cameraPort     = 0,
            customBaseUrl  = "",
        )
        assertEquals("http://100.91.42.7:7474", base)
    }

    @Test
    fun `bridge mode with explicit port uses that port`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = true,
            bridgeHost     = "100.91.42.7",
            cameraPort     = 9000,
            customBaseUrl  = "",
        )
        assertEquals("http://100.91.42.7:9000", base)
    }

    @Test
    fun `bridge mode with no host returns empty — camera not configured`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = true,
            bridgeHost     = "",
            cameraPort     = 7474,
            customBaseUrl  = "",
        )
        assertEquals("", base)
    }

    @Test
    fun `bridge mode with whitespace-only host returns empty`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = true,
            bridgeHost     = "   ",
            cameraPort     = 7474,
            customBaseUrl  = "",
        )
        assertEquals("", base)
    }

    @Test
    fun `bridge mode zero port falls back to default 7474`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = true,
            bridgeHost     = "10.0.0.1",
            cameraPort     = 0,
            customBaseUrl  = "",
        )
        assertEquals("http://10.0.0.1:${HttpMacCameraClient.DEFAULT_CAMERA_PORT}", base)
    }

    // ── Custom URL mode ──────────────────────────────────────────────────────

    @Test
    fun `custom URL mode uses the provided base URL`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = false,
            bridgeHost     = "",
            cameraPort     = 0,
            customBaseUrl  = "http://192.168.1.10:7474",
        )
        assertEquals("http://192.168.1.10:7474", base)
    }

    @Test
    fun `custom URL trailing slash is stripped`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = false,
            bridgeHost     = "",
            cameraPort     = 0,
            customBaseUrl  = "http://192.168.1.10:7474/",
        )
        assertEquals("http://192.168.1.10:7474", base)
    }

    @Test
    fun `custom URL blank returns empty — camera not configured`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = false,
            bridgeHost     = "",
            cameraPort     = 0,
            customBaseUrl  = "",
        )
        assertEquals("", base)
    }

    @Test
    fun `custom URL ignores bridgeHost even when provided`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = false,
            bridgeHost     = "should-be-ignored.example.com",
            cameraPort     = 17872,
            customBaseUrl  = "http://custom.host:7474",
        )
        assertEquals("http://custom.host:7474", base)
    }

    // ── Stream URL derivation ────────────────────────────────────────────────

    @Test
    fun `stream URL appends camera stream path to base`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = true,
            bridgeHost     = "10.0.0.1",
            cameraPort     = 7474,
            customBaseUrl  = "",
        )
        assertEquals("http://10.0.0.1:7474/camera/stream", "$base/camera/stream")
    }

    @Test
    fun `stream URL is empty when base is empty`() {
        val base = HttpMacCameraClient.buildBaseUrl(
            useBridgeCreds = true,
            bridgeHost     = "",
            cameraPort     = 0,
            customBaseUrl  = "",
        )
        val streamUrl = if (base.isBlank()) "" else "$base/camera/stream"
        assertEquals("", streamUrl)
    }

    @Test
    fun `DEFAULT_CAMERA_PORT constant is 7474`() {
        assertEquals(7474, HttpMacCameraClient.DEFAULT_CAMERA_PORT)
    }
}
