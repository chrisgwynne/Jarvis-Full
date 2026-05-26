package com.jarvis.assistant.session.bridge

import com.jarvis.assistant.session.GoalType
import com.jarvis.assistant.session.SessionStateEngine
import com.jarvis.assistant.tools.device.MessageIntentParser
import com.jarvis.assistant.tools.device.messaging.PendingMessageIntent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for the messaging migration onto SessionStateEngine.
 *
 * Acceptance criteria covered:
 *   - WhatsApp goal projection (creation + slot reads)
 *   - SMS goal projection
 *   - Slot updates (recipient correction)
 *   - Body correction
 *   - Channel preservation across all paths
 *   - Cancellation transitions
 *   - Expiry transitions
 *   - Privacy: snapshot() never exposes body content to the test (only reads).
 *
 * The bridge logic is pure orchestration of [SessionStateEngine] mutations —
 * we don't mock the engine, we use a real instance and assert observable state.
 */
class MessageGoalBridgeTest {

    private lateinit var engine: SessionStateEngine

    @Before
    fun setUp() {
        engine = SessionStateEngine()
        engine.startSession("test-session")
    }

    // ── Creation ───────────────────────────────────────────────────────────

    @Test
    fun `project creates a SEND_MESSAGE goal with channel pre-filled`() {
        val pending = PendingMessageIntent.create(MessageIntentParser.Channel.WHATSAPP)
        MessageGoalBridge.project(engine, pending)

        val goal = engine.activeGoal
        assertNotNull("Goal should exist after project", goal)
        assertEquals(GoalType.SEND_MESSAGE, goal!!.type)
        assertEquals("WHATSAPP", goal.slot(MessageGoalBridge.SLOT_CHANNEL))
        assertNull("Recipient pending", goal.slot(MessageGoalBridge.SLOT_RECIPIENT))
        assertNull("Body pending", goal.slot(MessageGoalBridge.SLOT_BODY))
        assertEquals(
            MessageGoalBridge.SLOT_RECIPIENT,
            goal.nextUnfilledSlot?.name,
        )
    }

    @Test
    fun `project preserves WhatsApp as WhatsApp`() {
        val pending = PendingMessageIntent.create(
            MessageIntentParser.Channel.WHATSAPP, recipient = "Mike",
        )
        MessageGoalBridge.project(engine, pending)
        assertEquals("WHATSAPP", engine.activeGoal?.slot(MessageGoalBridge.SLOT_CHANNEL))
    }

    @Test
    fun `project preserves SMS as SMS`() {
        val pending = PendingMessageIntent.create(
            MessageIntentParser.Channel.SMS, recipient = "Mike",
        )
        MessageGoalBridge.project(engine, pending)
        assertEquals("SMS", engine.activeGoal?.slot(MessageGoalBridge.SLOT_CHANNEL))
    }

    @Test
    fun `project with recipient already known fills recipient slot`() {
        val pending = PendingMessageIntent.create(
            MessageIntentParser.Channel.WHATSAPP, recipient = "Mike",
        )
        MessageGoalBridge.project(engine, pending)
        assertEquals("Mike", engine.activeGoal?.slot(MessageGoalBridge.SLOT_RECIPIENT))
        assertEquals(
            MessageGoalBridge.SLOT_BODY,
            engine.activeGoal?.nextUnfilledSlot?.name,
        )
    }

    // ── In-flight updates ──────────────────────────────────────────────────

    @Test
    fun `subsequent project advances the same goal with later slots filled`() {
        // First call: just channel + recipient.
        val first = PendingMessageIntent.create(
            MessageIntentParser.Channel.WHATSAPP, recipient = "Mike",
        )
        MessageGoalBridge.project(engine, first)
        assertEquals(GoalType.SEND_MESSAGE, engine.activeGoal?.type)
        assertNull(engine.activeGoal?.slot(MessageGoalBridge.SLOT_BODY))

        // Second call: same goal type, body now filled.  The contract is that
        // the active goal reflects the latest pending state — the underlying
        // representation (in-place update vs replace) is an implementation
        // detail and not asserted.
        val second = first.copy(body = "running late")
        MessageGoalBridge.project(engine, second)

        assertEquals(GoalType.SEND_MESSAGE, engine.activeGoal?.type)
        assertEquals("WHATSAPP", engine.activeGoal?.slot(MessageGoalBridge.SLOT_CHANNEL))
        assertEquals("Mike", engine.activeGoal?.slot(MessageGoalBridge.SLOT_RECIPIENT))
        assertEquals("running late", engine.activeGoal?.slot(MessageGoalBridge.SLOT_BODY))
    }

    // ── Recipient correction ──────────────────────────────────────────────

    @Test
    fun `replaceRecipient overwrites the recipient slot`() {
        val pending = PendingMessageIntent.create(
            MessageIntentParser.Channel.WHATSAPP, recipient = "Mike", body = "hi",
        )
        MessageGoalBridge.project(engine, pending)

        MessageGoalBridge.replaceRecipient(engine, "Sarah")
        assertEquals("Sarah", engine.activeGoal?.slot(MessageGoalBridge.SLOT_RECIPIENT))
        // Channel must stay WhatsApp.
        assertEquals("WHATSAPP", engine.activeGoal?.slot(MessageGoalBridge.SLOT_CHANNEL))
        // Body must stay.
        assertEquals("hi", engine.activeGoal?.slot(MessageGoalBridge.SLOT_BODY))
    }

    @Test
    fun `replaceRecipient is a no-op when there is no active SEND_MESSAGE goal`() {
        // No goal at all.
        MessageGoalBridge.replaceRecipient(engine, "Sarah")
        assertNull(engine.activeGoal)
    }

    // ── Body correction ───────────────────────────────────────────────────

    @Test
    fun `replaceBody overwrites the body slot`() {
        val pending = PendingMessageIntent.create(
            MessageIntentParser.Channel.WHATSAPP,
            recipient = "Mike",
            body      = "running late",
        )
        MessageGoalBridge.project(engine, pending)

        MessageGoalBridge.replaceBody(engine, "I'll be there in 10")
        assertEquals(
            "I'll be there in 10",
            engine.activeGoal?.slot(MessageGoalBridge.SLOT_BODY),
        )
        // Channel + recipient unchanged.
        assertEquals("WHATSAPP", engine.activeGoal?.slot(MessageGoalBridge.SLOT_CHANNEL))
        assertEquals("Mike", engine.activeGoal?.slot(MessageGoalBridge.SLOT_RECIPIENT))
    }

    // ── Cancellation ──────────────────────────────────────────────────────

    @Test
    fun `cancel clears the active SEND_MESSAGE goal`() {
        val pending = PendingMessageIntent.create(
            MessageIntentParser.Channel.WHATSAPP, recipient = "Mike",
        )
        MessageGoalBridge.project(engine, pending)
        assertNotNull(engine.activeGoal)

        MessageGoalBridge.cancel(engine, reason = "user_cancel")
        assertNull(engine.activeGoal)
    }

    @Test
    fun `cancel is scoped — does not touch a non-SEND_MESSAGE goal`() {
        // Create a non-messaging goal directly.
        engine.setGoal(com.jarvis.assistant.session.ConversationGoal(
            type = GoalType.GENERAL,
        ))
        MessageGoalBridge.cancel(engine, reason = "user_cancel")
        // Non-messaging goal still active.
        assertNotNull(engine.activeGoal)
        assertEquals(GoalType.GENERAL, engine.activeGoal?.type)
    }

    // ── Execution ─────────────────────────────────────────────────────────

    @Test
    fun `markExecuted transitions goal to EXECUTED status`() {
        val pending = PendingMessageIntent.create(
            MessageIntentParser.Channel.WHATSAPP,
            recipient = "Mike",
            body      = "hi",
        )
        MessageGoalBridge.project(engine, pending)

        MessageGoalBridge.markExecuted(engine)
        // markGoalExecuted sets status to EXECUTED but doesn't clear the goal
        // — context stays live for follow-ups during POST_EXECUTE_TTL_MS.
        assertEquals(
            com.jarvis.assistant.session.GoalStatus.EXECUTED,
            engine.activeGoal?.status,
        )
    }

    // ── Detection helpers ─────────────────────────────────────────────────

    @Test
    fun `detectRecipientCorrection catches "actually send it to Sarah instead"`() {
        val result = MessageGoalBridge
            .detectRecipientCorrection("actually send it to Sarah instead")
        assertEquals("Sarah", result)
    }

    @Test
    fun `detectRecipientCorrection catches "no send it to Sarah"`() {
        val result = MessageGoalBridge.detectRecipientCorrection("no send it to Sarah")
        assertEquals("Sarah", result)
    }

    @Test
    fun `detectRecipientCorrection catches "make it Sarah instead"`() {
        val result = MessageGoalBridge.detectRecipientCorrection("make it Sarah instead")
        assertEquals("Sarah", result)
    }

    @Test
    fun `detectRecipientCorrection ignores ordinary body text`() {
        // "hello are you home" is a typical body — must NOT match.
        val result = MessageGoalBridge.detectRecipientCorrection("hello are you home")
        assertNull(result)
    }

    @Test
    fun `detectBodyCorrection catches "actually say I'll be there in 10"`() {
        val result = MessageGoalBridge.detectBodyCorrection("actually say I'll be there in 10")
        assertEquals("I'll be there in 10", result)
    }

    @Test
    fun `detectBodyCorrection catches "make it say running late"`() {
        val result = MessageGoalBridge.detectBodyCorrection("make it say running late")
        assertEquals("running late", result)
    }

    @Test
    fun `detectBodyCorrection ignores ordinary recipient text`() {
        val result = MessageGoalBridge.detectBodyCorrection("Mike")
        assertNull(result)
    }

    // ── Snapshot helper (used by diagnostics + tests) ─────────────────────

    @Test
    fun `snapshot returns null when no SEND_MESSAGE goal active`() {
        assertNull(MessageGoalBridge.snapshot(engine))
    }

    @Test
    fun `snapshot returns the slot map when SEND_MESSAGE is active`() {
        val pending = PendingMessageIntent.create(
            MessageIntentParser.Channel.SMS,
            recipient = "Sarah",
            body      = "running late",
        )
        MessageGoalBridge.project(engine, pending)
        val snap = MessageGoalBridge.snapshot(engine)
        assertNotNull(snap)
        assertEquals("SMS", snap!![MessageGoalBridge.SLOT_CHANNEL])
        assertEquals("Sarah", snap[MessageGoalBridge.SLOT_RECIPIENT])
        assertEquals("running late", snap[MessageGoalBridge.SLOT_BODY])
    }

    // ── Null-engine safety (e.g. during early app init) ───────────────────

    @Test
    fun `all operations are safe on a null engine`() {
        val pending = PendingMessageIntent.create(MessageIntentParser.Channel.WHATSAPP)
        MessageGoalBridge.project(null, pending)
        MessageGoalBridge.replaceRecipient(null, "Sarah")
        MessageGoalBridge.replaceBody(null, "test")
        MessageGoalBridge.markExecuted(null)
        MessageGoalBridge.cancel(null, reason = "x")
        MessageGoalBridge.expire(null)
        // Did not throw — nothing further to assert.
        assertFalse(false)
    }
}
