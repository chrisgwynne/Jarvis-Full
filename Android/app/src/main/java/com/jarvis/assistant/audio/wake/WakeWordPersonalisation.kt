package com.jarvis.assistant.audio.wake

import android.content.Context
import android.util.Log
import java.io.File

/**
 * WakeWordPersonalisation — scaffold for owner-voice biasing of the wake-word
 * detector.
 *
 * STATUS: PARTIAL.  Sample storage + threshold-bias plumbing are in place, but
 * the audio-embedding comparison that actually does the personalised match
 * still needs to be implemented.
 *
 * RATIONALE:
 *   The default openWakeWord model fires for any voice that sounds like
 *   "Hey Jarvis".  A roommate's voice, a TV ad, or a child shouting at the
 *   phone can all wake the assistant.  Owner-voice biasing collects 3–5
 *   short samples of the owner saying the wake phrase, extracts an embedding
 *   for each, and at runtime multiplies the detector score by a similarity
 *   factor against those embeddings.
 *
 * WIRING REQUIRED TO COMPLETE:
 *   1. Build a Settings flow that calls [recordSample] with a 1.5 s mono 16 kHz
 *      PCM clip three times in succession ("Say 'Hey Jarvis' once… again…").
 *   2. Implement [scoreSimilarity] using the audio-feature pipeline already
 *      used by the TFLite wake-word detector (mel-spectrogram → encoder
 *      embedding).  Cosine similarity against each saved sample, take the max.
 *   3. Plumb [scoreSimilarity] into TFLiteWakeWordDetector so wake fires only
 *      when raw_score × similarity ≥ threshold.
 *
 * SECURITY:
 *   Samples are written to app-private storage and never leave the device.
 *   They are short (1.5 s) and cropped to just the wake phrase.
 */
class WakeWordPersonalisation(context: Context) {

    companion object {
        private const val TAG          = "WakeWordPersonalisation"
        private const val DIR_NAME     = "wake_samples"
        private const val MAX_SAMPLES  = 5
        /** Minimum similarity to count as the owner's voice.  Tune after
         *  the embedding implementation lands.  Values <0.6 are noisy. */
        const val DEFAULT_THRESHOLD    = 0.72f
    }

    private val sampleDir: File = File(context.filesDir, DIR_NAME).apply { mkdirs() }

    /** True when at least one enrolment sample exists. */
    val isEnrolled: Boolean
        get() = sampleDir.listFiles()?.isNotEmpty() == true

    val sampleCount: Int
        get() = sampleDir.listFiles()?.size ?: 0

    /**
     * Save a raw 16 kHz mono PCM16 audio clip as a new wake-phrase sample.
     * Oldest samples roll off once the cap is hit so a user can re-enrol
     * without manually clearing.
     */
    fun recordSample(pcm: ShortArray) {
        try {
            val files = sampleDir.listFiles()?.sortedBy { it.lastModified() } ?: emptyList()
            if (files.size >= MAX_SAMPLES) {
                files.first().delete()
            }
            val out = File(sampleDir, "sample_${System.currentTimeMillis()}.pcm")
            out.outputStream().use { fos ->
                val buf = java.nio.ByteBuffer.allocate(pcm.size * 2)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                pcm.forEach { buf.putShort(it) }
                fos.write(buf.array())
            }
            Log.d(TAG, "[WAKE_SAMPLE_SAVED] file=${out.name} bytes=${out.length()}")
        } catch (e: Exception) {
            Log.w(TAG, "[WAKE_SAMPLE_SAVE_FAILED] ${e.message}")
        }
    }

    /** Remove all enrolment samples. */
    fun clearEnrolment() {
        sampleDir.listFiles()?.forEach { it.delete() }
        Log.d(TAG, "[WAKE_ENROLMENT_CLEARED]")
    }

    /**
     * Score [candidate] (a candidate wake event's audio buffer) against the
     * saved enrolment samples.  Returns 1.0 when no samples exist
     * (so the detector behaves identically to the unpersonalised baseline),
     * otherwise a value in 0..1.
     *
     * STUB: returns 1.0 until the embedding extractor is implemented.
     * Wire the same MFCC / mel-spec → encoder path that TFLiteWakeWordDetector
     * uses; cosine-similarity the embeddings; max over saved samples.
     */
    @Suppress("UnusedPrivateMember")
    fun scoreSimilarity(candidate: ShortArray): Float {
        if (!isEnrolled) return 1.0f
        // TODO: implement embedding cosine similarity.
        return 1.0f
    }
}
