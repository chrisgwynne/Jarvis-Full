package com.jarvis.assistant.core.room

import com.jarvis.assistant.reliability.CrossDeviceHealthModel

/**
 * SituationRoomHealth — adapts the reliability layer's [CrossDeviceHealthModel]
 * into the dashboard's [SystemHealth] shape.
 *
 * Kept out of [SituationRoomComposer] so the composer stays free of the
 * reliability dependency and remains a pure JVM unit. The policy:
 *
 *   - CRITICAL when the wake detector isn't running — Jarvis literally can't
 *     hear its name, so nothing else it reports matters.
 *   - DEGRADED when the Mac brain is unreachable (local fallback) or remote
 *     replies are repeatedly timing out.
 *   - OK otherwise.
 */
object SituationRoomHealth {

    /** Remote-reply timeouts at or above this count count as degraded. */
    const val TIMEOUT_DEGRADED_THRESHOLD = 3

    fun from(snap: CrossDeviceHealthModel.Snapshot): SystemHealth {
        val issues = mutableListOf<String>()
        if (!snap.wakeReady) issues += "Wake detector is not running"
        if (snap.degradedModeActive) issues += "Mac brain unreachable — using local fallback"
        if (snap.remoteReplyTimeouts >= TIMEOUT_DEGRADED_THRESHOLD) {
            issues += "${snap.remoteReplyTimeouts} remote reply timeouts"
        }

        return when {
            !snap.wakeReady -> SystemHealth(
                status = HealthStatus.CRITICAL,
                summary = "Wake detection is down",
                issues = issues,
            )
            snap.degradedModeActive -> SystemHealth(
                status = HealthStatus.DEGRADED,
                summary = "Running on local fallback — Mac brain unreachable",
                issues = issues,
            )
            snap.remoteReplyTimeouts >= TIMEOUT_DEGRADED_THRESHOLD -> SystemHealth(
                status = HealthStatus.DEGRADED,
                summary = "Remote replies are timing out",
                issues = issues,
            )
            else -> SystemHealth.OK
        }
    }

    /** Convenience: read the live cross-device snapshot and adapt it. */
    fun current(): SystemHealth = from(CrossDeviceHealthModel.snapshot())
}
