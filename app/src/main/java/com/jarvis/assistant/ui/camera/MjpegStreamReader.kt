package com.jarvis.assistant.ui.camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit

/**
 * MjpegStreamReader — reads an MJPEG multipart stream and emits decoded Bitmaps.
 *
 * Protocol: multipart/x-mixed-replace;boundary=<boundary>
 *   --<boundary>\r\n
 *   Content-Type: image/jpeg\r\n
 *   Content-Length: <n>\r\n
 *   \r\n
 *   [JPEG bytes (n bytes)]\r\n
 *   --<boundary>\r\n
 *   ...
 *
 * SAFETY
 *   - Frame cap: MAX_FRAME_BYTES — oversized frames are skipped.
 *   - Flow cancellation closes the stream immediately via the OkHttp call.
 *   - Runs on Dispatchers.IO.
 */
object MjpegStreamReader {

    private const val TAG           = "MjpegStreamReader"
    private const val MAX_FRAME_BYTES = 2 * 1024 * 1024  // 2 MB per JPEG

    private val httpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(3, TimeUnit.SECONDS)
            // No read timeout — the stream is indefinite
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }

    /**
     * Connect to [streamUrl] and emit decoded JPEG frames as [Bitmap]s.
     *
     * Emits until the coroutine is cancelled or the stream closes.
     * Never throws — errors are swallowed and the flow simply completes.
     */
    fun frames(streamUrl: String, authToken: String): Flow<Bitmap> = flow {
        if (streamUrl.isBlank()) {
            Log.w(TAG, "MAC_CAMERA_ERROR: stream URL blank")
            return@flow
        }

        Log.i(TAG, "MAC_CAMERA_STREAM_CONNECTING: $streamUrl (token_present=${authToken.isNotBlank()})")

        val req = Request.Builder()
            .url(streamUrl)
            .apply { if (authToken.isNotBlank()) addHeader("Authorization", "Bearer $authToken") }
            .build()

        val call = httpClient.newCall(req)
        try {
            call.execute().use { resp ->
                if (!resp.isSuccessful) {
                    Log.w(TAG, "MAC_CAMERA_ERROR: HTTP ${resp.code}")
                    return@use
                }
                val body = resp.body ?: run {
                    Log.w(TAG, "MAC_CAMERA_ERROR: null body")
                    return@use
                }
                Log.i(TAG, "MAC_CAMERA_STREAM_CONNECTED")

                val contentType = resp.header("Content-Type") ?: ""
                val boundary = extractBoundary(contentType)

                body.byteStream().use { stream ->
                    readFrames(stream, boundary) { jpegBytes ->
                        if (currentCoroutineContext().isActive) {
                            val bm = decodeJpeg(jpegBytes)
                            if (bm != null) emit(bm)
                        }
                    }
                }
            }
        } catch (e: CancellationException) {
            call.cancel()
            Log.d(TAG, "MAC_CAMERA_STREAM_DISCONNECTED: cancelled")
            throw e
        } catch (e: Exception) {
            call.cancel()
            Log.w(TAG, "MAC_CAMERA_ERROR: ${e.javaClass.simpleName} ${e.message}")
        }
    }.flowOn(Dispatchers.IO)

    // ── Internal helpers ──────────────────────────────────────────────────────

    private fun extractBoundary(contentType: String): String {
        val kv = contentType.split(";").map { it.trim() }
        for (part in kv) {
            if (part.startsWith("boundary=", ignoreCase = true)) {
                return part.substringAfter("=").trim().trimStart('-')
            }
        }
        return "frame"
    }

    private inline fun readFrames(stream: InputStream, boundary: String, onFrame: (ByteArray) -> Unit) {
        val reader = BufferedReader(InputStreamReader(stream, Charsets.ISO_8859_1))
        var contentLength = -1
        var inHeaders = false

        while (true) {
            val line = reader.readLine() ?: break

            when {
                line.contains(boundary) -> {
                    contentLength = -1
                    inHeaders = true
                }
                inHeaders && line.startsWith("Content-Length:", ignoreCase = true) -> {
                    contentLength = line.substringAfter(":").trim().toIntOrNull() ?: -1
                }
                inHeaders && line.isEmpty() -> {
                    // End of headers — frame body follows
                    inHeaders = false
                    if (contentLength > 0 && contentLength <= MAX_FRAME_BYTES) {
                        val buf = CharArray(contentLength)
                        var read = 0
                        while (read < contentLength) {
                            val n = reader.read(buf, read, contentLength - read)
                            if (n < 0) return
                            read += n
                        }
                        val bytes = ByteArray(contentLength) { buf[it].code.toByte() }
                        onFrame(bytes)
                        Log.v(TAG, "MAC_CAMERA_FRAME_RECEIVED: ${contentLength}B")
                    } else if (contentLength > MAX_FRAME_BYTES) {
                        Log.w(TAG, "MAC_CAMERA_ERROR: frame $contentLength B exceeds cap — skipping")
                        contentLength = -1
                    }
                    // If contentLength == -1 we skip until the next boundary
                }
            }
        }
    }

    private fun decodeJpeg(bytes: ByteArray): Bitmap? {
        if (bytes.isEmpty()) return null
        return runCatching {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }.getOrNull()
    }
}
