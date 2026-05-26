package com.jarvis.assistant.voice.piper

import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * PiperTtsDebugExporter — saves WAV + JSON metadata for TTS parity debugging.
 *
 * Enable via: PiperTtsDebugExporter.enabled = true
 * Configure output dir via: PiperTtsDebugExporter.configure(dir)
 *   (call this from PiperVoiceManager which has Context)
 *
 * WAV file contains the raw PCM audio (peak-normalised to int16).
 * JSON file contains:
 *   - originalText
 *   - normalizedText
 *   - phonemes (per sentence)
 *   - phonemeIds (first 50)
 *   - noiseScale, lengthScale, noiseW
 *   - sampleRate
 *   - durationMs
 *   - sampleCount
 *   - clippingCount (samples that hit ±1.0 before scale)
 *   - maxAbsRaw (peak value before normalization)
 *   - rmsFirst1000 (RMS of first 1000 samples after normalization)
 */
object PiperTtsDebugExporter {

    private const val TAG = "PiperTtsDebugExporter"

    /** Set true from developer tools / diagnostics screen to enable export. */
    @Volatile var enabled: Boolean = false

    @Volatile private var outputDir: File? = null

    /**
     * Call once from PiperVoiceManager (which owns Context) to set the output
     * directory.  Typically: context.getExternalFilesDir(null) + "/tts_debug".
     */
    fun configure(dir: File) {
        outputDir = dir.also { it.mkdirs() }
        Log.d(TAG, "[DEBUG_EXPORT_CONFIGURED] dir=${dir.absolutePath}")
    }

    data class DebugSnapshot(
        val originalText:   String,
        val normalizedText: String,
        val phonemes:       List<List<String>>,
        val phonemeIds:     LongArray,
        val noiseScale:     Float,
        val lengthScale:    Float,
        val noiseW:         Float,
        val sampleRate:     Int,
        val rawPcm:         FloatArray,
    )

    /** Export [snap] if [enabled] is true and [configure] has been called. */
    fun exportIfEnabled(snap: DebugSnapshot) {
        if (!enabled) return
        val dir = outputDir ?: return
        try {
            val stamp = System.currentTimeMillis()
            val slug = snap.originalText.take(20)
                .replace(Regex("[^a-zA-Z0-9 ]"), "")
                .trim().replace(' ', '_')
            val base = "${stamp}_${slug}"

            writeWav(File(dir, "$base.wav"), snap.rawPcm, snap.sampleRate)
            writeJson(File(dir, "$base.json"), snap)

            Log.i(TAG, "[DEBUG_EXPORT] dir=${dir.absolutePath} base=$base")
        } catch (e: Exception) {
            Log.w(TAG, "[DEBUG_EXPORT_FAILED] ${e.message}")
        }
    }

    private fun writeWav(file: File, pcm: FloatArray, sampleRate: Int) {
        var maxAbs = 0f
        for (v in pcm) {
            val a = if (v < 0) -v else v
            if (a > maxAbs) maxAbs = a
        }
        val norm = maxOf(maxAbs, 0.01f)

        val pcm16 = ShortArray(pcm.size)
        var clipping = 0
        for (i in pcm.indices) {
            var v = pcm[i] / norm
            if (v > 1f)  { v = 1f;  clipping++ }
            if (v < -1f) { v = -1f; clipping++ }
            pcm16[i] = (v * 32767f).toInt().toShort()
        }

        val dataBytes = pcm16.size * 2
        FileOutputStream(file).use { fos ->
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("RIFF".toByteArray())
                putInt(36 + dataBytes)
                put("WAVE".toByteArray())
                put("fmt ".toByteArray())
                putInt(16)             // chunk size
                putShort(1)            // PCM
                putShort(1)            // mono
                putInt(sampleRate)
                putInt(sampleRate * 2) // byte rate
                putShort(2)            // block align
                putShort(16)           // bits per sample
                put("data".toByteArray())
                putInt(dataBytes)
            }
            fos.write(header.array())
            val buf = ByteBuffer.allocate(dataBytes).order(ByteOrder.LITTLE_ENDIAN)
            for (s in pcm16) buf.putShort(s)
            fos.write(buf.array())
        }
    }

    private fun writeJson(file: File, snap: DebugSnapshot) {
        val durationMs = (snap.rawPcm.size * 1000L) / snap.sampleRate.coerceAtLeast(1)

        var maxAbs = 0f
        for (v in snap.rawPcm) {
            val a = if (v < 0) -v else v
            if (a > maxAbs) maxAbs = a
        }
        val norm = maxOf(maxAbs, 0.01f)

        var sumSq = 0.0
        var clipping = 0
        val sampleWindow = minOf(snap.rawPcm.size, 1000)
        for (i in 0 until sampleWindow) {
            val v = snap.rawPcm[i] / norm
            sumSq += (v * v).toDouble()
            if (v > 1f || v < -1f) clipping++
        }
        val rms = Math.sqrt(sumSq / sampleWindow.toDouble().coerceAtLeast(1.0))

        val json = JSONObject().apply {
            put("originalText",          snap.originalText)
            put("normalizedText",        snap.normalizedText)
            put("phonemesPerSentence",   snap.phonemes.joinToString(" | ") { it.joinToString(" ") })
            put("phonemeIdCount",        snap.phonemeIds.size)
            put("phonemeIdsFirst50",     snap.phonemeIds.take(50).joinToString(","))
            put("noiseScale",            snap.noiseScale)
            put("lengthScale",           snap.lengthScale)
            put("noiseW",                snap.noiseW)
            put("sampleRate",            snap.sampleRate)
            put("sampleCount",           snap.rawPcm.size)
            put("durationMs",            durationMs)
            put("maxAbsRaw",             maxAbs)
            put("rmsFirst1000",          String.format("%.4f", rms))
            put("clippingCount",         clipping)
        }
        file.writeText(json.toString(2))
    }

    private fun LongArray.take(n: Int): List<Long> =
        (0 until minOf(size, n)).map { this[it] }
}
