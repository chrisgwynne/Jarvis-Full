package com.jarvis.assistant.voice.attention

import com.jarvis.assistant.modes.JarvisMode
import com.jarvis.assistant.voice.VoiceFeatureFlags
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Regression tests for the onboarding name-capture AttentionGate bug.
 *
 * Root cause (fixed): during first-run onboarding, Jarvis asks "What's your name?"
 * and the user replies "Chris".  The gate scored the bare name at 0.0 — no command
 * verb, no tool match, no active conversation window.  IGNORE_THRESHOLD is 0.0, so
 * `score <= IGNORE_THRESHOLD` evaluated true → IGNORE.  The awaitingOwnerName
 * handler at the bottom of the conversation loop was never reached.
 *
 * Two-part fix:
 *  1. JarvisRuntime calls [AttentionGate.extendActiveWindow] after the onboarding
 *     prompt completes, so the user's reply lands inside the conversation window
 *     (+1.8 score → always ACCEPT).
 *  2. A `inSpeakerFlow` guard in the conversation loop skips the gate entirely when
 *     `awaitingOwnerName` is true.
 *
 * These tests verify:
 *  a. A bare single-word name with NO active window → IGNORE (documents old breakage)
 *  b. A bare single-word name WITH an active window → ACCEPT (belt-and-suspenders fix)
 *  c. All common onboarding response forms accept even without a window extension
 *     when the gate is bypassed (simulated by extending the window)
 *  d. Suppression/barge-in patterns do not interfere with onboarding
 */
class OnboardingNameCaptureGateTest {

    private lateinit var gate: AttentionGate

    @Before fun setUp() {
        VoiceFeatureFlags.setOverride(VoiceFeatureFlags.Flag.ATTENTION_GATE_ENABLED, true)
        gate = AttentionGate()
    }

    @After fun tearDown() {
        VoiceFeatureFlags.clearOverride(VoiceFeatureFlags.Flag.ATTENTION_GATE_ENABLED)
    }

    private fun signals(
        text:          String,
        activeWindow:  Boolean = false,
        lastTtsText:   String? = null
    ): AttentionSignals {
        if (activeWindow) gate.extendActiveWindow()
        return AttentionSignals(
            transcript                = text,
            sttConfidence             = 0.9f,
            mode                      = JarvisMode.NORMAL,
            activeWindowUntilMs       = gate.activeWindowUntilMs,
            lastJarvisResponseMs      = 0L,
            nowMs                     = System.currentTimeMillis(),
            isInCall                  = false,
            isMediaPlaying            = false,
            isHeadsetConnected        = false,
            screenOn                  = true,
            isTtsActive               = false,
            lastTtsText               = lastTtsText,
            localCommandMatch         = false,
            localCommandToolName      = null,
            transcriptCorrectorScore  = 0,
            looksLikeNotificationText = false
        )
    }

    // ── (a) Bug regression — bare name with no window was IGNORE ─────────────

    @Test
    fun `bare name Chris with no active window scores zero and is IGNORED`() {
        gate.closeActiveWindow()
        val result = gate.gate(signals("Chris", activeWindow = false))
        assertTrue(
            "Bare name 'Chris' with no active window must IGNORE (score=0.0 <= threshold=0.0) — " +
            "this test documents the root cause of the onboarding bug; the runtime-level fix " +
            "bypasses the gate entirely for awaitingOwnerName state",
            result is AttentionDecision.Ignore
        )
    }

    @Test
    fun `bare name Alex with no active window is IGNORED`() {
        gate.closeActiveWindow()
        val result = gate.gate(signals("Alex"))
        assertTrue("'Alex' with no window must IGNORE", result is AttentionDecision.Ignore)
    }

    @Test
    fun `bare name Sarah with no active window is IGNORED`() {
        gate.closeActiveWindow()
        val result = gate.gate(signals("Sarah"))
        assertTrue("'Sarah' with no window must IGNORE", result is AttentionDecision.Ignore)
    }

    // ── (b) Belt-and-suspenders fix — bare name WITH active window → ACCEPT ──

    @Test
    fun `bare name Chris WITH active window is ACCEPTED`() {
        val result = gate.gate(signals("Chris", activeWindow = true))
        assertTrue(
            "After attentionGate.extendActiveWindow() the reply 'Chris' must ACCEPT " +
            "(active window +1.8 >= threshold 0.5)",
            result is AttentionDecision.Accept
        )
    }

    @Test
    fun `bare name Jo WITH active window is ACCEPTED`() {
        // Minimum-length (2 chars) name still passes the gate inside a window
        val result = gate.gate(signals("Jo", activeWindow = true))
        assertTrue("'Jo' with active window must ACCEPT", result is AttentionDecision.Accept)
    }

    @Test
    fun `I'm Chris WITH active window is ACCEPTED`() {
        val result = gate.gate(signals("I'm Chris", activeWindow = true))
        assertTrue("'I'm Chris' with active window must ACCEPT", result is AttentionDecision.Accept)
    }

    @Test
    fun `my name is Chris WITH active window is ACCEPTED`() {
        val result = gate.gate(signals("my name is Chris", activeWindow = true))
        assertTrue("'my name is Chris' with active window must ACCEPT",
            result is AttentionDecision.Accept)
    }

    // ── (c) Onboarding name does NOT echo the prompt ─────────────────────────

    @Test
    fun `Chris is not flagged as TTS echo of the onboarding prompt`() {
        val prompt = "Hi! I'm Jarvis. What's your name?"
        val result = gate.gate(signals("Chris", activeWindow = true, lastTtsText = prompt))
        assertTrue(
            "'Chris' must not be treated as an echo of the onboarding prompt",
            result is AttentionDecision.Accept
        )
    }

    @Test
    fun `I'm Chris is not flagged as TTS echo`() {
        val prompt = "Hi! I'm Jarvis. What's your name?"
        val result = gate.gate(signals("I'm Chris", activeWindow = true, lastTtsText = prompt))
        assertTrue("'I'm Chris' must not be a TTS echo", result is AttentionDecision.Accept)
    }

    // ── (d) Suppression / barge-in does not block onboarding ─────────────────

    @Test
    fun `stop does not barge-in when TTS is not active during onboarding`() {
        // TTS is NOT active when the user answers the name question.
        // "stop" should still pass through (it's not a barge-in when TTS=false).
        val result = gate.gate(signals("stop", activeWindow = true))
        // "stop" matches the command pattern → ACCEPT regardless.
        assertTrue("'stop' outside TTS must ACCEPT", result is AttentionDecision.Accept)
    }

    // ── First command after onboarding — window still active ─────────────────

    @Test
    fun `Hey Jarvis set a timer is ACCEPTED inside window`() {
        val result = gate.gate(signals("Hey Jarvis set a timer for five minutes", activeWindow = true))
        assertTrue(
            "First command after onboarding must ACCEPT — contains wake word",
            result is AttentionDecision.Accept
        )
    }

    @Test
    fun `generic sentence is ACCEPTED inside active window`() {
        val result = gate.gate(signals("the quick brown fox jumps over the lazy dog", activeWindow = true))
        assertTrue(
            "Generic sentence must ACCEPT inside active window (+1.8)",
            result is AttentionDecision.Accept
        )
    }
}
