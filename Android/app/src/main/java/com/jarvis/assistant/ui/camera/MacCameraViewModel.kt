package com.jarvis.assistant.ui.camera

import android.app.Application
import android.graphics.Bitmap
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.util.SettingsStore
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

sealed class StreamState {
    object Connecting : StreamState()
    object Live : StreamState()
    data class Snapshot(val reason: String) : StreamState()
    object Offline : StreamState()
    data class Error(val message: String) : StreamState()
}

class MacCameraViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private const val TAG           = "MacCameraViewModel"
        private const val MAX_RECONNECTS = 5
        private const val RECONNECT_DELAY_MS = 2_000L
    }

    private val settings = SettingsStore(application)

    private val _streamState = MutableStateFlow<StreamState>(StreamState.Connecting)
    val streamState: StateFlow<StreamState> = _streamState.asStateFlow()

    private val _currentFrame = MutableStateFlow<Bitmap?>(null)
    val currentFrame: StateFlow<Bitmap?> = _currentFrame.asStateFlow()

    val reconnectCount = AtomicInteger(0)
    val frameCount     = AtomicLong(0L)
    val lastFrameAtMs  = AtomicLong(0L)
    @Volatile var lastError: String = ""

    private var streamJob: Job? = null

    fun startStream() {
        if (streamJob?.isActive == true) return
        Log.i(TAG, "MAC_CAMERA_VIEWER_OPENED")
        Log.i(TAG, "LISTENING_STILL_ACTIVE_CAMERA_VIEWER")
        streamJob = viewModelScope.launch { connectLoop() }
    }

    fun stopStream() {
        streamJob?.cancel()
        streamJob = null
        _streamState.value = StreamState.Offline
        Log.i(TAG, "MAC_CAMERA_VIEWER_CLOSED")
        Log.i(TAG, "CAMERA_VIEWER_CLOSED_LISTENING_OK")
    }

    fun retry() {
        stopStream()
        reconnectCount.set(0)
        _streamState.value = StreamState.Connecting
        startStream()
    }

    override fun onCleared() {
        super.onCleared()
        stopStream()
    }

    // ── Stream loop ──────────────────────────────────────────────────────────

    private suspend fun connectLoop() {
        Log.i(TAG, "MAC_CAMERA_OPEN_REQUESTED")

        val cfg = JarvisApp.macBrainConnectionManager.settingsRepo.snapshot()
        if (!cfg.isPaired) {
            Log.w(TAG, "MAC_CAMERA_ERROR: not paired")
            lastError = "Not connected to Mac Jarvis"
            _streamState.value = StreamState.Offline
            return
        }

        val baseUrl = cfg.baseUrl.trimEnd('/')
        val token   = cfg.deviceToken ?: ""
        val url     = "$baseUrl/v1/camera/stream"

        _streamState.value = StreamState.Connecting

        var attempts = 0
        while (attempts < MAX_RECONNECTS) {
            Log.i(TAG, "MAC_CAMERA_STREAM_CONNECTING (attempt ${attempts + 1})")
            _streamState.value = StreamState.Connecting

            var receivedAnyFrame = false
            try {
                MjpegStreamReader.frames(url, token).collect { frame ->
                    _currentFrame.value = frame
                    lastFrameAtMs.set(System.currentTimeMillis())
                    frameCount.incrementAndGet()
                    if (!receivedAnyFrame) {
                        Log.i(TAG, "MAC_CAMERA_STREAM_CONNECTED")
                        _streamState.value = StreamState.Live
                        receivedAnyFrame = true
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                Log.d(TAG, "MAC_CAMERA_STREAM_DISCONNECTED: cancelled")
                return
            } catch (e: Exception) {
                lastError = e.message ?: "Stream error"
                Log.w(TAG, "MAC_CAMERA_ERROR: ${e.message}")
            }

            if (!receivedAnyFrame) {
                lastError = "Mac camera isn't reachable"
                Log.w(TAG, "MAC_CAMERA_STREAM_DISCONNECTED: no frames received")
                _streamState.value = StreamState.Offline
                return
            }

            // Stream dropped — reconnect
            attempts++
            reconnectCount.incrementAndGet()
            Log.i(TAG, "MAC_CAMERA_STREAM_RETRY: attempt $attempts")
            _streamState.value = StreamState.Connecting
            delay(RECONNECT_DELAY_MS)
        }

        lastError = "Stream unreachable after $MAX_RECONNECTS attempts"
        Log.w(TAG, "MAC_CAMERA_STREAM_DISCONNECTED: max retries reached")
        _streamState.value = StreamState.Offline
    }
}
