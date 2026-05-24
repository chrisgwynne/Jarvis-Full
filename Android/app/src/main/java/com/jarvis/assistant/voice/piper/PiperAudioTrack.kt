package com.jarvis.assistant.voice.piper

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * PiperAudioTrack — streaming AudioTrack wrapper for Piper PCM output.
 *
 * Streaming mode (not static buffer) so:
 *   - playback can start while inference is still producing samples (future
 *     enhancement — current code receives a complete FloatArray and writes
 *     it in chunks),
 *   - barge-in can stop playback instantly without waiting for the buffer
 *     to drain,
 *   - we never allocate a 100 MB monolithic PCM buffer for a long reply.
 *
 * Thread model: write happens on the IO dispatcher.  [stop] is safe to
 * call from any thread; sets a flag the writer checks every chunk.
 *
 * Lifetime: one instance per utterance.  Always call [release] when done
 * (success, failure, or cancellation) — leaks of native AudioTrack instances
 * will exhaust the audio HAL after a few hundred utterances.
 */
class PiperAudioTrack(
    private val sampleRate: Int,
) {
    companion object {
        private const val TAG = "PiperAudioTrack"
        /** Chunk size in samples — 4096 (~185ms) for stable throughput. */
        private const val CHUNK_SAMPLES = 4096
    }

    private val stopFlag = AtomicBoolean(false)
    @Volatile private var track: AudioTrack? = null

    /** True once [stop] was called.  Reset on a fresh instance. */
    val isStopped: Boolean get() = stopFlag.get()

    /**
     * Build a streaming AudioTrack for [sampleRate].  Returns false if the
     * platform refuses (rare — AudioTrack creation can fail on locked-down
     * devices); caller logs and falls back.
     */
    fun prepare(): Boolean {
        return try {
            val minBuf = AudioTrack.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            // Platform sometimes returns ERROR / ERROR_BAD_VALUE (-1/-2) when
            // 16BIT isn't supported — treat as failure.
            if (minBuf <= 0) {
                Log.w(TAG, "[AUDIOTRACK_PREPARE_FAILED] minBufferSize=$minBuf sampleRate=$sampleRate")
                return false
            }
            // minBuf is the bytes needed for one hardware-period; we want a
            // deeper buffer (8x) to avoid underruns when the IO thread is
            // pre-empted. This stops the audio from "shaking" or stuttering.
            val bufBytes = (minBuf * 8).coerceAtLeast(CHUNK_SAMPLES * 2 * 8)
            track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(bufBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            true
        } catch (e: Exception) {
            Log.w(TAG, "[AUDIOTRACK_PREPARE_FAILED] ${e.message}")
            false
        }
    }

    /**
     * Write the entire [pcm] in chunks.  Returns true if the full buffer was
     * written, false if [stop] interrupted us.  Safe to call once per
     * instance; subsequent calls fail with [IllegalStateException]-style
     * behaviour from the platform AudioTrack (we just bail).
     */
    fun playBlocking(pcm: ShortArray): Boolean {
        val t = track ?: run {
            Log.w(TAG, "[AUDIOTRACK_PLAY_NO_TRACK]")
            return false
        }
        return try {
            t.play()
            var offset = 0
            var totalWritten = 0
            while (offset < pcm.size) {
                if (stopFlag.get()) {
                    Log.d(TAG, "[AUDIOTRACK_INTERRUPTED] at_sample=$offset")
                    return false
                }
                val n = minOf(CHUNK_SAMPLES, pcm.size - offset)
                val written = t.write(pcm, offset, n)
                if (written < 0) {
                    Log.w(TAG, "[AUDIOTRACK_WRITE_ERROR] code=$written")
                    return false
                }
                offset += written
                totalWritten += written
            }

            // Signal end-of-data.
            try {
                t.stop()
                // Wait for the hardware to actually play the samples we wrote.
                // Releasing the track too early cuts off the end (drain latency).
                val startWait = System.currentTimeMillis()
                val timeout = 2000L // 2s safety cap
                while (t.playbackHeadPosition < totalWritten && 
                       (System.currentTimeMillis() - startWait) < timeout) {
                    if (stopFlag.get()) break
                    Thread.sleep(20)
                }
            } catch (_: Exception) {}
            true
        } catch (e: Exception) {
            Log.w(TAG, "[AUDIOTRACK_PLAY_EXCEPTION] ${e.message}")
            false
        }
    }

    /** Signal the writer to bail.  Safe from any thread. */
    fun stop() {
        if (!stopFlag.compareAndSet(false, true)) return
        try {
            track?.pause()
            track?.flush()
        } catch (_: Exception) { /* may already be stopped */ }
        Log.d(TAG, "[AUDIOTRACK_STOP_REQUESTED]")
    }

    /** Release the native AudioTrack.  Idempotent. */
    fun release() {
        val t = track ?: return
        track = null
        try { t.stop() } catch (_: Exception) {}
        try { t.release() } catch (_: Exception) {}
        Log.d(TAG, "[AUDIOTRACK_RELEASED]")
    }
}
