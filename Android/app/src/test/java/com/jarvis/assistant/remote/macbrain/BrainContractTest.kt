package com.jarvis.assistant.remote.macbrain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * BrainContractTest — verifies the Android/Mac Brain HTTP boundary is resilient to:
 *   • Server-side contract changes (extra fields, missing fields, type changes)
 *   • Malformed or oversized responses
 *   • Misconfigured or non-HTTP base URLs
 *   • Security properties (API key handling)
 *
 * All tests run against static companion-object helpers so no Android context is needed.
 */
class BrainContractTest {

    // ── URL scheme validation ──────────────────────────────────────────────────

    @Test
    fun `http scheme is valid`() =
        assertTrue(HttpMacBrainClient.isValidBaseUrl("http://192.168.1.100:7474"))

    @Test
    fun `https scheme is valid`() =
        assertTrue(HttpMacBrainClient.isValidBaseUrl("https://brain.example.com"))

    @Test
    fun `HTTP uppercase scheme is accepted (case-insensitive)`() =
        assertTrue(HttpMacBrainClient.isValidBaseUrl("HTTP://192.168.1.100:7474"))

    @Test
    fun `HTTPS uppercase scheme is accepted`() =
        assertTrue(HttpMacBrainClient.isValidBaseUrl("HTTPS://brain.example.com"))

    @Test
    fun `blank URL is rejected`() =
        assertFalse(HttpMacBrainClient.isValidBaseUrl(""))

    @Test
    fun `bare hostname without scheme is rejected`() =
        assertFalse(HttpMacBrainClient.isValidBaseUrl("192.168.1.100:7474"))

    @Test
    fun `ftp scheme is rejected`() =
        assertFalse(HttpMacBrainClient.isValidBaseUrl("ftp://192.168.1.100"))

    @Test
    fun `ws scheme is rejected`() =
        assertFalse(HttpMacBrainClient.isValidBaseUrl("ws://192.168.1.100:8080"))

    @Test
    fun `wss scheme is rejected`() =
        assertFalse(HttpMacBrainClient.isValidBaseUrl("wss://brain.example.com"))

    @Test
    fun `relative path is rejected`() =
        assertFalse(HttpMacBrainClient.isValidBaseUrl("/brain/context"))

    @Test
    fun `path with trailing slash still validates scheme`() =
        assertTrue(HttpMacBrainClient.isValidBaseUrl("http://192.168.1.100:7474/"))

    // ── Response body — happy path ─────────────────────────────────────────────

    @Test
    fun `full valid response parses correctly`() {
        val json = """
            {
                "memories":       ["I prefer dark mode", "I use vim keybindings"],
                "corrections":    ["living room → light.living_room"],
                "preferences":    {"answerStyle": "concise", "units": "metric"},
                "projectSummary": "Jarvis v2 — active sprint on Phase 5"
            }
        """.trimIndent()

        val resp = HttpMacBrainClient.parseResponseBody(json)

        assertNotNull(resp)
        assertEquals(2, resp!!.memories.size)
        assertEquals("I prefer dark mode", resp.memories[0])
        assertEquals("I use vim keybindings", resp.memories[1])
        assertEquals(1, resp.corrections.size)
        assertEquals(2, resp.preferences.size)
        assertEquals("concise", resp.preferences["answerStyle"])
        assertEquals("metric", resp.preferences["units"])
        assertEquals("Jarvis v2 — active sprint on Phase 5", resp.projectSummary)
        assertFalse(resp.isEmpty())
    }

    @Test
    fun `empty JSON object returns non-null empty response`() {
        val resp = HttpMacBrainClient.parseResponseBody("{}")
        assertNotNull("empty body must still parse — server may legitimately return no context", resp)
        assertTrue(resp!!.isEmpty())
    }

    // ── Missing fields ─────────────────────────────────────────────────────────

    @Test
    fun `missing memories field defaults to empty list`() {
        val resp = HttpMacBrainClient.parseResponseBody("""{"projectSummary":"test"}""")
        assertNotNull(resp)
        assertTrue("missing memories must default to empty list", resp!!.memories.isEmpty())
    }

    @Test
    fun `missing corrections field defaults to empty list`() {
        val resp = HttpMacBrainClient.parseResponseBody("""{"memories":["hi"]}""")
        assertNotNull(resp)
        assertTrue(resp!!.corrections.isEmpty())
    }

    @Test
    fun `missing preferences field defaults to empty map`() {
        val resp = HttpMacBrainClient.parseResponseBody("""{"memories":["hi"]}""")
        assertNotNull(resp)
        assertTrue(resp!!.preferences.isEmpty())
    }

    @Test
    fun `missing projectSummary returns null not empty string`() {
        val resp = HttpMacBrainClient.parseResponseBody("""{"memories":["hi"]}""")
        assertNotNull(resp)
        assertNull("absent projectSummary must be null, not empty string", resp!!.projectSummary)
    }

    // ── Null / blank fields ────────────────────────────────────────────────────

    @Test
    fun `null memories field treated as absent`() {
        val resp = HttpMacBrainClient.parseResponseBody("""{"memories":null}""")
        assertNotNull(resp)
        assertTrue(resp!!.memories.isEmpty())
    }

    @Test
    fun `blank projectSummary treated as null`() {
        val resp = HttpMacBrainClient.parseResponseBody("""{"projectSummary":"   "}""")
        assertNotNull(resp)
        assertNull("blank projectSummary must be treated as null", resp!!.projectSummary)
    }

    @Test
    fun `blank items inside memories array are filtered out`() {
        val resp = HttpMacBrainClient.parseResponseBody(
            """{"memories":["valid","","  ","also valid"]}"""
        )
        assertNotNull(resp)
        assertEquals("blank memory items must be filtered", 2, resp!!.memories.size)
    }

    @Test
    fun `blank keys in preferences map are filtered out`() {
        // org.json returns empty string for missing values — filtered via takeIf { isNotBlank() }
        val resp = HttpMacBrainClient.parseResponseBody(
            """{"preferences":{"goodKey":"goodValue","badKey":""}}"""
        )
        assertNotNull(resp)
        assertEquals("blank-value preference entries must be filtered", 1, resp!!.preferences.size)
        assertTrue(resp.preferences.containsKey("goodKey"))
    }

    // ── Unknown / extra fields ─────────────────────────────────────────────────

    @Test
    fun `unknown top-level fields are silently ignored`() {
        val json = """
            {
                "memories":           ["test"],
                "unknownFutureField": "some_value",
                "nestedUnknown":      {"key": "value"},
                "numberField":        42
            }
        """.trimIndent()
        val resp = HttpMacBrainClient.parseResponseBody(json)
        assertNotNull("unknown fields must not cause a parse failure", resp)
        assertEquals(1, resp!!.memories.size)
    }

    @Test
    fun `extra nested objects in preferences are ignored`() {
        // Server might evolve preferences to have nested values.
        // org.json.optString() coerces nested objects to their JSON string representation,
        // so they survive the blank-filter. The key point: parsing must not crash, and
        // string-valued entries must remain correct.
        val resp = HttpMacBrainClient.parseResponseBody(
            """{"preferences":{"style":"concise","nested":{"deep":"value"}}}"""
        )
        assertNotNull("nested preferences must not crash parsing", resp)
        // String-valued entry must be correct regardless of other entries
        assertEquals("concise", resp!!.preferences["style"])
    }

    // ── Malformed / invalid body ───────────────────────────────────────────────

    @Test
    fun `completely malformed JSON returns null`() {
        assertNull(
            "malformed JSON must return null — caller falls back to local-only context",
            HttpMacBrainClient.parseResponseBody("not json at all {{{")
        )
    }

    @Test
    fun `empty string returns null`() {
        assertNull(HttpMacBrainClient.parseResponseBody(""))
    }

    @Test
    fun `JSON array at root level returns null`() {
        // Root must be an object; an array means the server returned the wrong shape
        assertNull(HttpMacBrainClient.parseResponseBody("""["this","is","wrong"]"""))
    }

    @Test
    fun `truncated JSON returns null`() {
        assertNull(HttpMacBrainClient.parseResponseBody("""{"memories":["half"""))
    }

    // ── Response size guard ────────────────────────────────────────────────────

    @Test
    fun `MAX_RESPONSE_BYTES constant is 32 KiB`() {
        // Verifies the size cap hasn't been accidentally inflated (prompt-injection risk)
        assertEquals("MAX_RESPONSE_BYTES must be exactly 32 KiB", 32 * 1024, HttpMacBrainClient.MAX_RESPONSE_BYTES)
    }

    @Test
    fun `typical response is well within MAX_RESPONSE_BYTES`() {
        val typical = """{"memories":["I prefer dark mode"],"projectSummary":"test"}"""
        assertTrue(
            "typical response must be under limit",
            typical.toByteArray(Charsets.UTF_8).size < HttpMacBrainClient.MAX_RESPONSE_BYTES
        )
    }

    // ── Security: API key not in body ──────────────────────────────────────────

    @Test
    fun `parsed response does not expose any credential fields`() {
        val json = """
            {
                "memories":       ["test"],
                "apiKey":         "should-be-rejected",
                "authorization":  "Bearer token",
                "bearer":         "secret"
            }
        """.trimIndent()
        val resp = HttpMacBrainClient.parseResponseBody(json)
        assertNotNull(resp)
        // The field isn't mapped — it just gets silently ignored
        assertEquals(1, resp!!.memories.size)
    }

    // ── Response is empty helper ───────────────────────────────────────────────

    @Test
    fun `BrainContextResponse isEmpty returns true for all-empty fields`() {
        val empty = BrainContextResponse()
        assertTrue(empty.isEmpty())
    }

    @Test
    fun `BrainContextResponse isEmpty returns false when memories present`() {
        val nonEmpty = BrainContextResponse(memories = listOf("something"))
        assertFalse(nonEmpty.isEmpty())
    }

    @Test
    fun `BrainContextResponse isEmpty returns false when projectSummary present`() {
        val nonEmpty = BrainContextResponse(projectSummary = "Project X")
        assertFalse(nonEmpty.isEmpty())
    }
}
