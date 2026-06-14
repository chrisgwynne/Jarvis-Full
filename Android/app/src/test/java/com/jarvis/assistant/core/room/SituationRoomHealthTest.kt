package com.jarvis.assistant.core.room

import com.jarvis.assistant.core.state.JarvisState
import com.jarvis.assistant.reliability.CrossDeviceHealthModel
import com.jarvis.assistant.remote.brain.MacBrainStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SituationRoomHealthTest {

    private fun snapshot(
        wakeReady: Boolean = true,
        degradedModeActive: Boolean = false,
        remoteReplyTimeouts: Int = 0,
        gatewayStatus: MacBrainStatus = MacBrainStatus.Connected,
    ) = CrossDeviceHealthModel.Snapshot(
        macBrainOnline = gatewayStatus == MacBrainStatus.Connected,
        gatewayStatus = gatewayStatus,
        gatewayConnected = gatewayStatus == MacBrainStatus.Connected,
        wakeReady = wakeReady,
        listenReady = true,
        ttsReady = true,
        daemonConnected = gatewayStatus == MacBrainStatus.Connected,
        degradedModeActive = degradedModeActive,
        lastRouteId = null,
        awaitingReplySinceMs = 0L,
        lastError = null,
        remoteReplyTimeouts = remoteReplyTimeouts,
        runtimeState = JarvisState.IdleWake,
    )

    @Test
    fun `healthy snapshot maps to OK`() {
        val health = SituationRoomHealth.from(snapshot())
        assertEquals(HealthStatus.OK, health.status)
    }

    @Test
    fun `wake detector down is critical`() {
        val health = SituationRoomHealth.from(snapshot(wakeReady = false))
        assertEquals(HealthStatus.CRITICAL, health.status)
        assertTrue(health.issues.any { it.contains("Wake detector") })
    }

    @Test
    fun `mac brain unreachable is degraded`() {
        val health = SituationRoomHealth.from(
            snapshot(degradedModeActive = true, gatewayStatus = MacBrainStatus.Reconnecting),
        )
        assertEquals(HealthStatus.DEGRADED, health.status)
    }

    @Test
    fun `repeated remote timeouts are degraded`() {
        val health = SituationRoomHealth.from(
            snapshot(remoteReplyTimeouts = SituationRoomHealth.TIMEOUT_DEGRADED_THRESHOLD),
        )
        assertEquals(HealthStatus.DEGRADED, health.status)
    }
}
