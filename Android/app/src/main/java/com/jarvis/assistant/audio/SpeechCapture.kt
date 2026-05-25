package com.jarvis.assistant.audio

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import com.jarvis.assistant.util.LatencyTracker
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/**
 * SpeechCapture — wraps Android's built-in SpeechRecognizer as a suspend function.
 *
 * WHY ANDROID'S BUILT-IN RECOGNISER?
 *   No API key, no network cost (can use on-device model on Android 13+), and
 *   it has built-in VAD (Voice Activity Detection) that handles end-of-speech
 *   detection reliably — better than a DIY energy-threshold VAD for most phones.
 *
 * IMPORTANT THREADING CONSTRAINT:
 *   SpeechRecognizer MUST be created, used, and destroyed on the MAIN thread.
 *   We enforce this by always posting via Handler(Looper.getMainLooper()).
 *
 * MICROPHONE HANDOFF:
 *   WakeWordDetector must have released AudioRecord BEFORE listen() is called,
 *   because SpeechRecognizer opens its own mic session.
 *
 * ERROR HANDLING:
 *   ERROR_NO_MATCH (7) and ERROR_SPEECH_TIMEOUT (6) = user spoke but no result
 *   or didn't speak at all → we return "" so the pipeline retries gracefully.
 *   Other errors (hardware, recognizer crash) → return "" with a log warning.
 */
class SpeechCapture(private val context: Context) {

    companion object {
        private const val TAG = "SpeechCapture"

        // ── Fast VAD ─────────────────────────────────────────────────────────
        // After at least FAST_VAD_MIN_PARTIAL_CHARS characters appear in a
        // partial result, if RMS stays below the active threshold for
        // FAST_VAD_SILENCE_MS, we call stopListening() ourselves rather than
        // waiting for the OS silence timer (600–1500 ms).
        // Set FAST_VAD_ENABLED = false to revert to OS-only silence detection.
        private const val FAST_VAD_ENABLED           = true
        private const val FAST_VAD_MIN_PARTIAL_CHARS = 2       // at least 2 chars of transcript

        // Default (phone-mic) thresholds.  Overridden per-profile via setMicProfile().
        private const val DEFAULT_VAD_RMS_THRESHOLD  = 2.0f
        private const val DEFAULT_VAD_SILENCE_MS     = 350L

        // Mic retry delays (ms) used when SpeechRecognizer returns ERROR_AUDIO
        // because the previous session's mic hasn't released yet.  Bumped
        // from 150/150/200 (500 ms total) to cover slower AudioRecord
        // releases on older / power-saving devices — the wake detector's
        // teardown runs asynchronously on Dispatchers.Default and can take
        // 700–1200 ms before the mic is actually free.  When the mic is
        // available the first attempt succeeds immediately, so this
        // expanded ceiling only costs latency on a genuine handoff race.
        private val MIC_RETRY_DELAYS = longArrayOf(200L, 300L, 500L, 700L)
    }

    // Active per-profile thresholds — updated by setMicProfile().
    @Volatile private var activeVadRmsThreshold  = DEFAULT_VAD_RMS_THRESHOLD
    @Volatile private var activeVadSilenceMs     = DEFAULT_VAD_SILENCE_MS
    @Volatile private var activeCompleteSilenceMs       = 1_200L
    @Volatile private var activePossiblyCompleteSilenceMs = 600L

    /**
     * Apply per-profile VAD thresholds based on the detected microphone input path.
     * Call this whenever the headset connection state changes (before [listen]).
     */
    fun setMicProfile(profile: MicInputProfiler.MicProfile) {
        activeVadRmsThreshold        = MicInputProfiler.vadThreshold(profile)
        activeVadSilenceMs           = MicInputProfiler.vadSilenceMs(profile)
        activeCompleteSilenceMs      = MicInputProfiler.completeSilenceMs(profile)
        activePossiblyCompleteSilenceMs = MicInputProfiler.possiblyCompleteSilenceMs(profile)
        Log.d(TAG, "[VAD_THRESHOLD_SELECTED] profile=$profile " +
            "rms=$activeVadRmsThreshold silenceMs=$activeVadSilenceMs " +
            "completeSilenceMs=$activeCompleteSilenceMs")
    }

    private var recognizer: SpeechRecognizer? = null
    private val isCleaningUp = java.util.concurrent.atomic.AtomicBoolean(false)
    private val mainHandler = Handler(Looper.getMainLooper())
    // Ensures only one listen() is in flight at a time — SpeechRecognizer
    // keeps a single mic session and parallel calls stomp the 'recognizer'
    // field mid-run.
    private val listenLock = Mutex()

    // Set by onError() inside the current listenInternal() call; read by
    // listen() immediately after listenInternal() returns to decide whether
    // to retry.  Protected by listenLock — only one listen() in flight.
    @Volatile private var lastErrorCode: Int = 0

    /**
     * Optional N-best selector.  When set, [listenInternal] passes every
     * candidate the recogniser produced (plus confidences when available) and
     * uses the returned string as the final transcript.  JarvisRuntime wires
     * this up to [com.jarvis.assistant.audio.stt.TranscriptCorrector].
     *
     * If null, the first candidate is returned (legacy behaviour).
     */
    @Volatile private var nbestSelector: ((List<String>, FloatArray?) -> String)? = null

    fun setNbestSelector(selector: (List<String>, FloatArray?) -> String) {
        nbestSelector = selector
    }

    /**
     * Listen for one utterance and return the transcript.
     *
     * [onReady] is invoked on the main thread the moment the SpeechRecognizer
     * reports it is ready to receive audio (onReadyForSpeech).  Use this to
     * start any concurrent AudioRecord AFTER the recognizer has claimed the
     * microphone — starting an AudioRecord before that point can preempt the
     * recognition service on some devices.
     *
     * Returns "" if nothing was heard, recognition failed, or the 30 s hard
     * timeout fires.  Cancellation-safe.
     */
    suspend fun listen(
        onReady: (() -> Unit)? = null,
        /**
         * When true, constructs an on-device-only recognizer on API 31+ via
         * [SpeechRecognizer.createOnDeviceSpeechRecognizer].  Guarantees no
         * network round-trip even if Google's cloud model would give a better
         * answer — use when connectivity is known to be unavailable.  On API
         * < 31 this flag has no effect: the cloud recognizer already prefers
         * offline via [RecognizerIntent.EXTRA_PREFER_OFFLINE] below, which is
         * a hint rather than a hard guarantee.
         */
        forceOffline: Boolean = false
    ): String = listenLock.withLock {
        val t0 = SystemClock.elapsedRealtime()

        for (attempt in 0..MIC_RETRY_DELAYS.size) {
            if (attempt > 0) {
                val d = MIC_RETRY_DELAYS[attempt - 1]
                Log.w(TAG, "[STT_MIC_RETRY] attempt=$attempt delay=${d}ms " +
                    "+${SystemClock.elapsedRealtime() - t0}ms total")
                delay(d)
            }

            lastErrorCode = 0
            val result = withTimeoutOrNull(30_000L) {
                listenInternal(
                    onReady      = if (attempt == 0) onReady else null,
                    forceOffline = forceOffline
                )
            } ?: run {
                Log.w(TAG, "SpeechCapture timed out after 30 s — returning empty")
                cancel()
                return@withLock ""
            }

            // ERROR_AUDIO (3): the previous SpeechRecognizer session hasn't
            // released the mic yet.  Retry after a short wait instead of
            // failing immediately.  Only retry for the first N attempts.
            if (lastErrorCode == SpeechRecognizer.ERROR_AUDIO && attempt < MIC_RETRY_DELAYS.size) {
                Log.w(TAG, "[STT_MIC_RETRY] ERROR_AUDIO on attempt $attempt — " +
                    "mic not yet released, will retry")
                continue
            }

            if (attempt > 0) {
                Log.d(TAG, "[STT_MIC_RETRY] succeeded on attempt $attempt " +
                    "+${SystemClock.elapsedRealtime() - t0}ms")
            }
            return@withLock result
        }
        ""
    }

    private suspend fun listenInternal(
        onReady: (() -> Unit)? = null,
        forceOffline: Boolean = false
    ): String = suspendCancellableCoroutine { cont ->

        isCleaningUp.set(false)
        val listenStartMs = SystemClock.elapsedRealtime()
        // Some recognisers (notably Pixel Speech Services on recent builds)
        // fire onEndOfSpeech twice — once when the user stops speaking and
        // again immediately before onResults.  Guard so callers see it once.
        val endOfSpeechFired = java.util.concurrent.atomic.AtomicBoolean(false)

        // Snapshot thresholds at call time so they can't shift mid-utterance.
        val vadRmsThreshold  = activeVadRmsThreshold
        val vadSilenceMs     = activeVadSilenceMs
        val completeSilenceMs       = activeCompleteSilenceMs
        val possiblyCompleteSilenceMs = activePossiblyCompleteSilenceMs

        // Fast-VAD state — mutated only on the main thread inside the listener.
        var partialCharCount = 0
        var vadArmed         = false
        var speechStartLogged = false

        // Runnable posted after vadSilenceMs of quiet following a partial result.
        // Calls stopListening() to cut the OS silence wait.
        val vadRunnable = Runnable {
            if (vadArmed && partialCharCount >= FAST_VAD_MIN_PARTIAL_CHARS) {
                Log.d(TAG, "[FAST_VAD] silence ${vadSilenceMs}ms after partial " +
                    "(chars=$partialCharCount) — calling stopListening() " +
                    "+${SystemClock.elapsedRealtime() - listenStartMs}ms")
                recognizer?.stopListening()
            }
        }

        // Register cancellation cleanup BEFORE posting to handler,
        // so if the coroutine is cancelled while the handler post is pending
        // we still clean up correctly.
        cont.invokeOnCancellation {
            mainHandler.removeCallbacks(vadRunnable)
            mainHandler.post {
                if (isCleaningUp.compareAndSet(false, true)) {
                    recognizer?.let {
                        it.cancel()
                        it.destroy()
                        com.jarvis.assistant.reliability.ListenerDiagnostics.activeSpeechRecognizerCount.decrementAndGet()
                    }
                    recognizer = null
                    Log.d(TAG, "Cancelled")
                }
            }
        }

        mainHandler.post {
            val useOnDevice = forceOffline &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

            if (!useOnDevice && !SpeechRecognizer.isRecognitionAvailable(context)) {
                Log.w(TAG, "SpeechRecognizer not available on this device")
                if (cont.isActive) cont.resume("")
                return@post
            }

            recognizer?.let {
                it.destroy()
                com.jarvis.assistant.reliability.ListenerDiagnostics.activeSpeechRecognizerCount.decrementAndGet()
            }
            recognizer = if (useOnDevice) {
                Log.d(TAG, "Using on-device SpeechRecognizer (forceOffline=true, API ${Build.VERSION.SDK_INT})")
                SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            } else {
                SpeechRecognizer.createSpeechRecognizer(context)
            }
            com.jarvis.assistant.reliability.ListenerDiagnostics.activeSpeechRecognizerCount.incrementAndGet()

            recognizer?.setRecognitionListener(object : RecognitionListener {
                override fun onResults(results: Bundle) {
                    mainHandler.removeCallbacks(vadRunnable)
                    val matches = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?: arrayListOf()
                    val confidences = results.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
                    // Log every candidate so we can audit why STT picked what it picked.
                    matches.forEachIndexed { i, c ->
                        val cf = confidences?.getOrNull(i)?.let { "%.2f".format(it) } ?: "-"
                        Log.d(TAG, "[STT_CANDIDATE] #$i conf=$cf len=${c.length}")
                    }
                    val selector = nbestSelector
                    val text = when {
                        matches.isEmpty()  -> ""
                        selector != null   -> selector(matches, confidences)
                        else               -> matches.firstOrNull() ?: ""
                    }
                    Log.d(TAG, "Result: len=${text.length} +${SystemClock.elapsedRealtime() - listenStartMs}ms")
                    cleanup()
                    if (cont.isActive) cont.resume(text)
                }

                override fun onError(error: Int) {
                    mainHandler.removeCallbacks(vadRunnable)
                    lastErrorCode = error
                    val isSilence = error == SpeechRecognizer.ERROR_NO_MATCH ||
                                    error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT ||
                                    error == SpeechRecognizer.ERROR_CLIENT
                    Log.w(TAG, "Recognition error $error (silence=$isSilence) " +
                        "+${SystemClock.elapsedRealtime() - listenStartMs}ms")
                    cleanup()
                    // Return empty string for silence; caller will restart wake-word loop
                    if (cont.isActive) cont.resume("")
                }

                override fun onReadyForSpeech(params: Bundle?) {
                    Log.d(TAG, "Ready for speech +${SystemClock.elapsedRealtime() - listenStartMs}ms")
                    // SpeechRecognizer has the mic — safe to start any concurrent AudioRecord now.
                    onReady?.invoke()
                }
                override fun onBeginningOfSpeech() {
                    if (!speechStartLogged) {
                        speechStartLogged = true
                        Log.d(TAG, "[SPEECH_START_DETECTED] +${SystemClock.elapsedRealtime() - listenStartMs}ms rmsThreshold=$vadRmsThreshold")
                    }
                }

                override fun onRmsChanged(rmsdB: Float) {
                    if (!FAST_VAD_ENABLED) return
                    if (partialCharCount < FAST_VAD_MIN_PARTIAL_CHARS) return
                    if (rmsdB < vadRmsThreshold) {
                        // Below threshold — arm the VAD timer if not already armed.
                        if (!vadArmed) {
                            vadArmed = true
                            Log.v(TAG, "[SPEECH_REJECTED_LOW_RMS] rms=$rmsdB threshold=$vadRmsThreshold arming_silence_timer=${vadSilenceMs}ms")
                            mainHandler.postDelayed(vadRunnable, vadSilenceMs)
                        }
                    } else {
                        // Speech detected — disarm.
                        if (vadArmed) {
                            vadArmed = false
                            mainHandler.removeCallbacks(vadRunnable)
                        }
                    }
                }

                override fun onBufferReceived(buffer: ByteArray?) {}

                override fun onEndOfSpeech() {
                    // Compare-and-set so a duplicate event is dropped silently
                    // — log + (any future side effects) run exactly once per
                    // recognition session.  Without this guard the duplicate
                    // log polluted latency triage on every utterance.
                    if (!endOfSpeechFired.compareAndSet(false, true)) {
                        Log.v(TAG, "End of speech (duplicate — ignored)")
                        return
                    }
                    Log.d(TAG, "End of speech +${SystemClock.elapsedRealtime() - listenStartMs}ms")
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    if (!FAST_VAD_ENABLED) return
                    val text = partialResults
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull() ?: return
                    if (text.length > partialCharCount) {
                        partialCharCount = text.length
                        // Speech is still coming in — disarm any pending VAD timer.
                        if (vadArmed) {
                            vadArmed = false
                            mainHandler.removeCallbacks(vadRunnable)
                        }
                    }
                }

                override fun onEvent(eventType: Int, params: Bundle?) {}
            })

            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                )
                // Lock recognition to UK English — improves name handling
                // ("Cath", "Heidi") and avoids the recogniser silently
                // bouncing between en-US and the device default.
                putExtra(RecognizerIntent.EXTRA_LANGUAGE,            "en-GB")
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "en-GB")
                // Identify the calling app so the recogniser's accuracy heuristics
                // (and any device-side personalisation) can apply.
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
                // N-best output: we score five candidates downstream rather than
                // trusting the recogniser's #1 pick, which is often wrong for
                // homophones like "what's up" / "WhatsApp".
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                // EXTRA_PREFER_OFFLINE is a HINT only — cloud recognition is
                // still allowed when the on-device model would be worse, which
                // measurably helps proper-noun accuracy on most builds.
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)

                // End-of-speech silence detection — values selected per mic profile.
                // BT/wired headsets get a slightly longer window so a sentence ending
                // quietly (common on close-mic paths) isn't cut before the recogniser
                // has finished processing it.
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                    completeSilenceMs
                )
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                    possiblyCompleteSilenceMs
                )
                // Minimum utterance length: 0 = no filtering, capture even brief commands
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS,
                    0L
                )
            }

            recognizer?.startListening(intent)
            Log.d(TAG, "Listening… +${SystemClock.elapsedRealtime() - listenStartMs}ms")
        }
    }

    /** Cancel any in-progress recognition. */
    fun cancel() {
        mainHandler.post {
            if (isCleaningUp.compareAndSet(false, true)) {
                recognizer?.let {
                    it.cancel()
                    it.destroy()
                    com.jarvis.assistant.reliability.ListenerDiagnostics.activeSpeechRecognizerCount.decrementAndGet()
                }
                recognizer = null
            }
        }
    }

    private fun cleanup() {
        if (isCleaningUp.compareAndSet(false, true)) {
            recognizer?.let {
                it.destroy()
                com.jarvis.assistant.reliability.ListenerDiagnostics.activeSpeechRecognizerCount.decrementAndGet()
            }
            recognizer = null
        }
    }
}
