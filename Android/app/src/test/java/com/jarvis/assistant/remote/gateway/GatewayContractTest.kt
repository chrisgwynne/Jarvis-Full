package com.jarvis.assistant.remote.gateway

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * GatewayContractTest — unit tests for the Brain Gateway contract layer:
 *   • URL derivation (http→ws, https→wss, trailing-slash tolerance)
 *   • isPaired guard (requires paired flag + non-blank token + non-blank base URL)
 *   • Security: session token never appears in BrainGatewayConfig.toString()
 *   • Security: session token never appears in PairResult.Success.toString()
 *   • HTTP client URL validation
 *
 * All tests run without an Android context — pure Kotlin/JVM.
 */
class GatewayContractTest {

    // ── wsUrl derivation ──────────────────────────────────────────────────────

    @Test
    fun `http base URL derives ws websocket URL`() {
        val cfg = cfg("http://100.91.42.7:8765")
        assertEquals("ws://100.91.42.7:8765/v1/android/ws", cfg.wsUrl)
    }

    @Test
    fun `https base URL derives wss websocket URL`() {
        val cfg = cfg("https://jarvis.ts.net:8765")
        assertEquals("wss://jarvis.ts.net:8765/v1/android/ws", cfg.wsUrl)
    }

    @Test
    fun `trailing slash on base URL is stripped before appending ws path`() {
        val cfg = cfg("http://192.168.1.50:8765/")
        assertEquals("ws://192.168.1.50:8765/v1/android/ws", cfg.wsUrl)
    }

    @Test
    fun `healthUrl appended correctly`() {
        val cfg = cfg("http://192.168.1.50:8765")
        assertEquals("http://192.168.1.50:8765/health", cfg.healthUrl)
    }

    @Test
    fun `pairUrl appended correctly`() {
        val cfg = cfg("http://192.168.1.50:8765")
        assertEquals("http://192.168.1.50:8765/v1/android/pair", cfg.pairUrl)
    }

    @Test
    fun `chatUrl appended correctly`() {
        val cfg = cfg("http://192.168.1.50:8765")
        assertEquals("http://192.168.1.50:8765/v1/chat", cfg.chatUrl)
    }

    @Test
    fun `trailing slash on https base URL is stripped`() {
        val cfg = cfg("https://jarvis.ts.net:8765/")
        assertEquals("wss://jarvis.ts.net:8765/v1/android/ws", cfg.wsUrl)
    }

    // ── isPaired guard ────────────────────────────────────────────────────────

    @Test
    fun `isPaired true when all three fields set`() {
        val cfg = pairedCfg()
        assertTrue(cfg.isPaired)
    }

    @Test
    fun `isPaired false when paired flag is false`() {
        val cfg = pairedCfg().copy(paired = false)
        assertFalse(cfg.isPaired)
    }

    @Test
    fun `isPaired false when session token is null`() {
        val cfg = pairedCfg().copy(sessionToken = null)
        assertFalse(cfg.isPaired)
    }

    @Test
    fun `isPaired false when session token is blank`() {
        val cfg = pairedCfg().copy(sessionToken = "")
        assertFalse(cfg.isPaired)
    }

    @Test
    fun `isPaired false when base URL is blank`() {
        val cfg = pairedCfg().copy(baseUrl = "")
        assertFalse(cfg.isPaired)
    }

    // ── Security: toString() redaction ────────────────────────────────────────

    @Test
    fun `BrainGatewayConfig toString does not expose session token value`() {
        val token = "secret-session-token-abc123"
        val cfg   = pairedCfg().copy(sessionToken = token)
        assertFalse(
            "toString() must not include the raw token value",
            cfg.toString().contains(token)
        )
    }

    @Test
    fun `BrainGatewayConfig toString shows REDACTED placeholder when token set`() {
        val cfg = pairedCfg().copy(sessionToken = "some-token")
        assertTrue(cfg.toString().contains("[REDACTED]"))
    }

    @Test
    fun `BrainGatewayConfig toString shows null when token is null`() {
        val cfg = pairedCfg().copy(sessionToken = null)
        assertTrue(cfg.toString().contains("null"))
        assertFalse(cfg.toString().contains("[REDACTED]"))
    }

    @Test
    fun `PairResult_Success toString does not expose session token value`() {
        val token  = "super-secret-pairing-token-xyz"
        val result = PairResult.Success(
            sessionToken   = token,
            macDeviceName  = "MacBook Pro",
            serverVersion  = "1.0.0",
        )
        assertFalse(
            "PairResult.Success.toString() must not include the raw token value",
            result.toString().contains(token)
        )
    }

    @Test
    fun `PairResult_Success toString shows REDACTED placeholder`() {
        val result = PairResult.Success("any-token", "Mac", "1.0")
        assertTrue(result.toString().contains("[REDACTED]"))
    }

    // ── BrainGatewayHttpClient URL validation ─────────────────────────────────

    @Test
    fun `http URL is valid for gateway`() =
        assertTrue(BrainGatewayHttpClient.isValidBaseUrl("http://192.168.1.100:8765"))

    @Test
    fun `https URL is valid for gateway`() =
        assertTrue(BrainGatewayHttpClient.isValidBaseUrl("https://100.91.42.7:8765"))

    @Test
    fun `HTTP uppercase scheme is accepted`() =
        assertTrue(BrainGatewayHttpClient.isValidBaseUrl("HTTP://192.168.1.100:8765"))

    @Test
    fun `blank URL is rejected`() =
        assertFalse(BrainGatewayHttpClient.isValidBaseUrl(""))

    @Test
    fun `ws scheme is rejected (not http)`() =
        assertFalse(BrainGatewayHttpClient.isValidBaseUrl("ws://192.168.1.100:8765"))

    @Test
    fun `bare hostname without scheme is rejected`() =
        assertFalse(BrainGatewayHttpClient.isValidBaseUrl("192.168.1.100:8765"))

    @Test
    fun `relative path is rejected`() =
        assertFalse(BrainGatewayHttpClient.isValidBaseUrl("/v1/chat"))

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun cfg(baseUrl: String) = BrainGatewayConfig(baseUrl = baseUrl)

    private fun pairedCfg() = BrainGatewayConfig(
        baseUrl      = "http://100.91.42.7:8765",
        sessionToken = "tok-abc123",
        paired       = true,
    )
}
