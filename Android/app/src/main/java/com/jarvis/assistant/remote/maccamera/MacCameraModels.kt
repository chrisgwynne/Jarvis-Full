package com.jarvis.assistant.remote.maccamera

/** Sealed results returned by MacCameraClient operations. Never throws. */
sealed class MacCameraResult {

    sealed class HealthResult : MacCameraResult() {
        object Healthy : HealthResult()
        data class Unreachable(val reason: String) : HealthResult()
    }

    sealed class SnapshotResult : MacCameraResult() {
        data class Success(val jpegBytes: ByteArray) : SnapshotResult()
        data class Failure(val reason: String) : SnapshotResult()
    }
}

/** Stable snapshot of camera diagnostics shown in the diagnostics screen. */
data class MacCameraDiagnosticsSnapshot(
    val enabled: Boolean = false,
    val healthReachable: Boolean = false,
    val streamConnected: Boolean = false,
    val lastFrameAtMs: Long = 0L,
    val reconnectCount: Int = 0,
    val frameCount: Long = 0L,
    val lastError: String = "",
    val viewerOpen: Boolean = false,
    val streamUrl: String = "",
    val tokenPresent: Boolean = false,
)
