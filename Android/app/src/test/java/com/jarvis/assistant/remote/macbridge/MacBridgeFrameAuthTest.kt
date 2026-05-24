package com.jarvis.assistant.remote.macbridge

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Verifies that [buildAuthenticatedJson] — the single outbound auth chokepoint —
 * correctly injects the shared token on every frame type and enforces the 64 KB
 * ceiling.  These tests run on the JVM without Android context.
 */
class MacBridgeFrameAuthTest {

    private val token = "test-secret-token-abc123"

    // ── helpers ───────────────────────────────────────────────────────────────

    private fun commandFrame(command: String = "ping") = JSONObject().apply {
        put("id", "uuid-123")
        put("type", "request")
        put("command", command)
        put("payload", JSONObject())
    }

    private fun responseFrame(command: String = "call_contact") = JSONObject().apply {
        put("id", "uuid-456")
        put("type", "response")
        put("ok", true)
        put("status", "ok")
        put("payload", JSONObject().apply { put("command", command) })
    }

    private fun phoneEventFrame(event: String = "incoming_call") = JSONObject().apply {
        put("type", "event")
        put("command", event)
        put("payload", JSONObject().apply {
            put("id", "uuid-789")
            put("source", "android")
            put("event", event)
            put("data", JSONObject().apply {
                put("contactName", "Mike")
                put("app", "Phone")
            })
        })
    }

    private fun notificationEventFrame() = JSONObject().apply {
        put("type", "event")
        put("command", "notification_received")
        put("payload", JSONObject().apply {
            put("contactName", "Alice")
            put("app", "Messages")
            put("packageName", "com.google.android.apps.messaging")
        })
    }

    private fun heartbeatFrame() = JSONObject().apply {
        put("type", "event")
        put("command", "heartbeat")
        put("payload", JSONObject().apply {
            put("battery", 82)
            put("charging", false)
            put("deviceName", "Pixel 8")
        })
    }

    // ── 1. command includes auth ──────────────────────────────────────────────

    @Test
    fun `outbound command includes auth`() {
        val json = buildAuthenticatedJson(commandFrame("ping"), token)
        val parsed = JSONObject(json)
        assertEquals(token, parsed.getString("auth"))
        assertEquals("request", parsed.getString("type"))
    }

    // ── 2. response includes auth ─────────────────────────────────────────────

    @Test
    fun `outbound response includes auth`() {
        val json = buildAuthenticatedJson(responseFrame("call_contact"), token)
        val parsed = JSONObject(json)
        assertEquals(token, parsed.getString("auth"))
        assertEquals("response", parsed.getString("type"))
        assertTrue(parsed.getBoolean("ok"))
    }

    // ── 3. phone event includes auth ──────────────────────────────────────────

    @Test
    fun `outbound phone event includes auth`() {
        val json = buildAuthenticatedJson(phoneEventFrame("incoming_call"), token)
        val parsed = JSONObject(json)
        assertEquals(token, parsed.getString("auth"))
        assertEquals("incoming_call", parsed.getString("command"))
    }

    // ── 4. notification event includes auth ───────────────────────────────────

    @Test
    fun `outbound notification event includes auth`() {
        val json = buildAuthenticatedJson(notificationEventFrame(), token)
        val parsed = JSONObject(json)
        assertEquals(token, parsed.getString("auth"))
        assertEquals("notification_received", parsed.getString("command"))
    }

    // ── 5. heartbeat includes auth ────────────────────────────────────────────

    @Test
    fun `outbound heartbeat includes auth`() {
        val json = buildAuthenticatedJson(heartbeatFrame(), token)
        val parsed = JSONObject(json)
        assertEquals(token, parsed.getString("auth"))
        assertEquals("heartbeat", parsed.getString("command"))
    }

    // ── 6. blank token — auth field absent ───────────────────────────────────

    @Test
    fun `outbound frame without pairing token omits auth field`() {
        val json = buildAuthenticatedJson(commandFrame("ping"), token = "")
        val parsed = JSONObject(json)
        assertFalse("auth field should be absent when token is blank", parsed.has("auth"))
    }

    @Test
    fun `outbound frame with whitespace-only token omits auth field`() {
        val json = buildAuthenticatedJson(phoneEventFrame(), token = "   ")
        assertFalse(JSONObject(json).has("auth"))
    }

    // ── 7. 64 KB ceiling enforced ─────────────────────────────────────────────

    @Test
    fun `realistic notification frame is under 64 KB`() {
        val frame = JSONObject().apply {
            put("type", "event")
            put("command", "notification_received")
            put("payload", JSONObject().apply {
                put("contactName", "A".repeat(200))
                put("app", "WhatsApp")
                put("packageName", "com.whatsapp")
                put("messagePreview", "B".repeat(200))
            })
        }
        val json = buildAuthenticatedJson(frame, token)
        val bytes = json.toByteArray(Charsets.UTF_8).size
        assertTrue("Frame should be under 64 KB; was $bytes bytes", bytes < 64 * 1024)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `frame over 64 KB throws IllegalArgumentException`() {
        val frame = JSONObject().apply {
            put("type", "event")
            put("command", "notification_received")
            put("payload", JSONObject().apply {
                put("body", "X".repeat(70_000))
            })
        }
        buildAuthenticatedJson(frame, token)
    }

    // ── source field not mutated ──────────────────────────────────────────────

    @Test
    fun `existing source field is preserved`() {
        val frame = phoneEventFrame().apply { put("source", "android") }
        val json = buildAuthenticatedJson(frame, token)
        assertEquals("android", JSONObject(json).getString("source"))
    }

    // ── auth injected on all canonical event sub-types ────────────────────────

    @Test
    fun `auth present on every event sub-type`() {
        val eventTypes = listOf(
            "incoming_call", "missed_call", "call_answered", "call_ended",
            "sms_received", "whatsapp_received", "notification_received",
            "battery_status", "power_connected", "power_disconnected",
            "heartbeat", "capabilities_report",
        )
        for (evt in eventTypes) {
            val json = buildAuthenticatedJson(phoneEventFrame(evt), token)
            assertTrue(
                "auth missing for event '$evt'",
                JSONObject(json).has("auth"),
            )
        }
    }
}
