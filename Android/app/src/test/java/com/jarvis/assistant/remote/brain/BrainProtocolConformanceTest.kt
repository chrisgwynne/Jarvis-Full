package com.jarvis.assistant.remote.brain

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Executable protocol conformance — validates [BrainProtocol] against
 * `shared/contracts/ws-frame-examples.json`, the canonical frame examples for
 * `shared/contracts/PROTOCOL.md`. The same file drives the daemon's
 * `ProtocolConformanceTests` (Mac side), so a frame-shape change that lands on
 * only one platform fails CI on the other.
 *
 * The contract file is on the test classpath via the `test.resources` srcDir
 * registered in app/build.gradle.kts — there is no copied fixture to drift.
 */
class BrainProtocolConformanceTest {

    private val examples: JSONObject by lazy {
        val stream = checkNotNull(
            javaClass.classLoader?.getResourceAsStream("ws-frame-examples.json")
        ) { "shared/contracts/ws-frame-examples.json missing from test classpath" }
        JSONObject(stream.bufferedReader().readText())
    }

    private fun example(group: String, name: String): JSONObject =
        examples.getJSONObject(group).getJSONObject(name)

    // ── Outbound: client → daemon ───────────────────────────────────────────

    @Test
    fun `transcript final matches the contract example field-for-field`() {
        val contract = example("client_to_mac", "transcript.final")
        val built = BrainProtocol.transcriptFinal(
            text        = contract.getString("transcript"),
            routeId     = contract.getString("messageId"),
            deviceId    = contract.getString("deviceId"),
            timestampMs = contract.getLong("timestamp"),
        )
        // Exact key set — an extra or missing field is contract drift.
        assertEquals(
            contract.keys().asSequence().toSet(),
            built.keys().asSequence().toSet(),
        )
        for (key in contract.keys()) {
            assertEquals("field '$key'", contract.get(key).toString(), built.get(key).toString())
        }
    }

    // ── Inbound: mac → client ───────────────────────────────────────────────

    @Test
    fun `reply final parses text and correlates via routeId or messageId`() {
        val contract = example("mac_to_client", "reply.final")
        assertEquals("reply.final", BrainProtocol.frameType(contract))
        assertEquals(contract.getString("text"), BrainProtocol.replyText(contract))

        // The contract's reply carries routeId == the transcript's messageId.
        // The manager correlates on correlationId/messageId, so a daemon echo
        // using either key must resolve.
        val viaCorrelationId = JSONObject(contract.toString())
            .put("correlationId", contract.getString("routeId"))
        assertEquals(
            contract.getString("routeId"),
            BrainProtocol.replyCorrelationId(viaCorrelationId),
        )
        val viaMessageId = JSONObject(contract.toString())
            .put("messageId", contract.getString("routeId"))
        assertEquals(
            contract.getString("routeId"),
            BrainProtocol.replyCorrelationId(viaMessageId),
        )
    }

    @Test
    fun `reply partial parses streaming text`() {
        val contract = example("mac_to_client", "reply.partial")
        assertEquals(contract.getString("text"), BrainProtocol.replyText(contract))
    }

    @Test
    fun `orchestrate speak parses text`() {
        val contract = example("mac_to_client", "orchestrate.speak")
        assertEquals("orchestrate.speak", BrainProtocol.frameType(contract))
        assertEquals(contract.getString("text"), BrainProtocol.replyText(contract))
    }

    @Test
    fun `orchestrate silent parses reason and defaults when absent`() {
        val contract = example("mac_to_client", "orchestrate.silent")
        assertEquals(contract.getString("reason"), BrainProtocol.silentReason(contract))
        assertEquals("mac_responding", BrainProtocol.silentReason(JSONObject()))
    }

    @Test
    fun `proactive notify parses title and body`() {
        val contract = example("mac_to_client", "proactive.notify")
        val (title, body) = checkNotNull(BrainProtocol.proactiveNotification(contract))
        assertEquals(contract.getString("title"), title)
        assertEquals(contract.getString("body"), body)
        // Body is mandatory — a bodyless notification is dropped, not shown blank.
        assertNull(BrainProtocol.proactiveNotification(JSONObject().put("title", "x")))
    }

    @Test
    fun `blank reply text is rejected not passed through`() {
        assertNull(BrainProtocol.replyText(JSONObject().put("text", "")))
        assertNull(BrainProtocol.replyText(JSONObject()))
    }

    // ── Envelope-routed frames: daemon → android ────────────────────────────

    @Test
    fun `comm action execute payload is extracted from the envelope`() {
        val contract = example("daemon_to_mac", "comm.action.execute")
        val payload = BrainProtocol.payloadOf(contract)
        assertEquals("req_xyz", payload.getString("requestId"))
        assertEquals("callBack", payload.getString("action"))
        // Security invariant (PROTOCOL.md): comm actions arriving at Android
        // always require explicit user confirmation.
        assertTrue(payload.getBoolean("requiresConfirmation"))
    }

    @Test
    fun `handoff request payload is extracted from the envelope`() {
        val contract = example("mac_to_daemon", "handoff.request_mac_to_android")
        val payload = BrainProtocol.payloadOf(contract)
        assertEquals("text", payload.getString("key"))
        assertNotNull(payload.getString("value"))
        assertEquals("mac", payload.getString("sourceDevice"))
    }

    @Test
    fun `flat frames fall back to top-level fields when no payload object exists`() {
        val flat = JSONObject().put("key", "url").put("value", "https://example.com")
        val payload = BrainProtocol.payloadOf(flat)
        assertEquals("url", payload.getString("key"))
    }

    @Test
    fun `every mac_to_client example carries a type discriminator`() {
        val group = examples.getJSONObject("mac_to_client")
        for (name in group.keys()) {
            val frame = group.getJSONObject(name)
            assertTrue(
                "example '$name' must have a non-blank type",
                BrainProtocol.frameType(frame).isNotBlank(),
            )
        }
    }
}
