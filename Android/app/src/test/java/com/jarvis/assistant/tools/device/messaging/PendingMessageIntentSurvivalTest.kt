package com.jarvis.assistant.tools.device.messaging

import com.jarvis.assistant.tools.device.MessageIntentParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the survival contract of [PendingMessageIntent] across the
 * silence-timeout exit-to-wake-word path.
 *
 * The runtime no longer clears [JarvisRuntime.pendingMessageIntent] when
 * the recognizer hits its silence window — the pending intent's own 60 s
 * TTL governs expiry.  These tests pin the contract that callers (and
 * the runtime intercept) rely on:
 *
 *   - A freshly created pending intent is NOT expired immediately.
 *   - It remains non-expired through a typical thinking-pause window.
 *   - It IS expired past the TTL boundary.
 *   - merge() works correctly against a pending whose recipient is set
 *     and body is blank (the post-silence resumption case).
 */
class PendingMessageIntentSurvivalTest {

    @Test
    fun `fresh pending intent is not expired`() {
        val pending = PendingMessageIntent.create(
            channel   = MessageIntentParser.Channel.WHATSAPP,
            recipient = "wifey",
        )
        assertFalse(
            "Newly created pending intent must not be reported as expired",
            pending.isExpired(),
        )
    }

    @Test
    fun `pending survives a five second simulated elapsed`() {
        // Simulates: user pauses 5 s to think → silence_timeout fires →
        // runtime exits to wake-word but PRESERVES the pending.  Five
        // seconds later the user wakes back and replies; the pending
        // must still be valid at that point.
        val nowMs = 1_000_000L
        val pending = PendingMessageIntent.create(
            channel   = MessageIntentParser.Channel.WHATSAPP,
            recipient = "wifey",
            nowMs     = nowMs,
        )
        val fiveSecondsLater = nowMs + 5_000L
        assertFalse(
            "Pending must survive a 5 s pause (TTL is 60 s)",
            pending.isExpired(fiveSecondsLater),
        )
    }

    @Test
    fun `pending survives thirty seconds simulated elapsed`() {
        val nowMs = 1_000_000L
        val pending = PendingMessageIntent.create(
            channel   = MessageIntentParser.Channel.WHATSAPP,
            recipient = "wifey",
            nowMs     = nowMs,
        )
        assertFalse(
            "Pending must survive 30 s (TTL is 60 s)",
            pending.isExpired(nowMs + 30_000L),
        )
    }

    @Test
    fun `pending expires past TTL boundary`() {
        val nowMs = 1_000_000L
        val pending = PendingMessageIntent.create(
            channel   = MessageIntentParser.Channel.WHATSAPP,
            recipient = "wifey",
            nowMs     = nowMs,
        )
        val pastTtl = nowMs + PendingMessageIntent.TTL_MS + 1L
        assertTrue(
            "Pending past 60 s TTL must report expired",
            pending.isExpired(pastTtl),
        )
    }

    // ── The resumption flow ────────────────────────────────────────────────

    @Test
    fun `i love you merges as body after silence resumption`() {
        // Reproduces the exact regression the user reported:
        // 1. "send a whatsapp to wifey" → pending(recipient="wifey", body="")
        // 2. Silence timeout fires — pending must be preserved (fixed).
        // 3. User: "i love you"
        // 4. Intercept fires → merge → body filled, intent ready.
        val pending = PendingMessageIntent.create(
            channel   = MessageIntentParser.Channel.WHATSAPP,
            recipient = "wifey",
        )
        val merged = PendingMessageIntent.merge(pending, "i love you")

        assertEquals(MessageIntentParser.Channel.WHATSAPP, merged.channel)
        assertEquals("wifey", merged.recipient)
        assertEquals("i love you", merged.body)
        assertTrue("Merged intent should now be ready to dispatch", merged.isReady)
    }

    @Test
    fun `bare body after silence preserves the recipient`() {
        // Same shape as above but with a different body — confirms the
        // body-only merge path is robust across different message contents.
        val pending = PendingMessageIntent.create(
            channel   = MessageIntentParser.Channel.SMS,
            recipient = "Mike",
        )
        val merged = PendingMessageIntent.merge(pending, "running late, be there in 10")
        assertEquals("Mike", merged.recipient)
        assertEquals("running late, be there in 10", merged.body)
        assertEquals(MessageIntentParser.Channel.SMS, merged.channel)
    }
}
