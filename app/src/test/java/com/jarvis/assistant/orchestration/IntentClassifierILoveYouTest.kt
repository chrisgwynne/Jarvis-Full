package com.jarvis.assistant.orchestration

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression tests for the EXPLICIT_STORE_PATTERNS pronoun guard.
 *
 * Pre-fix: "I love you" matched `^i love\s` and became a stored fact
 * ("Noted.").  During a messaging follow-up that meant the user's
 * intended WhatsApp body was silently captured as a profile fact
 * instead of being sent.
 *
 * Post-fix: "I love you" (and similar pronoun-object forms) NEVER hit
 * RememberFact — they pass through to the normal routing layers where
 * the pending-intent intercept catches them.
 */
class IntentClassifierILoveYouTest {

    // ── Pronoun objects must NOT trigger memory store ───────────────────────

    @Test fun `i love you is not a memory store`() {
        val action = IntentClassifier.classify("I love you")
        assertNotEquals(
            "\"I love you\" must pass through, not become a stored fact",
            ConversationAction::class.java,
            (action as? ConversationAction.RememberFact)?.javaClass,
        )
        assertTrue(action is ConversationAction.PassThrough)
    }

    @Test fun `i love you so much is not a memory store`() {
        val action = IntentClassifier.classify("I love you so much")
        assertTrue(action is ConversationAction.PassThrough)
    }

    @Test fun `i hate him is not a memory store`() {
        assertTrue(IntentClassifier.classify("I hate him") is ConversationAction.PassThrough)
    }

    @Test fun `i like her is not a memory store`() {
        assertTrue(IntentClassifier.classify("I like her") is ConversationAction.PassThrough)
    }

    @Test fun `i dislike them is not a memory store`() {
        assertTrue(IntentClassifier.classify("I dislike them") is ConversationAction.PassThrough)
    }

    @Test fun `i love that is not a memory store`() {
        assertTrue(IntentClassifier.classify("I love that") is ConversationAction.PassThrough)
    }

    @Test fun `i hate it is not a memory store`() {
        assertTrue(IntentClassifier.classify("I hate it") is ConversationAction.PassThrough)
    }

    // ── Genuine preference / fact statements STILL store ──────────────────

    @Test fun `i love coffee is a memory store`() {
        val action = IntentClassifier.classify("I love coffee")
        assertTrue("Genuine fact should still store", action is ConversationAction.RememberFact)
    }

    @Test fun `i prefer brief weather is a memory store`() {
        val action = IntentClassifier.classify("I prefer brief weather")
        assertTrue(action is ConversationAction.RememberFact)
    }

    @Test fun `i hate the cold is a memory store`() {
        val action = IntentClassifier.classify("I hate the cold")
        assertTrue(action is ConversationAction.RememberFact)
    }

    @Test fun `i like dark chocolate is a memory store`() {
        val action = IntentClassifier.classify("I like dark chocolate")
        assertTrue(action is ConversationAction.RememberFact)
    }

    @Test fun `i usually walk to work is a memory store`() {
        val action = IntentClassifier.classify("I usually walk to work")
        assertTrue(
            "Frequency-prefixed habits still match the second pattern",
            action is ConversationAction.RememberFact,
        )
    }
}
