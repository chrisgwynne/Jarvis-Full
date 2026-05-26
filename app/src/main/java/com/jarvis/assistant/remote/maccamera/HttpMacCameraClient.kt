package com.jarvis.assistant.remote.maccamera

import android.util.Log
import com.jarvis.assistant.remote.macbridge.MacBridgeSettingsRepository
import com.jarvis.assistant.util.SettingsStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * HttpMacCameraClient — production implementation of [MacCameraClient].
 *
 * URL resolution (in priority order):
 *   1. If [SettingsStore.macCameraUseBridgeCreds] is true:
 *      base = "http://<bridgeHost>:<macCameraPort>"
 *      token = macBridgeAuthToken
 *   2. Otherwise:
 *      base = macCameraBaseUrl
 *      token = macCameraAuthToken
 *
 * Token is injected as "Authorization: Bearer <token>" on every request.
 * Token is NEVER written to logcat.
 */
class HttpMacCameraClient(
    private val settings: SettingsStore,
    private val bridgeSettings: MacBridgeSettingsRepository,
) : MacCameraClient {

    companion object {
        private const val TAG              = "MacCameraClient"
        private const val HEALTH_TIMEOUT   = 750L
        private const val SNAPSHOT_TIMEOUT = 2_000L
        internal const val DEFAULT_CAMERA_PORT = 7474

        /**
         * Pure URL builder — exposed internal for unit tests.
         * No network I/O; no SettingsStore dependency.
         */
        internal fun buildBaseUrl(
            useBridgeCreds: Boolean,
            bridgeHost: String,
            cameraPort: Int,
            customBaseUrl: String,
        ): String {
            return if (useBridgeCreds) {
                if (bridgeHost.isBlank()) ""
                else "http://$bridgeHost:${cameraPort.takeIf { it > 0 } ?: DEFAULT_CAMERA_PORT}"
            } else {
                customBaseUrl.trimEnd('/')
            }
        }
    }

    private val httpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(3, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()
    }

    private fun resolvedBaseUrl(): String = buildBaseUrl(
        useBridgeCreds = settings.macCameraUseBridgeCreds,
        bridgeHost     = bridgeSettings.snapshot().host,
        cameraPort     = settings.macCameraPort,
        customBaseUrl  = settings.macCameraBaseUrl,
    )

    private fun resolvedToken(): String {
        return if (settings.macCameraUseBridgeCreds) {
            bridgeSettings.snapshot().authToken
        } else {
            settings.macCameraAuthToken
        }
    }

    override fun streamUrl(): String {
        val base = resolvedBaseUrl()
        return if (base.isBlank()) "" else "$base/camera/stream"
    }

    override suspend fun health(): MacCameraResult.HealthResult {
        val base = resolvedBaseUrl()
        if (base.isBlank()) {
            return MacCameraResult.HealthResult.Unreachable("Camera not configured")
        }
        val token = resolvedToken()
        val url = "$base/camera/health"

        return withContext(Dispatchers.IO) {
            val result = withTimeoutOrNull(HEALTH_TIMEOUT) {
                runCatching {
                    val req = Request.Builder()
                        .url(url)
                        .apply { if (token.isNotBlank()) addHeader("Authorization", "Bearer $token") }
                        .build()
                    httpClient.newCall(req).execute().use { resp ->
                        if (resp.isSuccessful) MacCameraResult.HealthResult.Healthy
                        else MacCameraResult.HealthResult.Unreachable("HTTP ${resp.code}")
                    }
                }.getOrElse { e ->
                    Log.w(TAG, "MAC_CAMERA_HEALTH: ${e.javaClass.simpleName} ${e.message}")
                    MacCameraResult.HealthResult.Unreachable(e.message ?: "Connection failed")
                }
            }
            result ?: MacCameraResult.HealthResult.Unreachable("Timeout")
        }
    }

    override suspend fun snapshot(): MacCameraResult.SnapshotResult {
        val base = resolvedBaseUrl()
        if (base.isBlank()) return MacCameraResult.SnapshotResult.Failure("Camera not configured")
        val token = resolvedToken()
        val url = "$base/camera/snapshot"

        return withContext(Dispatchers.IO) {
            val result = withTimeoutOrNull(SNAPSHOT_TIMEOUT) {
                runCatching {
                    val req = Request.Builder()
                        .url(url)
                        .apply { if (token.isNotBlank()) addHeader("Authorization", "Bearer $token") }
                        .build()
                    httpClient.newCall(req).execute().use { resp ->
                        if (resp.isSuccessful) {
                            val bytes = resp.body?.bytes()
                            if (bytes != null && bytes.isNotEmpty())
                                MacCameraResult.SnapshotResult.Success(bytes)
                            else
                                MacCameraResult.SnapshotResult.Failure("Empty response")
                        } else {
                            MacCameraResult.SnapshotResult.Failure("HTTP ${resp.code}")
                        }
                    }
                }.getOrElse { e ->
                    Log.w(TAG, "MAC_CAMERA_SNAPSHOT: ${e.javaClass.simpleName} ${e.message}")
                    MacCameraResult.SnapshotResult.Failure(e.message ?: "Snapshot failed")
                }
            }
            result ?: MacCameraResult.SnapshotResult.Failure("Timeout")
        }
    }

    override suspend fun validateConnection(): Boolean {
        val base = resolvedBaseUrl()
        if (base.isBlank()) return false
        return health() is MacCameraResult.HealthResult.Healthy
    }
}
