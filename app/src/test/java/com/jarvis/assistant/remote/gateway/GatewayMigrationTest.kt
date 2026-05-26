package com.jarvis.assistant.remote.gateway

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * GatewayMigrationTest — verifies the host extraction logic used when deriving
 * the gateway base URL from legacy Mac Bridge / Mac Brain settings.
 *
 * Only tests [GatewayMigration.extractHost] — the full migrateIfNeeded() flow
 * touches SharedPreferences and is covered by integration tests.
 */
class GatewayMigrationTest {

    // ── Happy paths ───────────────────────────────────────────────────────────

    @Test
    fun `extracts bare IP from http URL`() =
        assertEquals("192.168.1.50", GatewayMigration.extractHost("http://192.168.1.50:7474"))

    @Test
    fun `extracts Tailscale IP from https URL`() =
        assertEquals("100.91.42.7", GatewayMigration.extractHost("https://100.91.42.7:7474"))

    @Test
    fun `extracts hostname from URL with path`() =
        assertEquals("brain.local", GatewayMigration.extractHost("http://brain.local:7474/brain/context"))

    @Test
    fun `extracts hostname from URL without port`() =
        assertEquals("brain.local", GatewayMigration.extractHost("http://brain.local/brain/context"))

    @Test
    fun `scheme casing does not affect result`() =
        assertEquals("192.168.1.50", GatewayMigration.extractHost("HTTP://192.168.1.50:7474"))

    // ── Edge cases / error paths ──────────────────────────────────────────────

    @Test
    fun `blank URL returns null`() =
        assertNull(GatewayMigration.extractHost(""))

    @Test
    fun `URL with only scheme and colon-slash-slash returns null`() =
        assertNull(GatewayMigration.extractHost("http://"))

    @Test
    fun `bare hostname without scheme extracts correctly (no protocol prefix)`() {
        // When user has stored just a hostname/IP (no scheme), extractHost
        // treats the whole string as host:port and returns everything before ":"
        val result = GatewayMigration.extractHost("192.168.1.50:7474")
        // No "://" found so substringAfter("://") returns the full string;
        // the host is "192.168.1.50" (before ":") — acceptable fallback.
        assertEquals("192.168.1.50", result)
    }
}
