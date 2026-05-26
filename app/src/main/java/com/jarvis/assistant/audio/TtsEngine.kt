package com.jarvis.assistant.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.math.PI
import kotlin.math.sin

/**
 * TtsEngine — wraps Android TextToSpeech and the startup chime as suspend functions.
 *
 * SUSPEND SPEAK:
 *   speak() suspends the coroutine until the utterance is fully spoken,
 *   then resumes. If the coroutine is cancelled mid-speech, TTS is stopped.
 *
 * CHIME:
 *   playChime() generates a two-tone ascending sine-wave "ding" (A5→D6)
 *   entirely in memory — no audio file asset needed.
 */
class TtsEngine(context: Context) : TextToSpeech.OnInitListener {

    companion object {
        private const val TAG = "TtsEngine"
    }

    private val appContext = context.applicationContext
    private val tts = TextToSpeech(appContext, this)
    private val ready = AtomicBoolean(false)

    /**
     * The most recent text passed to [speak].  Read by
     * [com.jarvis.assistant.voice.attention.AttentionGate] as the echo-guard
     * reference — if the next captured transcript closely resembles this
     * text, it's our own TTS bleeding back into the microphone.
     *
     * Cleared once the utterance finishes so the guard does not keep
     * suppressing legitimate follow-ups indefinitely.
     */
    @Volatile var lastSpokenText: String? = null
        private set

    /**
     * Persists the voice name across the async [onInit] gap so that a voice
     * selected before the engine is ready is still applied once it fires.
     */
    @Volatile private var pendingVoiceName: String = ""

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            val result = tts.setLanguage(Locale.US)
            if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                Log.w(TAG, "US English TTS language not available — falling back to device default")
                tts.language = Locale.getDefault()
            }
            ready.set(true)
            Log.d(TAG, "TTS engine ready")
            if (pendingVoiceName.isNotBlank()) {
                Log.d(TAG, "Applying deferred voice: $pendingVoiceName")
                applyVoice(pendingVoiceName)
            }
        } else {
            Log.e(TAG, "TTS init failed with status $status")
        }
    }

    /** Speak [text] aloud and suspend until playback is complete. */
    suspend fun speak(text: String) {
        if (text.isBlank()) return

        // Wait briefly for the engine's async init to complete.  Without this,
        // a speak() called before onInit fires (notably the wake-word ack on the
        // first activation after launch) is silently dropped — the user hears
        // the chime then total silence and the mic appears to close immediately
        // because no audible feedback ever followed the wake.
        if (!ready.get()) {
            var waited = 0
            while (!ready.get() && waited < 2_000) {
                delay(50)
                waited += 50
            }
            if (!ready.get()) {
                Log.w(TAG, "[SPEAK_SUPPRESSED] reason=tts_init_timeout waited_ms=$waited text.len=${text.length}")
                return
            }
            Log.d(TAG, "[TTS_INIT_AWAITED] resumed after ${waited}ms")
        }

        lastSpokenText = text

        // Optional Piper path — opt-in via JarvisApp.piperVoiceManager.
        // If the user has explicitly selected a "piper:..." voice in settings,
        // we use that voice via PiperVoiceManager and skip the system TTS.
        // If no Piper voice is selected, we still try the Piper path if the
        // experimental flag is ON (which uses the default Piper voice).
        try {
            val piper = com.jarvis.assistant.JarvisApp.piperVoiceManager
            val selectedVoice = com.jarvis.assistant.util.SettingsStore(appContext).ttsVoiceName
            val flagOn = com.jarvis.assistant.voice.VoiceFeatureFlags.isEnabled(
                com.jarvis.assistant.voice.VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P
            )
            
            if (selectedVoice.startsWith("piper:")) {
                val voiceId = selectedVoice.removePrefix("piper:")
                if (piper.initialize(voiceId) && piper.speak(text)) return
                Log.w(TAG, "[PIPER_EXPLICIT_FALLBACK] Piper failed for $voiceId — using system TTS")
            } else if (flagOn) {
                // Feature flag is ON but no explicit Piper voice selected.
                // Use the default Piper voice.  Initialize if needed.
                if (!piper.isReady()) {
                    Log.d(TAG, "[PIPER_AUTO_INIT] Flag is ON, initializing default voice")
                    piper.initialize() // uses DEFAULT_VOICE_ID
                }
                if (piper.isReady() && piper.speak(text)) {
                    return
                }
            }
        } catch (_: UninitializedPropertyAccessException) {
            // JarvisApp not yet initialised (e.g. unit-test path); continue.
        } catch (e: Exception) {
            Log.w(TAG, "[PIPER_PATH_EXCEPTION_FALLBACK] ${e.javaClass.simpleName}: ${e.message}", e)
        }

        if (!speakOnce(text)) {
            // Network voice failed — most commonly because the device is offline
            // and the user's chosen Google voice has isNetworkConnectionRequired
            // == true.  Swap to a local-only voice and retry once.  Subsequent
            // calls continue with the offline voice until applyVoice() is invoked.
            if (switchToOfflineVoice()) {
                Log.d(TAG, "[TTS_FALLBACK_OFFLINE] retrying after voice swap")
                speakOnce(text)
            }
        }
    }

    /**
     * Single attempt.  Returns true on clean completion (onDone/onStop), false
     * if the engine signalled a network-related error so the caller can retry
     * with a different voice.
     *
     * Wrapped with a 20 s hard timeout because on some devices the native
     * UtteranceProgressListener never fires onDone — leaving the coroutine
     * suspended forever, audio focus held, and the state machine stuck in
     * Speaking.  [TtsCoordinator] has an outer 30 s fence; this inner one
     * is tighter so we surrender to the fallback path sooner.
     */
    private suspend fun speakOnce(text: String): Boolean =
        (kotlinx.coroutines.withTimeoutOrNull(20_000L) { speakOnceInner(text) } ?: run {
            Log.w(TAG, "[TTS_SPEAK_TIMEOUT] no listener callback within 20s — stopping")
            try { tts.stop() } catch (_: Exception) {}
            try { tts.setOnUtteranceProgressListener(null) } catch (_: Exception) {}
            false
        })

    private suspend fun speakOnceInner(text: String): Boolean =
        suspendCancellableCoroutine { cont ->
            val utteranceId = "jarvis_${System.currentTimeMillis()}"
            val resumed = AtomicBoolean(false)

            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                // Clear the listener once the utterance is settled so the TTS native
                // connection doesn't keep a reference to this object (and through it, the
                // suspended continuation) after the coroutine has already resumed.
                private fun finish(success: Boolean) {
                    if (!resumed.compareAndSet(false, true)) return
                    tts.setOnUtteranceProgressListener(null)
                    if (cont.isActive) cont.resume(success)
                }
                override fun onDone(id: String?)  = finish(true)
                override fun onStop(utteranceId: String?, interrupted: Boolean) = finish(true)
                override fun onStart(id: String?) {}
                override fun onError(id: String?) {
                    Log.w(TAG, "TTS utterance error for $id (no error code)")
                    finish(false)
                }
                @Suppress("DEPRECATION")
                override fun onError(utteranceId: String?, errorCode: Int) {
                    val isNetworkError = errorCode == TextToSpeech.ERROR_NETWORK ||
                        errorCode == TextToSpeech.ERROR_NETWORK_TIMEOUT
                    val reason = when (errorCode) {
                        TextToSpeech.ERROR_SYNTHESIS         -> "ERROR_SYNTHESIS"
                        TextToSpeech.ERROR_SERVICE           -> "ERROR_SERVICE"
                        TextToSpeech.ERROR_OUTPUT            -> "ERROR_OUTPUT"
                        TextToSpeech.ERROR_NETWORK           -> "ERROR_NETWORK"
                        TextToSpeech.ERROR_NETWORK_TIMEOUT   -> "ERROR_NETWORK_TIMEOUT"
                        TextToSpeech.ERROR_INVALID_REQUEST   -> "ERROR_INVALID_REQUEST"
                        TextToSpeech.ERROR_NOT_INSTALLED_YET -> "ERROR_NOT_INSTALLED_YET"
                        else                                 -> "unknown ($errorCode)"
                    }
                    Log.w(TAG, "TTS utterance error for $utteranceId — $reason")
                    // Treat network errors as a retryable failure so the caller
                    // can swap to a local voice and try once more.
                    finish(!isNetworkError)
                }
            })

            tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
            cont.invokeOnCancellation {
                tts.stop()
                tts.setOnUtteranceProgressListener(null)
            }
        }

    /**
     * Pick a voice with isNetworkConnectionRequired == false and matching the
     * current locale.  Returns true if a swap was performed.  Caches the
     * decision via [usingOfflineFallback] so we don't repeatedly enumerate
     * voices when the network is down for many turns.
     */
    private fun switchToOfflineVoice(): Boolean {
        if (usingOfflineFallback) return false
        val voices = try { tts.voices } catch (_: Exception) { null } ?: return false
        val targetLocale = tts.voice?.locale ?: Locale.getDefault()
        val candidate = voices.firstOrNull {
            !it.isNetworkConnectionRequired &&
                it.locale.language == targetLocale.language &&
                !it.features.contains(android.speech.tts.TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)
        } ?: voices.firstOrNull {
            !it.isNetworkConnectionRequired &&
                !it.features.contains(android.speech.tts.TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)
        }
        if (candidate == null) {
            Log.w(TAG, "[TTS_FALLBACK_OFFLINE_NO_VOICE] no local voice available — TTS will stay silent")
            return false
        }
        tts.voice = candidate
        usingOfflineFallback = true
        Log.d(TAG, "[TTS_FALLBACK_OFFLINE_SWITCHED] voice=${candidate.name} " +
            "locale=${candidate.locale}")
        return true
    }

    @Volatile private var usingOfflineFallback = false

    /**
     * Play a short ascending two-tone chime to signal that Jarvis heard the wake word.
     * Suspends for ~600 ms before returning.
     *
     * Prefer [startChimeAsync] in the wake pipeline — it fires immediately and
     * returns so the microphone opens in parallel instead of waiting.
     */
    suspend fun playChime() {
        val chime = buildChime() ?: return
        try {
            chime.play()
            delay(600L)
        } finally {
            // Always release the AudioTrack — delay() throws on coroutine
            // cancellation, which would otherwise leave the hardware claim open.
            try { chime.release() } catch (_: Exception) {}
        }
    }

    /**
     * Fire-and-forget chime: starts playback and returns immediately.
     *
     * The chime is 2 × 150 ms = 300 ms of audio.  A daemon thread waits 350 ms
     * (a little longer than the audio) and then releases the AudioTrack.  Callers
     * do not block — the microphone opens in parallel while the chime plays.
     *
     * Use this in the wake pipeline instead of the suspending [playChime].
     */
    fun startChimeAsync() {
        val chime = buildChime() ?: return
        val t0 = android.os.SystemClock.elapsedRealtime()
        Log.d(TAG, "Chime start (async) t=+0ms")
        chime.play()
        Thread {
            Thread.sleep(350L)   // slightly longer than 300 ms audio to ensure full playback
            try { chime.release() } catch (_: Exception) {}
            Log.d(TAG, "Chime released after ${android.os.SystemClock.elapsedRealtime() - t0}ms")
        }.also { it.isDaemon = true; it.name = "jarvis-chime-release" }.start()
    }

    /**
     * Subtle 90 ms ack tick — used by [SilentExecution] to confirm an action
     * fired without speaking a sentence.  A single short sine pip; quieter
     * than the wake chime so it never competes with music ducking.
     */
    fun playAckTickAsync() {
        val tick = buildAckTick() ?: return
        tick.play()
        Thread {
            Thread.sleep(120L)
            try { tick.release() } catch (_: Exception) {}
        }.also { it.isDaemon = true; it.name = "jarvis-acktick-release" }.start()
    }

    private fun buildAckTick(): AudioTrack? {
        return try {
            val sampleRate      = 44100
            val durationMs      = 90
            val totalSamples    = sampleRate * durationMs / 1000
            val frequency       = 1200          // single short, soft pip
            val buffer          = ShortArray(totalSamples)
            val attackSamples   = sampleRate * 5 / 1000
            for (i in 0 until totalSamples) {
                val t        = i.toDouble() / sampleRate
                val envelope = when {
                    i < attackSamples -> i.toDouble() / attackSamples
                    else              -> Math.exp(-5.0 * (i - attackSamples).toDouble() / totalSamples)
                }
                val sample = (sin(2.0 * PI * frequency * t) * 32767.0 * 0.18 * envelope).toInt()
                buffer[i] = sample.coerceIn(-32768, 32767).toShort()
            }
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .setAudioFormat(
                    android.media.AudioFormat.Builder()
                        .setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(android.media.AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(buffer.size * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
                .also {
                    it.write(buffer, 0, buffer.size)
                }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to build ack tick: ${e.message}")
            null
        }
    }

    /**
     * Switch to an Android TTS device voice by name.
     * Pass blank to revert to the system default.
     */
    fun applyVoice(voiceName: String) {
        pendingVoiceName = voiceName
        if (voiceName.isBlank() || !ready.get()) {
            Log.d(TAG, "TTS engine not ready yet — voice '$voiceName' will be applied in onInit()")
            return
        }
        val voice = tts.voices?.find { it.name == voiceName }
        if (voice != null) {
            tts.voice = voice
            // User picked this voice on purpose — clear the offline-fallback
            // latch so we re-test it next time (the network may be back).
            usingOfflineFallback = false
            Log.d(TAG, "Voice set to: ${voice.name}")
        } else {
            Log.w(TAG, "Voice '$voiceName' not found on this device")
        }
    }

    /**
     * Immediately stop any current or queued speech without shutting down the engine.
     * Called by BargeInDetector when the user starts speaking during TTS playback.
     * Also signals the optional Piper path so its AudioTrack stops within ~100 ms.
     */
    fun stopSpeaking() {
        tts.stop()
        try {
            com.jarvis.assistant.JarvisApp.piperVoiceManager.stop()
        } catch (_: UninitializedPropertyAccessException) { /* not wired */ }
        catch (_: Exception)                                { /* defensive */ }
    }

    /** Release all TTS resources. Call when the service is being destroyed. */
    fun shutdown() {
        tts.stop()
        tts.shutdown()
    }

    // ── Chime generation ──────────────────────────────────────────────────────

    private fun buildChime(): AudioTrack? {
        return try {
            val sampleRate     = 44100
            val msPerTone      = 150
            val samplesPerTone = sampleRate * msPerTone / 1000
            val frequencies    = intArrayOf(880, 1174)
            val totalSamples   = samplesPerTone * frequencies.size
            val buffer         = ShortArray(totalSamples)

            for ((idx, freq) in frequencies.withIndex()) {
                val offset = idx * samplesPerTone
                for (i in 0 until samplesPerTone) {
                    val t            = i.toDouble() / sampleRate
                    val attackSamples = sampleRate * 5 / 1000
                    val envelope     = when {
                        i < attackSamples -> i.toDouble() / attackSamples
                        else              -> Math.exp(-3.5 * (i - attackSamples).toDouble() / samplesPerTone)
                    }
                    val sample = (sin(2.0 * PI * freq * t) * 32767.0 * 0.4 * envelope).toInt()
                    buffer[offset + i] = sample.coerceIn(-32768, 32767).toShort()
                }
            }

            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(totalSamples * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
                .also { track -> track.write(buffer, 0, buffer.size) }
        } catch (e: Exception) {
            Log.w(TAG, "Chime build failed: ${e.message}")
            null
        }
    }
}
