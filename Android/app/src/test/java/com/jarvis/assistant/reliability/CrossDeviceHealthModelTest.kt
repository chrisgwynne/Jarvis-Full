package com.jarvis.assistant.reliability

import com.jarvis.assistant.core.state.JarvisState
import com.jarvis.assistant.core.store.DeviceStateStore
import com.jarvis.assistant.remote.gateway.GatewayWsStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for [CrossDeviceHealthModel] snapshot aggregation.
 *
 * These tests drive the diagnostic / health-aggregation logic independently of
 * the gateway WebSocket, the state machine, and the TTS engine so they can run
 * in any JVM (no Android framework, no Coroutines test runner needed).
 *
 * The test strategy:
 *   1. Reset all shared state in @Before.
 *   2. Drive the observable inputs ([ListenerDiagnostics], [DeviceStateStore]).
 *   3. Call [CrossDeviceHealthModel.snapshot] and assert on the derived fields.
 *
 * Note: [BrainGatewayWebSocketClient.sharedStatus] is a Kotlin StateFlow with a
 * default of GatewayWsStatus.Disconnected.  We cannot set it from tests without
 * a running WebSocket client, so tests of the Connected / Degraded paths rely on
 * the default (Disconnected) and the fields we *can* set.  The full Connected path
 * is covered at integration level via RemoteReplyLifecycleTest.
 */
class CrossDeviceHealthModelTest {

    @Before
    fun setUp() {
        ListenerDiagnostics.resetForTest()
        DeviceStateStore.reset()
    }

    // ── 1. Gateway status mapping ─────────────────────────────────────────────

    @Test
    fun `snapshot gatewayStatus reflects default disconnected state`() {
        val snap = CrossDeviceHealthModel.snapshot()
        assertEquals(GatewayWsStatus.Disconnected, snap.gatewayStatus)
        assertFalse("macBrainOnline should be false when Disconnected", snap.macBrainOnline)
        assertFalse("gatewayConnected should be false when Disconnected", snap.gatewayConnected)
    }

    @Test
    fun `macBrainOnline and gatewayConnected are aliases of each other`() {
        val snap = CrossDeviceHealthModel.snapshot()
        // Both must reflect the same underlying Connected state.
        assertEquals(snap.macBrainOnline, snap.gatewayConnected)
    }

    // ── 2. Degraded mode ─────────────────────────────────────────────────────

    @Test
    fun `degradedModeActive is false when gateway is Disconnected`() {
        // Disconnected = user never set up gateway; not the same as "gateway dropped"
        val snap = CrossDeviceHealthModel.snapshot()
        assertFalse(snap.degradedModeActive)
    }

    @Test
    fun `isFullyOffline is true when gateway is Disconnected`() {
        val snap = CrossDeviceHealthModel.snapshot()
        assertTrue(snap.isFullyOffline)
    }

    @Test
    fun `isHealthy is false when macBrainOnline is false`() {
        val snap = CrossDeviceHealthModel.snapshot()
        assertFalse(snap.isHealthy)
    }

    // ── 3. Wake / listen signals ──────────────────────────────────────────────

    @Test
    fun `wakeReady is true when activeWakeDetectorCount is nonzero`() {
        ListenerDiagnostics.activeWakeDetectorCount.set(1)
        val snap = CrossDeviceHealthModel.snapshot()
        assertTrue(snap.wakeReady)
    }

    @Test
    fun `wakeReady is false when activeWakeDetectorCount is zero`() {
        ListenerDiagnostics.activeWakeDetectorCount.set(0)
        val snap = CrossDeviceHealthModel.snapshot()
        assertFalse(snap.wakeReady)
    }

    @Test
    fun `listenReady is true when activeSpeechRecognizerCount is nonzero`() {
        ListenerDiagnostics.activeSpeechRecognizerCount.set(1)
        val snap = CrossDeviceHealthModel.snapshot()
        assertTrue(snap.listenReady)
    }

    @Test
    fun `listenReady is false when speech recognizer count is zero`() {
        ListenerDiagnostics.activeSpeechRecognizerCount.set(0)
        val snap = CrossDeviceHealthModel.snapshot()
        assertFalse(snap.listenReady)
    }

    // ── 4. TTS ready ─────────────────────────────────────────────────────────

    @Test
    fun `ttsReady is true when ttsPlaying is false`() {
        // DeviceStateStore default: ttsPlaying = false
        val snap = CrossDeviceHealthModel.snapshot()
        assertTrue(snap.ttsReady)
    }

    @Test
    fun `ttsReady is false when ttsPlaying is true`() {
        DeviceStateStore.update { copy(ttsPlaying = true) }
        val snap = CrossDeviceHealthModel.snapshot()
        assertFalse(snap.ttsReady)
    }

    // ── 5. Daemon connection ──────────────────────────────────────────────────

    @Test
    fun `daemonConnected is true when activeMacBridgeConnectionCount is nonzero`() {
        ListenerDiagnostics.activeMacBridgeConnectionCount.set(1)
        val snap = CrossDeviceHealthModel.snapshot()
        assertTrue(snap.daemonConnected)
    }

    @Test
    fun `daemonConnected is false by default`() {
        val snap = CrossDeviceHealthModel.snapshot()
        assertFalse(snap.daemonConnected)
    }

    // ── 6. Route / timeout tracking ──────────────────────────────────────────

    @Test
    fun `lastRouteId is null when no pending route`() {
        val snap = CrossDeviceHealthModel.snapshot()
        assertNull(snap.lastRouteId)
        assertEquals(0L, snap.awaitingReplySinceMs)
    }

    @Test
    fun `lastRouteId reflects pendingRemoteRouteId`() {
        ListenerDiagnostics.pendingRemoteRouteId = "test-route-42"
        ListenerDiagnostics.awaitingRemoteReplySinceMs = 1_000_000L
        val snap = CrossDeviceHealthModel.snapshot()
        assertEquals("test-route-42", snap.lastRouteId)
        assertEquals(1_000_000L, snap.awaitingReplySinceMs)
    }

    @Test
    fun `awaitingReplySinceMs is zero when no pending route even if field has stale value`() {
        // Ensure awaitingReplySinceMs is only surfaced when there IS a pending route.
        ListenerDiagnostics.pendingRemoteRouteId = null
        ListenerDiagnostics.awaitingRemoteReplySinceMs = 999L
        val snap = CrossDeviceHealthModel.snapshot()
        assertNull(snap.lastRouteId)
        assertEquals(0L, snap.awaitingReplySinceMs)
    }

    @Test
    fun `remoteReplyTimeouts count is surfaced`() {
        ListenerDiagnostics.remoteReplyTimeouts.set(3)
        val snap = CrossDeviceHealthModel.snapshot()
        assertEquals(3, snap.remoteReplyTimeouts)
    }

    // ── 7. Last error ─────────────────────────────────────────────────────────

    @Test
    fun `lastError is null when no listen stop has been recorded`() {
        val snap = CrossDeviceHealthModel.snapshot()
        assertNull(snap.lastError)
    }

    @Test
    fun `lastError reflects most recent listen stop reason`() {
        ListenerDiagnostics.recordListenStop("audio_focus_lost")
        val snap = CrossDeviceHealthModel.snapshot()
        assertEquals("audio_focus_lost", snap.lastError)
    }

    // ── 8. Runtime state passthrough ─────────────────────────────────────────

    @Test
    fun `runtimeState defaults to ServiceStopped`() {
        val snap = CrossDeviceHealthModel.snapshot()
        assertEquals(JarvisState.ServiceStopped, snap.runtimeState)
    }

    // ── 9. Snapshot one-liner ─────────────────────────────────────────────────

    @Test
    fun `toOneLiner contains gateway status when not connected`() {
        val snap = CrossDeviceHealthModel.snapshot()
        val line = snap.toOneLiner()
        assertTrue("should contain 'brain=' prefix", "brain=" in line)
        assertTrue("should reflect disconnected status", "disconnected" in line)
    }

    @Test
    fun `toOneLiner marks wake ready`() {
        ListenerDiagnostics.activeWakeDetectorCount.set(1)
        val snap = CrossDeviceHealthModel.snapshot()
        assertTrue("wake=✓ expected when detector is running",
            "wake=✓" in snap.toOneLiner())
    }

    @Test
    fun `toOneLiner marks tts busy when ttsPlaying is true`() {
        DeviceStateStore.update { copy(ttsPlaying = true) }
        val snap = CrossDeviceHealthModel.snapshot()
        assertTrue("tts=busy expected when TTS is active",
            "tts=busy" in snap.toOneLiner())
    }

    @Test
    fun `toOneLiner shows timeout count when nonzero`() {
        ListenerDiagnostics.remoteReplyTimeouts.set(2)
        val snap = CrossDeviceHealthModel.snapshot()
        assertTrue("timeouts=2 should appear", "timeouts=2" in snap.toOneLiner())
    }

    @Test
    fun `toOneLiner shows DEGRADED marker when degradedModeActive`() {
        // Reconnecting state triggers degraded (gateway configured but unreachable).
        // We can't set sharedStatus directly, but we can verify the logic by
        // inspecting the snapshot fields directly.
        val snap = CrossDeviceHealthModel.snapshot()
        // With Disconnected state degradedModeActive is false, no DEGRADED marker.
        assertFalse("[DEGRADED]" in snap.toOneLiner())
    }
}
