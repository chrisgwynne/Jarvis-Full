package com.jarvis.assistant.reliability

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for [ListenerDiagnostics] and [DiagnosticsSnapshot].
 *
 * Coverage:
 *  - Counter increments and decrements are reflected in [snapshot]
 *  - [recordListenStop] updates reason + timestamp
 *  - [resetForTest] restores all fields to zero/null
 *  - Multiple rapid recordListenStop calls keep only the most recent reason
 *  - [DiagnosticsSnapshot.toDebugCard] includes all key fields in the output
 *  - Last-event string fields are independent (writing one doesn't affect another)
 *  - Watchdog counter increments independently of other counters
 */
class ListenerDiagnosticsTest {

    @Before
    fun setUp() {
        ListenerDiagnostics.resetForTest()
    }

    // ── 1. Counter operations ─────────────────────────────────────────────────

    @Test
    fun `wake detector counter reflects set operations`() {
        assertEquals(0, ListenerDiagnostics.activeWakeDetectorCount.get())
        ListenerDiagnostics.activeWakeDetectorCount.set(1)
        assertEquals(1, ListenerDiagnostics.snapshot().activeWakeDetectorCount)
        ListenerDiagnostics.activeWakeDetectorCount.set(0)
        assertEquals(0, ListenerDiagnostics.snapshot().activeWakeDetectorCount)
    }

    @Test
    fun `speech recognizer counter reflects set operations`() {
        ListenerDiagnostics.activeSpeechRecognizerCount.set(1)
        assertEquals(1, ListenerDiagnostics.snapshot().activeSpeechRecognizerCount)
    }

    @Test
    fun `overlay view counter tracks attach and detach`() {
        ListenerDiagnostics.activeOverlayViewCount.incrementAndGet()
        assertEquals(1, ListenerDiagnostics.snapshot().activeOverlayViewCount)
        ListenerDiagnostics.activeOverlayViewCount.decrementAndGet()
        assertEquals(0, ListenerDiagnostics.snapshot().activeOverlayViewCount)
    }

    @Test
    fun `HA subscription counter tracks service lifecycle`() {
        ListenerDiagnostics.activeHaSubscriptionCount.incrementAndGet()
        assertEquals(1, ListenerDiagnostics.snapshot().activeHaSubscriptionCount)
        ListenerDiagnostics.activeHaSubscriptionCount.decrementAndGet()
        assertEquals(0, ListenerDiagnostics.snapshot().activeHaSubscriptionCount)
    }

    @Test
    fun `mac bridge counter reflects connection and disconnection`() {
        ListenerDiagnostics.activeMacBridgeConnectionCount.set(1)
        assertEquals(1, ListenerDiagnostics.snapshot().activeMacBridgeConnectionCount)
        ListenerDiagnostics.activeMacBridgeConnectionCount.set(0)
        assertEquals(0, ListenerDiagnostics.snapshot().activeMacBridgeConnectionCount)
    }

    @Test
    fun `notification buffer size counter can be set directly`() {
        ListenerDiagnostics.notificationListenerBufferSize.set(17)
        assertEquals(17, ListenerDiagnostics.snapshot().notificationListenerBufferSize)
    }

    // ── 2. recordListenStop ───────────────────────────────────────────────────

    @Test
    fun `recordListenStop — reason and timestamp are updated`() {
        val before = System.currentTimeMillis()
        ListenerDiagnostics.recordListenStop("audio_duck_in_idle_wake")
        val after = System.currentTimeMillis()

        val snap = ListenerDiagnostics.snapshot()
        assertEquals("audio_duck_in_idle_wake", snap.lastListenStopReason)
        assertTrue("timestamp should be within test window",
            snap.lastListenStopTimeMs in before..after)
    }

    @Test
    fun `recordListenStop — most recent call wins`() {
        ListenerDiagnostics.recordListenStop("first_reason")
        ListenerDiagnostics.recordListenStop("second_reason")
        assertEquals("second_reason", ListenerDiagnostics.snapshot().lastListenStopReason)
    }

    @Test
    fun `recordListenStop with different reasons — each updates the field`() {
        for (reason in listOf("audio_focus_lost", "bridge_mode_demotion", "service_shutdown")) {
            ListenerDiagnostics.recordListenStop(reason)
            assertEquals(reason, ListenerDiagnostics.lastListenStopReason)
        }
    }

    // ── 3. Last-event strings ─────────────────────────────────────────────────

    @Test
    fun `lastAudioFocusEvent is independently writable`() {
        ListenerDiagnostics.lastAudioFocusEvent = "lost transient=true state=IdleWake"
        assertEquals("lost transient=true state=IdleWake",
            ListenerDiagnostics.snapshot().lastAudioFocusEvent)
        // Other fields unaffected
        assertNull(ListenerDiagnostics.snapshot().lastListenStopReason)
    }

    @Test
    fun `lastOverlayAttempt and lastOverlayBlockReason are independent`() {
        ListenerDiagnostics.lastOverlayAttempt    = "type=HOME_ASSISTANT_ALERT entity=sensor.door"
        ListenerDiagnostics.lastOverlayBlockReason = "master_disabled"

        val snap = ListenerDiagnostics.snapshot()
        assertEquals("type=HOME_ASSISTANT_ALERT entity=sensor.door", snap.lastOverlayAttempt)
        assertEquals("master_disabled", snap.lastOverlayBlockReason)
    }

    @Test
    fun `currentListeningState and currentRole are writable`() {
        ListenerDiagnostics.currentListeningState = "Listening"
        ListenerDiagnostics.currentRole           = "FULL_ASSISTANT"

        val snap = ListenerDiagnostics.snapshot()
        assertEquals("Listening",       snap.currentListeningState)
        assertEquals("FULL_ASSISTANT",  snap.currentRole)
    }

    // ── 4. Watchdog counter ───────────────────────────────────────────────────

    @Test
    fun `watchdog restart counter increments atomically`() {
        assertEquals(0, ListenerDiagnostics.watchdogRestartCount.get())
        ListenerDiagnostics.watchdogRestartCount.incrementAndGet()
        ListenerDiagnostics.watchdogRestartCount.incrementAndGet()
        assertEquals(2, ListenerDiagnostics.snapshot().watchdogRestartCount)
    }

    @Test
    fun `lastWatchdogRestartMs is writable`() {
        val ts = System.currentTimeMillis()
        ListenerDiagnostics.lastWatchdogRestartMs = ts
        assertEquals(ts, ListenerDiagnostics.snapshot().lastWatchdogRestartMs)
    }

    // ── 5. resetForTest ───────────────────────────────────────────────────────

    @Test
    fun `resetForTest clears all counters and strings`() {
        // Write non-zero state
        ListenerDiagnostics.activeWakeDetectorCount.set(1)
        ListenerDiagnostics.activeSpeechRecognizerCount.set(1)
        ListenerDiagnostics.activeOverlayViewCount.set(1)
        ListenerDiagnostics.activeHaSubscriptionCount.set(1)
        ListenerDiagnostics.activeMacBridgeConnectionCount.set(1)
        ListenerDiagnostics.notificationListenerBufferSize.set(5)
        ListenerDiagnostics.recordListenStop("some_reason")
        ListenerDiagnostics.lastAudioFocusEvent    = "focus_event"
        ListenerDiagnostics.lastOverlayAttempt     = "attempt"
        ListenerDiagnostics.lastOverlayBlockReason = "blocked"
        ListenerDiagnostics.currentListeningState  = "Listening"
        ListenerDiagnostics.currentRole            = "FULL_ASSISTANT"
        ListenerDiagnostics.watchdogRestartCount.set(3)
        ListenerDiagnostics.lastWatchdogRestartMs  = 12345L

        ListenerDiagnostics.resetForTest()
        val snap = ListenerDiagnostics.snapshot()

        assertEquals(0,        snap.activeWakeDetectorCount)
        assertEquals(0,        snap.activeSpeechRecognizerCount)
        assertEquals(0,        snap.activeOverlayViewCount)
        assertEquals(0,        snap.activeHaSubscriptionCount)
        assertEquals(0,        snap.activeMacBridgeConnectionCount)
        assertEquals(0,        snap.notificationListenerBufferSize)
        assertNull(snap.lastListenStopReason)
        assertEquals(0L,       snap.lastListenStopTimeMs)
        assertNull(snap.lastAudioFocusEvent)
        assertNull(snap.lastOverlayAttempt)
        assertNull(snap.lastOverlayBlockReason)
        assertEquals("UNKNOWN", snap.currentListeningState)
        assertEquals("UNKNOWN", snap.currentRole)
        assertEquals(0,        snap.watchdogRestartCount)
        assertEquals(0L,       snap.lastWatchdogRestartMs)
    }

    // ── 6. DiagnosticsSnapshot.toDebugCard ────────────────────────────────────

    @Test
    fun `toDebugCard includes all key fields`() {
        ListenerDiagnostics.activeWakeDetectorCount.set(1)
        ListenerDiagnostics.activeSpeechRecognizerCount.set(0)
        ListenerDiagnostics.activeOverlayViewCount.set(2)
        ListenerDiagnostics.activeHaSubscriptionCount.set(1)
        ListenerDiagnostics.activeMacBridgeConnectionCount.set(0)
        ListenerDiagnostics.notificationListenerBufferSize.set(7)
        ListenerDiagnostics.recordListenStop("audio_duck_in_idle_wake")
        ListenerDiagnostics.lastAudioFocusEvent    = "lost transient=true state=IdleWake"
        ListenerDiagnostics.lastOverlayBlockReason = "entity_cooldown:sensor.door:118s"
        ListenerDiagnostics.currentListeningState  = "IdleWake"
        ListenerDiagnostics.currentRole            = "FULL_ASSISTANT"
        ListenerDiagnostics.watchdogRestartCount.set(0)

        val card = ListenerDiagnostics.snapshot().toDebugCard()

        assertNotNull(card)
        assertTrue("should contain role",          "FULL_ASSISTANT" in card)
        assertTrue("should contain state",         "IdleWake" in card)
        assertTrue("should contain wake count",    "Wake: 1" in card)
        assertTrue("should contain overlay count", "Overlay: 2" in card)
        assertTrue("should contain HA subs",       "HASubs: 1" in card)
        assertTrue("should contain buffer size",   "NotifBuf: 7" in card)
        assertTrue("should contain stop reason",   "audio_duck_in_idle_wake" in card)
        assertTrue("should contain focus event",   "transient=true" in card)
        assertTrue("should contain block reason",  "entity_cooldown" in card)
    }

    @Test
    fun `toDebugCard shows dashes for null fields`() {
        // All null by default (after resetForTest in setUp)
        val card = ListenerDiagnostics.snapshot().toDebugCard()
        assertTrue("null stop reason should show dash", "StopReason: —" in card)
        assertTrue("null focus event should show dash", "Focus: —" in card)
    }
}
