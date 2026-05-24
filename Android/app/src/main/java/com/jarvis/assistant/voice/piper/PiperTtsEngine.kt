package com.jarvis.assistant.voice.piper

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicReference

/**
 * PiperTtsEngine — orchestrates one synth call:
 *   1. phonemize text
 *   2. run ONNX inference
 *   3. stream PCM through [PiperAudioTrack]
 *
 * Single in-flight track at a time.  Calling [speak] while another speak is
 * playing first stops the existing track, then starts the new one — same
 * QUEUE_FLUSH semantic as Android TextToSpeech.
 *
 * All failures bubble out as [Result] values, never thrown.  Callers map
 * Failure → [VoiceFallbackManager.recordFailure] → system TTS.
 */
class PiperTtsEngine(
    private val session: PiperOnnxSession,
    private val config: PiperVoiceConfig,
) {

    companion object {
        private const val TAG = "PiperTtsEngine"
    }

    private val activeTrack: AtomicReference<PiperAudioTrack?> = AtomicReference(null)

    sealed class Result {
        object Ok : Result()
        data class Failure(val reason: String) : Result()
        object Interrupted : Result()
    }

    /**
     * Synthesise + play [text] end-to-end.  Suspends until playback finishes
     * or [stop] is called.  Returns the operator-friendly outcome.
     */
    suspend fun speak(text: String, phonemizer: PiperPhonemizer): Result =
        withContext(Dispatchers.IO) {
            val trimmed = text.trim()
            if (trimmed.isBlank()) return@withContext Result.Ok

            // Phase 4 Fix 13: Text guard.  Piper neural models struggle with
            // pure symbol/emoji strings, often outputting silent nonsense or
            // clicking.  Reject if there are NO alphanumeric characters.
            val hasAlphanumeric = trimmed.any { it.isLetterOrDigit() }
            if (!hasAlphanumeric) {
                Log.d(TAG, "[PIPER_GUARD_REJECT] pure_symbols: \"$trimmed\"")
                return@withContext Result.Failure("symbols_only_rejected")
            }

            // 1. Phonemize.  Empty result = phonemizer not configured (no-op),
            //    or input had no phonemizable content.  Either way, fail
            //    fast so the system-TTS fallback fires immediately.
            val phonemeIdsList = phonemizer.textToPhonemeIds(text, config)
            if (phonemeIdsList.isEmpty()) {
                return@withContext Result.Failure("phonemizer_empty_output")
            }
            val rawPhonemeIds = phonemeIdsList.flatten()
            
            // Format: BOS  [PAD ph]*N  PAD  EOS  →  2*N + 3 tokens total
            // PAD = 0, BOS = 1, EOS = 2
            val PAD = 0L
            val BOS = 1L
            val EOS = 2L

            val tokenCount = (rawPhonemeIds.size * 2) + 3  // was 2*N+2 — off by 1
            val parityTokens = try {
                val arr = LongArray(tokenCount)
                var tidx = 0
                arr[tidx++] = BOS
                for (id in rawPhonemeIds) {
                    arr[tidx++] = PAD
                    arr[tidx++] = id.toLong()
                }
                arr[tidx++] = PAD
                arr[tidx++] = EOS
                Log.d(TAG, "[TOKEN_ARRAY] rawIds=${rawPhonemeIds.size} tokenCount=$tokenCount finalIdx=$tidx")
                arr
            } catch (e: Exception) {
                Log.e(TAG, "[TOKEN_BUILD_FAILED] rawIds=${rawPhonemeIds.size} tokenCount=$tokenCount ${e.javaClass.simpleName}: ${e.message}", e)
                return@withContext Result.Failure("token_build_failed:${e.javaClass.simpleName}")
            }

            if (parityTokens.isEmpty()) return@withContext Result.Failure("phonemizer_empty_output")

            // PARITY DEBUG: Normalized text, phonemes, token IDs
            Log.d(TAG, "[PARITY_DEBUG] Normalized text: \"$text\"")
            Log.d(TAG, "[PARITY_DEBUG] Token IDs: ${parityTokens.joinToString(",")}")

            // 2. ONNX inference — guarded by the session's own timeout.
            val rawPcm = session.synthesize(parityTokens)
                ?: return@withContext Result.Failure(
                    session.lastFailureReason.ifBlank { "inference_failed" }
                )

            // MAC PARITY: Audio Conversion
            // 1. Peak Normalization: audio = audio / max(abs(audio))
            // 2. Clip to [-1.0, 1.0]
            // 3. pcm16 = audio * 32767.0
            
            if (rawPcm.isEmpty()) return@withContext Result.Failure("empty_inference_output")
            
            var maxAbs = 0.0f
            for (v in rawPcm) {
                val absV = if (v < 0) -v else v
                if (absV > maxAbs) maxAbs = absV
            }
            
            // Safeguard against exploding the noise floor on near-silent utterances.
            maxAbs = maxOf(maxAbs, 0.01f)
            
            val pcm16 = ShortArray(rawPcm.size)
            if (maxAbs > 0) {
                for (i in rawPcm.indices) {
                    var v = rawPcm[i] / maxAbs // Normalize
                    if (v > 1.0f) v = 1.0f    // Clip
                    if (v < -1.0f) v = -1.0f
                    pcm16[i] = (v * 32767.0f).toInt().toShort()
                }
            }

            // PARITY DEBUG: RMS/min/max, first 20 samples
            var sumSq = 0.0
            var minV = 0.0f
            var maxV = 0.0f
            for (i in 0 until minOf(rawPcm.size, 1000)) {
                val v = rawPcm[i]
                sumSq += (v * v).toDouble()
                if (v < minV) minV = v
                if (v > maxV) maxV = v
            }
            val rms = Math.sqrt(sumSq / minOf(rawPcm.size, 1000).toDouble())
            Log.d(TAG, "[PARITY_DEBUG] Output RMS=${String.format("%.4f", rms)} min=${String.format("%.4f", minV)} max=${String.format("%.4f", maxV)}")
            Log.d(TAG, "[PARITY_DEBUG] First 20 float samples: ${rawPcm.take(20).joinToString(", ") { String.format("%.4f", it) }}")
            Log.d(TAG, "[PARITY_DEBUG] AudioTrack SampleRate=${config.sampleRate} mono PCM16")

            // Append 20 ms of leading silence (hardware spin-up) and 
            // 100 ms of trailing silence (drain buffer).
            val leadingSilenceSamples = (config.sampleRate * 0.02f).toInt()
            val trailingSilenceSamples = (config.sampleRate * 0.10f).toInt()
            val paddedPcm = ShortArray(leadingSilenceSamples + pcm16.size + trailingSilenceSamples)
            System.arraycopy(pcm16, 0, paddedPcm, leadingSilenceSamples, pcm16.size)

            // 3. Stream playback.  Stop any in-flight track first (queue-flush).
            stopActive()
            val newTrack = PiperAudioTrack(config.sampleRate)
            if (!newTrack.prepare()) {
                newTrack.release()
                return@withContext Result.Failure("audiotrack_prepare_failed")
            }
            activeTrack.set(newTrack)
            PiperDiagnostics.update {
                it.copy(lastPlaybackStarted = true, lastPlaybackCompleted = false)
            }
            val finished = try {
                newTrack.playBlocking(paddedPcm)
            } finally {
                if (activeTrack.compareAndSet(newTrack, null)) {
                    newTrack.release()
                }
            }
            PiperDiagnostics.update {
                it.copy(lastPlaybackCompleted = finished && !newTrack.isStopped)
            }
            if (newTrack.isStopped || !finished) {
                Log.d(TAG, "[PIPER_SPEAK_INTERRUPTED]")
                Result.Interrupted
            } else {
                Log.d(TAG, "[PIPER_SPEAK_DONE] chars=${text.length} samples=${pcm16.size} padded=${paddedPcm.size}")
                Result.Ok
            }
        }

    /** Stop any in-flight playback immediately.  Safe from any thread. */
    fun stop() {
        stopActive()
    }

    private fun stopActive() {
        val t = activeTrack.getAndSet(null) ?: return
        try {
            t.stop()
            t.release()
        } catch (e: Exception) {
            Log.w(TAG, "[PIPER_STOP_EXCEPTION] ${e.message}")
        }
    }

    /** Final teardown — call when switching voices or shutting the manager. */
    fun shutdown() {
        stopActive()
        session.close()
    }
}
