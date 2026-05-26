package com.jarvis.assistant.remote.maccamera

/**
 * MacCameraClient — interface for the Mac Camera HTTP service.
 *
 * Endpoints (served by the Mac camera HTTP server, not Mac Brain):
 *   GET /camera/health   → liveness check
 *   GET /camera/snapshot → single JPEG frame
 *   GET /camera/stream   → MJPEG multipart stream
 *
 * CONTRACT
 *   - All methods are suspend-safe; may be called from any dispatcher.
 *   - Never throws — wrap every failure in the appropriate sealed type.
 *   - [streamUrl] is a pure URL builder — no network I/O.
 *   - Token is sent as "Authorization: Bearer <token>" on every request.
 *   - Token is never logged.
 */
interface MacCameraClient {

    /** Quick liveness ping. Should complete in ≤ 750 ms. */
    suspend fun health(): MacCameraResult.HealthResult

    /** Fetch a single JPEG snapshot. Timeout: 2 s. */
    suspend fun snapshot(): MacCameraResult.SnapshotResult

    /** Return the URL for the MJPEG stream endpoint. No network call. */
    fun streamUrl(): String

    /**
     * Run health + basic URL validation.
     * Returns true when the camera is reachable and configured.
     */
    suspend fun validateConnection(): Boolean
}
