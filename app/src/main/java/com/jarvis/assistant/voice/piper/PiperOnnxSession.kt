package com.jarvis.assistant.voice.piper

import android.os.Debug
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.nio.FloatBuffer
import java.nio.LongBuffer

/**
 * PiperOnnxSession — wraps the lifecycle of a single ONNX Runtime session
 * for one Piper voice.
 *
 * Constructed lazily — the session is only built on the first synth call,
 * not at app boot, so cold-start latency is paid by the user who actually
 * triggers TTS rather than every device user.
 *
 * Failure modes mapped to clean strings (no stack traces leak to TTS):
 *   - File missing / unreadable → "model_file_unavailable"
 *   - Allocation failure / OOM → "model_load_oom"
 *   - Session build > [LOAD_TIMEOUT_MS] → "model_load_timeout"
 *   - Inference exception → "inference_failed"
 *   - Inference > [INFER_TIMEOUT_MS] → "inference_timeout"
 *
 * Uses reflection internally to access ONNX Runtime classes — keeps the
 * runtime as a soft dependency.  If the dep is missing at runtime (which
 * shouldn't happen given build.gradle, but defensive programming) we fail
 * with `"onnx_runtime_missing"` instead of crashing.
 */
class PiperOnnxSession(
    private val modelFile: File,
    private val config: PiperVoiceConfig,
) {

    companion object {
        private const val TAG = "PiperOnnxSession"
        const val LOAD_TIMEOUT_MS:  Long = 10_000L
        const val INFER_TIMEOUT_MS: Long = 8_000L
        /** Conservative thread count to avoid eating cores during STT. */
        private const val INTRA_OP_THREADS = 2
        /**
         * Safety cap on phoneme tensor size.  A single utterance of more
         * than ~6 000 phonemes is almost certainly a malformed input —
         * Piper inference is O(N²) in attention so this also caps worst-
         * case latency.
         */
        const val MAX_PHONEMES_PER_UTTERANCE: Int = 6_000
        /** Reject PCM outputs longer than this many seconds — model regression. */
        const val MAX_PCM_SECONDS: Int = 30
        /** Cap on the NaN/Inf scan to keep validation O(1). */
        const val MAX_SCAN_SAMPLES: Int = 50_000
    }

    @Volatile private var ortEnv:     Any? = null
    @Volatile private var ortSession: Any? = null
    @Volatile private var loadFailureReason: String = ""

    val isLoaded: Boolean get() = ortSession != null
    val lastFailureReason: String get() = loadFailureReason

    /**
     * Build the session.  Suspends — call from a background dispatcher.
     * Returns true on success, false on any failure (reason in
     * [lastFailureReason]).  Idempotent: returns true immediately if
     * already loaded.
     */
    suspend fun ensureLoaded(): Boolean = withContext(Dispatchers.IO) {
        if (ortSession != null) return@withContext true
        if (!modelFile.isFile) {
            loadFailureReason = "model_file_unavailable"
            Log.w(TAG, "[ONNX_LOAD_SKIPPED] reason=$loadFailureReason path=${modelFile.absolutePath}")
            return@withContext false
        }

        val memBefore  = Debug.getNativeHeapAllocatedSize() + Runtime.getRuntime().totalMemory()
        val tStart     = System.currentTimeMillis()
        PiperDiagnostics.update {
            it.copy(memoryBeforeLoadBytes = memBefore)
        }

        val ok = withTimeoutOrNull(LOAD_TIMEOUT_MS) {
            try {
                buildSessionViaReflection()
                true
            } catch (e: ClassNotFoundException) {
                loadFailureReason = "onnx_runtime_missing"
                Log.e(TAG, "[ONNX_LOAD_FAILED] reason=$loadFailureReason ${e.message}")
                false
            } catch (e: OutOfMemoryError) {
                loadFailureReason = "model_load_oom"
                Log.e(TAG, "[ONNX_LOAD_FAILED] reason=$loadFailureReason")
                false
            } catch (e: Exception) {
                loadFailureReason = "model_load_exception"
                Log.e(TAG, "[ONNX_LOAD_FAILED] reason=$loadFailureReason ${e.message}")
                false
            }
        } ?: run {
            loadFailureReason = "model_load_timeout"
            Log.e(TAG, "[ONNX_LOAD_FAILED] reason=$loadFailureReason after_ms=$LOAD_TIMEOUT_MS")
            false
        }

        val memAfter  = Debug.getNativeHeapAllocatedSize() + Runtime.getRuntime().totalMemory()
        val durationMs = System.currentTimeMillis() - tStart
        PiperDiagnostics.update {
            it.copy(
                memoryAfterLoadBytes = memAfter,
                loadDurationMs       = durationMs,
                onnxLoaded           = ok,
                modelPath            = modelFile.absolutePath,
                modelSizeBytes       = modelFile.length(),
                sampleRate           = config.sampleRate,
            )
        }
        if (ok) Log.d(TAG, "[ONNX_LOAD_DONE] ms=$durationMs " +
            "heapDelta=${memAfter - memBefore} path=${modelFile.absolutePath}")
        ok
    }

    /**
     * Run inference on [phonemeIds].  Returns float audio in `[-1, 1]` at
     * [PiperVoiceConfig.sampleRate], or null on any failure.
     *
     * Inputs the model expects (mainline Piper):
     *   input        int64 [B, T]
     *   input_lengths int64 [B]
     *   scales       float32 [3]   (noise_scale, length_scale, noise_w)
     *   sid          int64 [B]     (only when num_speakers > 1)
     */
    suspend fun synthesize(phonemeIds: LongArray): FloatArray? = withContext(Dispatchers.IO) {
        val session = ortSession ?: run {
            loadFailureReason = "session_not_loaded"
            Log.w(TAG, "[ONNX_SYNTH_SKIPPED] reason=$loadFailureReason")
            return@withContext null
        }
        // Input validation — bail fast on bad tensor shape so the runtime
        // never invokes the model on garbage.
        if (phonemeIds.isEmpty()) {
            loadFailureReason = "inference_bad_tensor"
            Log.w(TAG, "[ONNX_SYNTH_SKIPPED] reason=$loadFailureReason cause=empty_phonemes")
            return@withContext null
        }
        if (phonemeIds.size > MAX_PHONEMES_PER_UTTERANCE) {
            loadFailureReason = "inference_bad_tensor"
            Log.w(TAG, "[ONNX_SYNTH_SKIPPED] reason=$loadFailureReason " +
                "cause=phonemes_too_long count=${phonemeIds.size} max=$MAX_PHONEMES_PER_UTTERANCE")
            return@withContext null
        }

        val inputShape = "[1, ${phonemeIds.size}]"
        PiperDiagnostics.update { it.copy(lastInputTensorShape = inputShape) }

        val tStart = System.currentTimeMillis()
        val pcm = withTimeoutOrNull(INFER_TIMEOUT_MS) {
            try {
                runInferenceViaReflection(session, phonemeIds)
            } catch (e: CancellationException) {
                throw e   // honour coroutine cancellation
            } catch (e: Exception) {
                Log.e(TAG, "[ONNX_INFER_FAILED] ${e.message}")
                null
            }
        }
        val durationMs = System.currentTimeMillis() - tStart
        PiperDiagnostics.update {
            it.copy(
                lastInferenceMs    = durationMs,
                lastInferenceChars = phonemeIds.size,
            )
        }
        if (pcm == null) {
            // Distinguish timeout vs other failure via the elapsed time.
            loadFailureReason = if (durationMs >= INFER_TIMEOUT_MS)
                "inference_timeout" else "inference_failed"
            Log.w(TAG, "[ONNX_INFER_TIMEOUT_OR_FAIL] reason=$loadFailureReason " +
                "ms=$durationMs phonemes=${phonemeIds.size}")
            return@withContext null
        }
        // Output validation.  PCM must be (a) non-empty, (b) finite-valued,
        // (c) a plausible size for the sample rate × utterance length.
        val validation = validatePcm(pcm, phonemeIds.size)
        if (validation != null) {
            loadFailureReason = validation
            Log.w(TAG, "[ONNX_INFER_INVALID_PCM] reason=$loadFailureReason " +
                "samples=${pcm.size} phonemes=${phonemeIds.size}")
            return@withContext null
        }

        val pcmDurationMs = (pcm.size * 1000L) / config.sampleRate.coerceAtLeast(1)
        PiperDiagnostics.update {
            it.copy(
                lastPcmSamples    = pcm.size,
                lastPcmDurationMs = pcmDurationMs,
            )
        }
        Log.d(TAG, "[ONNX_INFER_DONE] ms=$durationMs samples=${pcm.size} " +
            "phonemes=${phonemeIds.size} pcmDurationMs=$pcmDurationMs")
        pcm
    }

    /**
     * Return null when [pcm] passes every output check, otherwise a
     * specific failure-reason string the caller publishes via the fallback
     * manager.  Cheap — bounded by [maxScanSamples] to avoid scanning
     * gigantic outputs.
     */
    private fun validatePcm(pcm: FloatArray, phonemeCount: Int): String? {
        if (pcm.isEmpty()) return "inference_empty_output"
        // Absurd-size guard: a single utterance over 30 s of audio is
        // almost certainly a model regression — reject so we fall back.
        val maxSamples = config.sampleRate * MAX_PCM_SECONDS
        if (pcm.size > maxSamples) return "inference_pcm_too_large"
        // NaN/Inf scan.  Bounded to the first ~50k samples — anything
        // bad earlier than that will fire; deeper drift is rare enough
        // not to justify O(N) on every call.
        val scanLimit = minOf(pcm.size, MAX_SCAN_SAMPLES)
        for (i in 0 until scanLimit) {
            val v = pcm[i]
            if (v.isNaN() || v.isInfinite()) return "inference_invalid_pcm"
        }
        return null
    }

    /** Release the session promptly — call when switching voices. */
    @Synchronized
    fun close() {
        try {
            ortSession?.let { invokeClose(it) }
            ortEnv?.let { invokeClose(it) }
        } catch (e: Exception) {
            Log.w(TAG, "[ONNX_CLOSE_FAILED] ${e.message}")
        }
        ortSession = null
        ortEnv = null
        Log.d(TAG, "[ONNX_CLOSED]")
    }

    // ── Reflection adapter (keeps ONNX as a soft dependency) ────────────────

    /**
     * Builds the session via reflection so a missing dependency degrades to
     * "onnx_runtime_missing" rather than a hard ClassNotFoundError at load
     * time.  Mirrors:
     *   val env = OrtEnvironment.getEnvironment()
     *   val opts = OrtSession.SessionOptions() // Default options
     *   ortSession = env.createSession(modelFile.absolutePath, opts)
     */
    private fun buildSessionViaReflection() {
        val ortEnvCls   = Class.forName("ai.onnxruntime.OrtEnvironment")
        val ortSessCls  = Class.forName("ai.onnxruntime.OrtSession")
        val sessOptsCls = Class.forName("ai.onnxruntime.OrtSession\$SessionOptions")

        val env = ortEnvCls.getMethod("getEnvironment").invoke(null)
        val opts = sessOptsCls.getDeclaredConstructor().newInstance()
        
        // MAC PARITY: default SessionOptions, CPUExecutionProvider only (default)
        // No threads/optimization overrides here.

        val createSession = ortEnvCls.getMethod(
            "createSession",
            String::class.java,
            sessOptsCls,
        )
        ortSession = createSession.invoke(env, modelFile.absolutePath, opts)
        ortEnv = env
    }

    /**
     * Build inputs + run + extract PCM.  Reflection-only so a runtime
     * version mismatch fails with a clean log line, not a NoSuchMethodError
     * crash.
     */
    private fun runInferenceViaReflection(session: Any, phonemeIds: LongArray): FloatArray? {
        val ortEnvCls = Class.forName("ai.onnxruntime.OrtEnvironment")
        val tensorCls = Class.forName("ai.onnxruntime.OnnxTensor")
        val env = ortEnvCls.getMethod("getEnvironment").invoke(null)

        // input — int64 [1, T]
        val inputBuf = LongBuffer.wrap(phonemeIds)
        val inputShape = longArrayOf(1L, phonemeIds.size.toLong())
        val inputTensor = tensorCls.getMethod(
            "createTensor", ortEnvCls, LongBuffer::class.java, LongArray::class.java,
        ).invoke(null, env, inputBuf, inputShape)

        // input_lengths — int64 [1]
        val lengthsBuf = LongBuffer.wrap(longArrayOf(phonemeIds.size.toLong()))
        val lengthsShape = longArrayOf(1L)
        val lengthsTensor = tensorCls.getMethod(
            "createTensor", ortEnvCls, LongBuffer::class.java, LongArray::class.java,
        ).invoke(null, env, lengthsBuf, lengthsShape)

        // 3. Scales — float32 [3]
        val scales = floatArrayOf(
            config.noiseScale,
            config.lengthScale,
            config.noiseW
        )
        val scalesBuf = FloatBuffer.wrap(scales)
        val scalesShape = longArrayOf(3L)
        val scalesTensor = tensorCls.getMethod(
            "createTensor", ortEnvCls, FloatBuffer::class.java, LongArray::class.java,
        ).invoke(null, env, scalesBuf, scalesShape)

        val inputs = mutableMapOf<String, Any>(
            "input"         to inputTensor,
            "input_lengths" to lengthsTensor,
            "scales"        to scalesTensor,
        )
        // MAC PARITY: NO speaker ID tensor even if numSpeakers > 1
        // if (!config.isSingleSpeaker) { ... }

        return try {
            val runMethod = session.javaClass.getMethod("run", Map::class.java)
            val result = runMethod.invoke(session, inputs)
                ?: return null

            // Result is OrtSession.Result (Iterable<Map.Entry<String, OnnxValue>>).
            // We want the first output's value.
            val iterator = (result as Iterable<*>).iterator()
            val first = iterator.next() as? Map.Entry<*, *> ?: return null
            val onnxValue = first.value ?: return null

            extractFloatArray(onnxValue)
        } finally {
            inputs.values.forEach { invokeClose(it) }
        }
    }

    /**
     * Extract float[] from an OnnxTensor whose backing storage is float32.
     * Mainline Piper output is `[1, 1, T_audio]` or `[1, T_audio]`.
     */
    private fun extractFloatArray(onnxValue: Any): FloatArray? {
        val getValueMethod = onnxValue.javaClass.getMethod("getValue")
        val raw = getValueMethod.invoke(onnxValue) ?: return null
        return flattenFloats(raw)
    }

    private fun flattenFloats(raw: Any): FloatArray? {
        return when (raw) {
            is FloatArray             -> raw
            is Array<*>               -> {
                val parts = raw.mapNotNull { it?.let(::flattenFloats) }
                if (parts.isEmpty()) null
                else FloatArray(parts.sumOf { it.size }).also { out ->
                    var off = 0
                    for (p in parts) {
                        System.arraycopy(p, 0, out, off, p.size)
                        off += p.size
                    }
                }
            }
            else                      -> null
        }
    }

    private fun invokeClose(target: Any) {
        try {
            target.javaClass.getMethod("close").invoke(target)
        } catch (_: Exception) { /* best-effort */ }
    }
}
