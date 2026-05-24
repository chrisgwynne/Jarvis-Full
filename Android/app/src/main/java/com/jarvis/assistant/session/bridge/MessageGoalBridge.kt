package com.jarvis.assistant.session.bridge

import android.util.Log
import com.jarvis.assistant.session.ConversationGoal
import com.jarvis.assistant.session.GoalType
import com.jarvis.assistant.session.PendingSlot
import com.jarvis.assistant.session.SessionStateEngine
import com.jarvis.assistant.tools.device.MessageIntentParser
import com.jarvis.assistant.tools.device.messaging.PendingMessageIntent

/**
 * MessageGoalBridge — parallel-write adapter that mirrors the legacy
 * [PendingMessageIntent] state into [SessionStateEngine] as a SEND_MESSAGE
 * [ConversationGoal].
 *
 * Migration strategy:
 *   - JarvisRuntime keeps writing to its `pendingMessageIntent` field — that
 *     remains the authoritative READ path during this transition phase.
 *   - Every mutation to `pendingMessageIntent` ALSO calls into this bridge so
 *     the SessionStateEngine reflects the same state.  This is what the
 *     diagnostics UI surfaces and what future readers will prefer.
 *
 * Why a separate bridge:
 *   - JarvisRuntime is huge.  Putting goal-creation calls inline at six sites
 *     would scatter the SEND_MESSAGE goal contract.  Centralising it here
 *     makes the goal shape one thing to read, debug, and unit-test.
 *
 * Privacy:
 *   - Body text is NEVER logged.  Recipient + channel are logged because they
 *     are operationally useful and not sensitive.  The body presence is
 *     reported as `body.len=N` so debug tooling can confirm a value was
 *     captured without revealing it.  Set [LOG_BODY_DEBUG] to true only on
 *     dev builds when you actively need it.
 */
object MessageGoalBridge {

    private const val TAG = "MessageGoalBridge"
    /** Dev-only override.  Never enable in release builds. */
    @Suppress("MayBeConstant")
    private val LOG_BODY_DEBUG = false

    /** The well-known SEND_MESSAGE slot names. */
    const val SLOT_CHANNEL   = "channel"
    const val SLOT_RECIPIENT = "recipient"
    const val SLOT_BODY      = "body"

    /**
     * Project the current [pending] state onto SessionStateEngine.  Creates or
     * refreshes the SEND_MESSAGE goal so its slot fills match the pending
     * intent.  Idempotent — call after every legacy mutation.
     */
    fun project(engine: SessionStateEngine?, pending: PendingMessageIntent) {
        engine ?: return
        val existing = engine.activeGoal
        if (existing != null && existing.type == GoalType.SEND_MESSAGE) {
            // In-flight goal — update slots in place rather than recreate so
            // createdAt + listener state don't churn.
            engine.updateSlot(SLOT_CHANNEL, pending.channel.name)
            if (pending.recipient.isNotBlank()) {
                engine.updateSlot(SLOT_RECIPIENT, pending.recipient)
            }
            if (pending.body.isNotBlank()) {
                engine.updateSlot(SLOT_BODY, pending.body)
            }
            logProjection("UPDATED", pending)
            return
        }
        // Fresh goal.
        val goal = ConversationGoal(
            type   = GoalType.SEND_MESSAGE,
            slots  = listOf(
                PendingSlot(name = SLOT_CHANNEL,   prompt = "WhatsApp or SMS?",
                    filled = pending.channel.name),
                PendingSlot(name = SLOT_RECIPIENT, prompt = "Who to?",
                    filled = pending.recipient.ifBlank { null }),
                PendingSlot(name = SLOT_BODY,      prompt = "Message?",
                    filled = pending.body.ifBlank { null }),
            ),
            sourceIntent = "messaging",
            expiresAt    = pending.expiresAtMs,
        )
        engine.setGoal(goal)
        logProjection("CREATED", pending)
    }

    /**
     * Overwrite the recipient slot.  Use when the user said something like
     * "actually send it to Sarah instead" — preserves channel and body.
     */
    fun replaceRecipient(engine: SessionStateEngine?, newRecipient: String) {
        engine ?: return
        if (engine.activeGoal?.type != GoalType.SEND_MESSAGE) return
        if (newRecipient.isBlank()) return
        engine.updateSlot(SLOT_RECIPIENT, newRecipient)
        Log.d(TAG, "[SESSION_SLOT_UPDATED] slot=$SLOT_RECIPIENT (recipient correction)")
    }

    /**
     * Overwrite the body slot — used for "actually say I'll be there in 10".
     * The body itself is not logged.
     */
    fun replaceBody(engine: SessionStateEngine?, newBody: String) {
        engine ?: return
        if (engine.activeGoal?.type != GoalType.SEND_MESSAGE) return
        if (newBody.isBlank()) return
        engine.updateSlot(SLOT_BODY, newBody)
        Log.d(TAG, "[SESSION_SLOT_UPDATED] slot=$SLOT_BODY (body correction) " +
            (if (LOG_BODY_DEBUG) "body=\"$newBody\"" else "body.len=${newBody.length}"))
    }

    /** Mark the SEND_MESSAGE goal as executed — successful dispatch. */
    fun markExecuted(engine: SessionStateEngine?) {
        engine ?: return
        if (engine.activeGoal?.type != GoalType.SEND_MESSAGE) return
        engine.markGoalExecuted()
        Log.d(TAG, "[SESSION_GOAL_COMPLETED] type=SEND_MESSAGE")
    }

    /** Clear an in-flight SEND_MESSAGE goal — user cancellation. */
    fun cancel(engine: SessionStateEngine?, reason: String) {
        engine ?: return
        if (engine.activeGoal?.type != GoalType.SEND_MESSAGE) return
        engine.cancelGoal()
        Log.d(TAG, "[SESSION_GOAL_CANCELLED] type=SEND_MESSAGE reason=$reason")
    }

    /** Clear after expiry / timeout — no user wording. */
    fun expire(engine: SessionStateEngine?) {
        engine ?: return
        if (engine.activeGoal?.type != GoalType.SEND_MESSAGE) return
        engine.clearGoal()
        Log.d(TAG, "[SESSION_GOAL_EXPIRED] type=SEND_MESSAGE")
    }

    /**
     * Detects an in-flight recipient-correction phrase.  Returns the new
     * recipient name on match, null otherwise.  Anchored on "actually" or
     * "no" + "to X" so we only fire on clear corrective intent.
     */
    fun detectRecipientCorrection(transcript: String): String? {
        val m = RECIPIENT_CORRECTION_RE.find(transcript.trim()) ?: return null
        return m.groupValues[1].trim().ifBlank { null }
    }

    /**
     * Detects "actually say <body>" / "no say <body>" / "make it say <body>".
     * Returns the new body on match.
     */
    fun detectBodyCorrection(transcript: String): String? {
        val m = BODY_CORRECTION_RE.find(transcript.trim()) ?: return null
        return m.groupValues[1].trim().ifBlank { null }
    }

    // ── Privacy-aware logging ───────────────────────────────────────────────

    private fun logProjection(action: String, pending: PendingMessageIntent) {
        val tag = when (action) {
            "CREATED" -> "[SESSION_GOAL_CREATED]"
            "UPDATED" -> "[SESSION_GOAL_ADVANCED]"
            else      -> "[SESSION_GOAL_$action]"
        }
        Log.d(TAG, "$tag type=SEND_MESSAGE channel=${pending.channel.name} " +
            "recipient=\"${pending.recipient}\" body.len=${pending.body.length}" +
            if (LOG_BODY_DEBUG) " body=\"${pending.body}\"" else "")
    }

    // ── Patterns ────────────────────────────────────────────────────────────

    /**
     * "actually send it to Sarah instead", "no send it to Sarah", "make it
     * Sarah instead", "send it to Sarah instead".  Captures the new recipient.
     */
    private val RECIPIENT_CORRECTION_RE = Regex(
        """(?ix)
        ^\s*
        (?:
            (?:actually|no|wait)\s+
            (?:send\s+it\s+to|message|make\s+it|change\s+it\s+to|to)\s+
          | (?:send\s+it\s+)?to\s+
          | make\s+it\s+
        )
        (?<name>[A-Za-z][A-Za-z'\-\s]{0,40}?)
        (?:\s+instead)?
        \s*[.?!]?\s*$
        """,
    )

    /**
     * "actually say <body>", "make it say <body>", "no say <body>", "change
     * the message to <body>".  Captures the new body.
     */
    private val BODY_CORRECTION_RE = Regex(
        """(?ix)
        ^\s*
        (?:
            (?:actually|no|wait)\s+(?:say|tell\s+(?:them|him|her))\s+
          | make\s+it\s+say\s+
          | change\s+(?:the\s+)?(?:message|body|text)\s+to\s+
        )
        (?<body>.+?)
        \s*[.?!]?\s*$
        """,
    )

    // ── Public surface for testing ──────────────────────────────────────────

    /**
     * Read-only test helper — returns the current SEND_MESSAGE goal slot
     * values as a map.  Used in unit tests to assert the goal shape.
     */
    fun snapshot(engine: SessionStateEngine?): Map<String, String?>? {
        val goal = engine?.activeGoal ?: return null
        if (goal.type != GoalType.SEND_MESSAGE) return null
        return mapOf(
            SLOT_CHANNEL   to goal.slot(SLOT_CHANNEL),
            SLOT_RECIPIENT to goal.slot(SLOT_RECIPIENT),
            SLOT_BODY      to goal.slot(SLOT_BODY),
        )
    }
}
