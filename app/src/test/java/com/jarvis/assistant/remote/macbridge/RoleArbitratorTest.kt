package com.jarvis.assistant.remote.macbridge

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever

/**
 * RoleArbitratorTest — pure JVM tests for the six role-transition scenarios plus
 * supporting edge cases.
 *
 * ## Design
 * [RoleArbitrator] is constructed with:
 *  - A [org.mockito.kotlin.mock] [MacBridgeSettingsRepository] so we can return any
 *    [AndroidRole] without touching SharedPreferences.
 *  - Short [demotionDelayMs] / [promotionDelayMs] (50 ms / 100 ms) so
 *    [advanceTimeBy] finishes in microseconds rather than waiting real seconds.
 *  - The [runTest]'s [CoroutineScope] as [testScope] — this makes internal
 *    [delay] calls use virtual time, controllable with [advanceTimeBy].
 *  - A [bridgeStatusProvider] lambda backed by a local [currentStatus] var so
 *    tests can change the apparent bridge state without touching the companion
 *    object.
 *
 * [RoleArbitrator.onBridgeStatusChanged] is `internal` so tests call it directly
 * instead of needing a live WebSocket to emit [MacBridgeStatus] events.
 *
 * ## Scenario map
 * | # | Description                                         |
 * |---|-----------------------------------------------------|
 * | 1 | FULL → BRIDGE: full demotion cycle                  |
 * | 2 | BRIDGE → FULL: full promotion cycle                 |
 * | 3 | AUTO Mac active → effective BRIDGE_ONLY             |
 * | 4 | AUTO Mac disconnected → effective FULL_ASSISTANT    |
 * | 5 | Rapid reconnect/disconnect — no flapping            |
 * | 6 | Manual trigger while BRIDGE_ONLY → suppressed       |
 */
class RoleArbitratorTest {

    // ── Test fixtures ─────────────────────────────────────────────────────────

    /** Injected mock — controls what [AndroidRole] [settingsRepo.snapshot] returns. */
    private lateinit var mockRepo: MacBridgeSettingsRepository

    /** Controls what [bridgeStatusProvider] returns in each test. */
    private var currentStatus: MacBridgeStatus = MacBridgeStatus.DISABLED

    @Before
    fun setUp() {
        mockRepo = mock()
        currentStatus = MacBridgeStatus.DISABLED
    }

    /** Helper — build an arbitrator wired to the current [runTest] scope. */
    private fun buildArbitrator(
        role: AndroidRole = AndroidRole.AUTO,
        demotionMs: Long  = 50L,
        promotionMs: Long = 100L,
        scope: CoroutineScope,
    ): RoleArbitrator {
        whenever(mockRepo.snapshot())
            .thenReturn(MacBridgeConfig(androidRole = role))
        return RoleArbitrator(
            settingsRepo        = mockRepo,
            demotionDelayMs     = demotionMs,
            promotionDelayMs    = promotionMs,
            testScope           = scope,
            bridgeStatusProvider = { currentStatus },
        )
    }

    // ── Scenario 1: FULL_ASSISTANT → BRIDGE_ONLY ─────────────────────────────
    //
    // Expected: STT stopped, wake word stopped, TTS stopped, overlay stopped,
    //           proactive engines stopped, bridge remains connected.
    //
    // From the arbitrator's perspective:
    //   · Mac connects (CONNECTED)
    //   · After demotion delay, effectiveRole becomes BRIDGE_ONLY
    //   · conversationalOwner becomes "mac"
    //   · macReachable is true
    //   · State transitions exactly once (no spurious intermediate commits)

    @Test
    fun `scenario1 - Mac connects, demotion fires after full delay`() = runTest {
        val a = buildArbitrator(scope = this)

        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)

        // Before delay: still FULL_ASSISTANT
        assertEquals(EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)
        assertTrue("macReachable should be true", a.state.value.macReachable)

        // Advance past demotion delay
        advanceTimeBy(100L)

        assertEquals("Effective role must be BRIDGE_ONLY after demotion delay",
            EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)
        assertEquals("conversationalOwner must be 'mac' in bridge mode",
            "mac", a.state.value.conversationalOwner)
        assertNotEquals("Reason must be updated", "Initialising", a.state.value.reason)

        a.stop()
    }

    @Test
    fun `scenario1 - calling demotion twice is idempotent`() = runTest {
        val a = buildArbitrator(scope = this)

        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(100L)
        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)

        // Calling demotion signal again while already in bridge mode should not
        // re-queue a new demotion job or change anything.
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(200L)
        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)

        a.stop()
    }

    // ── Scenario 2: BRIDGE_ONLY → FULL_ASSISTANT ─────────────────────────────
    //
    // Expected: bridge remains connected, wake/STT/TTS start exactly once,
    //           no duplicate recognizers, no duplicate WebSocket clients.
    //
    // Arbitrator perspective:
    //   · Mac disconnects (RECONNECTING / DISABLED)
    //   · After promotion delay, effectiveRole becomes FULL_ASSISTANT
    //   · conversationalOwner becomes "android"
    //   · Only one role commit happens (no double-promotion)

    @Test
    fun `scenario2 - Mac disconnects, promotion fires after full delay`() = runTest {
        val a = buildArbitrator(scope = this)

        // First demote
        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(100L)
        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)

        // Now disconnect
        currentStatus = MacBridgeStatus.RECONNECTING
        a.onBridgeStatusChanged(MacBridgeStatus.RECONNECTING)

        // Before promotion delay: still BRIDGE_ONLY
        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)
        assertFalse("macReachable should be false", a.state.value.macReachable)

        // Advance past promotion delay
        advanceTimeBy(200L)

        assertEquals("Effective role must be FULL_ASSISTANT after promotion delay",
            EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)
        assertEquals("conversationalOwner must be 'android' after promotion",
            "android", a.state.value.conversationalOwner)

        a.stop()
    }

    @Test
    fun `scenario2 - calling promotion twice is idempotent`() = runTest {
        val a = buildArbitrator(scope = this)

        // Demote first
        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(100L)

        // Promote
        currentStatus = MacBridgeStatus.DISABLED
        a.onBridgeStatusChanged(MacBridgeStatus.DISABLED)
        advanceTimeBy(200L)
        assertEquals(EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)

        // Second promotion signal while already FULL should not queue another job
        a.onBridgeStatusChanged(MacBridgeStatus.DISABLED)
        advanceTimeBy(300L)
        assertEquals(EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)

        a.stop()
    }

    // ── Scenario 3: AUTO Mac active → effective BRIDGE_ONLY ──────────────────
    //
    // Expected: Android silent, Mac owns conversation.
    //
    // Verifies: after stable Mac connection, conversationalOwner="mac",
    //           effectiveRole=BRIDGE_ONLY, macReachable=true.

    @Test
    fun `scenario3 - AUTO Mac active means Android hands off`() = runTest {
        val a = buildArbitrator(role = AndroidRole.AUTO, scope = this)

        // Mac becomes active
        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        a.onMacStatusReceived(assistantActive = true)
        advanceTimeBy(100L)  // past demotion delay

        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)
        assertEquals("mac", a.state.value.conversationalOwner)
        assertTrue("macReachable must be true", a.state.value.macReachable)
        assertTrue("macAssistantActive must be true", a.state.value.macAssistantActive)

        a.stop()
    }

    @Test
    fun `scenario3 - Android stays silent while Mac remains connected`() = runTest {
        val a = buildArbitrator(role = AndroidRole.AUTO, scope = this)

        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(100L)

        // Simulate multiple Mac heartbeats — role should not flip back
        repeat(5) {
            a.onMacStatusReceived(assistantActive = true)
            advanceTimeBy(20L)
        }
        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)
        assertEquals("mac", a.state.value.conversationalOwner)

        a.stop()
    }

    // ── Scenario 4: AUTO Mac disconnected → effective FULL_ASSISTANT ──────────
    //
    // Expected: Android promotes after debounce, listens and speaks again.
    //
    // Verifies: effectiveRole=FULL_ASSISTANT, conversationalOwner="android",
    //           macReachable=false after debounce.

    @Test
    fun `scenario4 - AUTO Mac disconnected means Android promotes after debounce`() = runTest {
        val a = buildArbitrator(role = AndroidRole.AUTO, demotionMs = 50L, promotionMs = 100L, scope = this)

        // Demote first
        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(100L)
        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)

        // Mac goes away
        currentStatus = MacBridgeStatus.RECONNECTING
        a.onBridgeStatusChanged(MacBridgeStatus.RECONNECTING)

        // Halfway — Android still silent
        advanceTimeBy(50L)
        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)

        // Full promotion delay
        advanceTimeBy(100L)
        assertEquals(EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)
        assertEquals("android", a.state.value.conversationalOwner)
        assertFalse("macReachable must be false after disconnect", a.state.value.macReachable)

        a.stop()
    }

    @Test
    fun `scenario4 - DISABLED reason triggers promotion with correct message`() = runTest {
        val a = buildArbitrator(role = AndroidRole.AUTO, scope = this)

        // Demote
        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(100L)

        // Bridge disabled entirely
        currentStatus = MacBridgeStatus.DISABLED
        a.onBridgeStatusChanged(MacBridgeStatus.DISABLED)
        advanceTimeBy(200L)

        assertEquals(EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)
        assertTrue("Reason should mention disabled or resuming",
            a.state.value.reason.contains("disabled", ignoreCase = true) ||
            a.state.value.reason.contains("resuming", ignoreCase = true))

        a.stop()
    }

    // ── Scenario 5: Rapid reconnect/disconnect — no flapping ─────────────────
    //
    // Expected: no flapping, no duplicate start calls, final role is correct.
    //
    // Rule: a demotion job started during CONNECTED must be cancelled if
    //       CONNECTED disappears before the delay expires (and vice-versa for
    //       promotion jobs).

    @Test
    fun `scenario5 - rapid Mac connect then disconnect cancels demotion`() = runTest {
        val a = buildArbitrator(demotionMs = 100L, promotionMs = 200L, scope = this)

        // Connect
        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        // Advance only halfway through demotion delay
        advanceTimeBy(40L)
        assertEquals("Must still be FULL_ASSISTANT mid-demotion",
            EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)

        // Disconnect before demotion fires
        currentStatus = MacBridgeStatus.RECONNECTING
        a.onBridgeStatusChanged(MacBridgeStatus.RECONNECTING)
        // Advance well past where demotion would have fired
        advanceTimeBy(300L)

        // No demotion should have happened — still FULL_ASSISTANT
        assertEquals("Demotion must be cancelled by early disconnect",
            EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)

        a.stop()
    }

    @Test
    fun `scenario5 - rapid Mac disconnect then reconnect cancels promotion`() = runTest {
        val a = buildArbitrator(demotionMs = 50L, promotionMs = 100L, scope = this)

        // Get to bridge mode first
        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(100L)
        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)

        // Disconnect
        currentStatus = MacBridgeStatus.RECONNECTING
        a.onBridgeStatusChanged(MacBridgeStatus.RECONNECTING)
        // Halfway through promotion delay
        advanceTimeBy(40L)

        // Reconnect — cancels promotion job
        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        // Advance well past original promotion deadline
        advanceTimeBy(400L)

        // Should still be BRIDGE_ONLY — promotion was cancelled
        assertEquals("Promotion must be cancelled by reconnect",
            EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)

        a.stop()
    }

    @Test
    fun `scenario5 - five rapid toggles settle on correct final role`() = runTest {
        val a = buildArbitrator(demotionMs = 50L, promotionMs = 80L, scope = this)

        // Rapid connect/disconnect 5×
        repeat(5) {
            currentStatus = MacBridgeStatus.CONNECTED
            a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
            advanceTimeBy(10L)

            currentStatus = MacBridgeStatus.RECONNECTING
            a.onBridgeStatusChanged(MacBridgeStatus.RECONNECTING)
            advanceTimeBy(10L)
        }

        // Final: leave Mac connected and let demotion settle
        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(150L)

        assertEquals("After stabilising as connected, must be BRIDGE_ONLY",
            EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)

        a.stop()
    }

    // ── Scenario 6: Manual trigger while BRIDGE_ONLY → suppressed ────────────
    //
    // The arbitrator itself doesn't own TTS or reminders; it only manages the
    // effectiveRole flag.  Tests here verify that when effectiveRole=BRIDGE_ONLY
    // the state fields correctly signal "Android is silent":
    //   · conversationalOwner == "mac"
    //   · macReachable == true (Mac is live)
    //   · effectiveRole == BRIDGE_ONLY
    //
    // The actual TTS/STT suppression checks (bridge_mode_suppressed_local_assistant_output)
    // are enforced by JarvisRuntime.bridgeModeActive which mirrors effectiveRole.

    @Test
    fun `scenario6 - in bridge mode conversationalOwner is mac not android`() = runTest {
        val a = buildArbitrator(scope = this)

        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(100L)

        // All "speak" and "listen" paths in JarvisRuntime check bridgeModeActive
        // which is set when effectiveRole becomes BRIDGE_ONLY.  Verify the
        // arbitrator correctly signals that state.
        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)
        assertEquals("Android must yield conversation to mac",
            "mac", a.state.value.conversationalOwner)
        assertFalse("Android should not consider itself the conversational owner",
            a.state.value.conversationalOwner == "android")

        a.stop()
    }

    @Test
    fun `scenario6 - after promotion Android re-owns conversation`() = runTest {
        val a = buildArbitrator(demotionMs = 50L, promotionMs = 80L, scope = this)

        // Demote → promote cycle
        currentStatus = MacBridgeStatus.CONNECTED
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(100L)
        assertEquals("mac", a.state.value.conversationalOwner)

        currentStatus = MacBridgeStatus.DISABLED
        a.onBridgeStatusChanged(MacBridgeStatus.DISABLED)
        advanceTimeBy(200L)

        assertEquals("After promotion Android must re-own conversation",
            "android", a.state.value.conversationalOwner)
        assertEquals(EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)

        a.stop()
    }

    // ── Fixed role passthrough ────────────────────────────────────────────────

    @Test
    fun `fixed FULL_ASSISTANT role applies immediately regardless of Mac status`() = runTest {
        val a = buildArbitrator(role = AndroidRole.FULL_ASSISTANT, scope = this)
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(500L)
        assertEquals(EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)
        assertEquals("android", a.state.value.conversationalOwner)
        a.stop()
    }

    @Test
    fun `fixed BRIDGE_ONLY role applies immediately regardless of Mac status`() = runTest {
        val a = buildArbitrator(role = AndroidRole.BRIDGE_ONLY, scope = this)
        a.onBridgeStatusChanged(MacBridgeStatus.DISABLED)
        advanceTimeBy(500L)
        assertEquals(EffectiveRole.BRIDGE_ONLY, a.state.value.effectiveRole)
        assertEquals("mac", a.state.value.conversationalOwner)
        a.stop()
    }

    @Test
    fun `fixed DISABLED role maps to FULL_ASSISTANT effective role`() = runTest {
        // DISABLED means nothing starts; effectiveRole defaults to FULL_ASSISTANT
        // (arbitrator is a passthrough — JarvisRuntime handles the DISABLED stop).
        val a = buildArbitrator(role = AndroidRole.DISABLED, scope = this)
        a.onBridgeStatusChanged(MacBridgeStatus.CONNECTED)
        advanceTimeBy(500L)
        assertEquals(EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)
        a.stop()
    }

    // ── onMacStatusReceived ───────────────────────────────────────────────────

    @Test
    fun `onMacStatusReceived true sets macAssistantActive=true`() = runTest {
        val a = buildArbitrator(scope = this)
        a.onMacStatusReceived(true)
        assertTrue(a.state.value.macAssistantActive)
        a.stop()
    }

    @Test
    fun `onMacStatusReceived false sets macAssistantActive=false`() = runTest {
        val a = buildArbitrator(scope = this)
        a.onMacStatusReceived(false)
        assertFalse(a.state.value.macAssistantActive)
        a.stop()
    }

    // ── Lifecycle safety ──────────────────────────────────────────────────────

    @Test
    fun `stop without prior start does not throw`() = runTest {
        val a = buildArbitrator(scope = this)
        a.stop()   // scope.cancel() on a fresh scope — must not throw
    }

    @Test
    fun `stop can be called multiple times safely`() = runTest {
        val a = buildArbitrator(scope = this)
        a.start()
        a.stop()
        a.stop()   // second cancel is a no-op
    }

    @Test
    fun `initial state is always FULL_ASSISTANT`() = runTest {
        val a = buildArbitrator(scope = this)
        assertEquals(EffectiveRole.FULL_ASSISTANT, a.state.value.effectiveRole)
        assertEquals("android", a.state.value.conversationalOwner)
        a.stop()
    }
}
