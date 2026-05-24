package com.jarvis.assistant.voice.piper

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicReference

/**
 * PiperVoiceManager — top-level coordinator for the Piper TTS path.
 *
 * Single instance per process (typically constructed in JarvisApp lazily).
 * Owns:
 *   - the active [VoiceDefinition] + ONNX session
 *   - the [PiperPhonemizer] currently installed
 *   - the [VoiceFallbackManager] gating retries
 *
 * Public surface (the brief specified):
 *   - initialize()        — async load; safe to call repeatedly
 *   - speak(text)         — returns true when Piper handled the utterance,
 *                            false when caller should fall back to system TTS
 *   - stop()              — interrupt any in-flight playback
 *   - isReady()           — quick check used by [TtsEngine]
 *   - getDiagnostics()    — snapshot for the Settings screen
 *
 * Voice switching:
 *   - switchTo(voiceId) tears down the current session and loads the new
 *     voice, with the same fallback-on-failure semantic.
 *
 * Failure policy: every error path records a [PiperDiagnostics] entry,
 * informs [VoiceFallbackManager], and returns false from [speak] so the
 * caller's system-TTS fallback fires.  We never throw out of [speak].
 */
class PiperVoiceManager(private val context: Context) {

    companion object {
        private const val TAG = "PiperVoiceManager"
    }

    private val loader = PiperVoiceLoader(context)
    private val fallback = VoiceFallbackManager()

    init {
        // Configure debug exporter output directory (disabled by default).
        val debugDir = java.io.File(context.getExternalFilesDir(null), "tts_debug")
        PiperTtsDebugExporter.configure(debugDir)
    }

    /** Mutex guarding voice load / switch / shutdown.  Speak is lock-free. */
    private val loadLock = Mutex()

    private val state = AtomicReference<LoadedState?>(null)
    private val phonemizerRef = AtomicReference<PiperPhonemizer>(PiperPhonemizer.NOOP)

    /** True when a Piper session is loaded AND the fallback hasn't tripped. */
    fun isReady(): Boolean {
        // Feature-flag gate — when OFF (default), Piper is bypassed entirely
        // and Android system TTS handles every utterance.  The user enables
        // this from Settings > Voice Diagnostics to opt in to the
        // experimental Kotlin G2P path.  Reflected in diagnostics so the
        // screen shows the current flag state alongside readiness.
        val flagOn = com.jarvis.assistant.voice.VoiceFeatureFlags.isEnabled(
            com.jarvis.assistant.voice.VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P
        )
        PiperDiagnostics.update { it.copy(experimentalKotlinG2pEnabled = flagOn) }
        if (!flagOn) return false

        val st = state.get() ?: return false
        if (!st.session.isLoaded) return false
        if (fallback.isFallbackActive) return false
        if (!phonemizerRef.get().isAvailable) return false
        return true
    }

    fun getDiagnostics(): PiperDiagnostics.Snapshot = PiperDiagnostics.snapshot()

    fun installPhonemizer(p: PiperPhonemizer) {
        phonemizerRef.set(p)
        PiperDiagnostics.update {
            it.copy(phonemizerAvailable = p.isAvailable, phonemizerName = p.name)
        }
        Log.d(TAG, "[PHONEMIZER_INSTALLED] name=${p.name} available=${p.isAvailable}")
    }

    /**
     * Load the default voice (or [voiceId] when supplied).  Idempotent —
     * subsequent calls with the same id return immediately.  When the voice
     * fails to load, fallback is recorded but the function returns false
     * rather than throwing.
     */
    suspend fun initialize(voiceId: String = PiperVoiceRegistry.DEFAULT_VOICE_ID): Boolean =
        loadLock.withLock {
            val current = state.get()
            if (current != null && current.voice.id == voiceId && current.session.isLoaded) {
                return@withLock true
            }
            // Load (or reload) — replace any existing state.
            val voice = PiperVoiceRegistry.byId(voiceId)
                ?: PiperVoiceRegistry.default()
            doLoad(voice)
        }

    /** Switch to a different voice.  Tears down the current session first. */
    suspend fun switchTo(voiceId: String): Boolean = loadLock.withLock {
        Log.d(TAG, "[VOICE_SWITCH_REQUESTED] to=$voiceId")
        state.getAndSet(null)?.engine?.shutdown()
        val voice = PiperVoiceRegistry.byId(voiceId)
            ?: return@withLock false.also {
                Log.w(TAG, "[VOICE_SWITCH_UNKNOWN] id=$voiceId")
            }
        doLoad(voice)
    }

    private suspend fun doLoad(voice: VoiceDefinition): Boolean = withContext(Dispatchers.IO) {
        Log.d(TAG, "[VOICE_LOAD_START] id=${voice.id}")
        PiperDiagnostics.update {
            it.copy(activeVoiceId = voice.id, jsonLoaded = false, onnxLoaded = false)
        }
        val resolved = loader.resolveOrCopy(voice) ?: run {
            fallback.recordFailure("voice_files_unavailable")
            return@withContext false
        }
        val cfg = loader.parseConfig(resolved.jsonFile) ?: run {
            fallback.recordFailure("voice_config_invalid")
            return@withContext false
        }
        PiperDiagnostics.update { it.copy(jsonLoaded = true, sampleRate = cfg.sampleRate) }

        val session = PiperOnnxSession(resolved.modelFile, cfg)
        val ok = session.ensureLoaded()
        if (!ok) {
            fallback.recordFailure(session.lastFailureReason)
            session.close()
            return@withContext false
        }

        val engine = PiperTtsEngine(session, cfg)
        state.set(LoadedState(voice, cfg, session, engine))
        fallback.recordSuccess()
        Log.d(TAG, "[VOICE_LOAD_DONE] id=${voice.id}")
        true
    }

    /**
     * Speak [text] via Piper if everything is ready; return false if the
     * caller should fall back to system TTS.  Never throws.
     */
    suspend fun speak(text: String): Boolean {
        if (text.isBlank()) return true
        val st = state.get() ?: run {
            Log.d(TAG, "[PIPER_SPEAK_SKIP] reason=not_initialised")
            return false
        }
        if (!fallback.allowAttempt()) {
            Log.d(TAG, "[PIPER_SPEAK_SKIP] reason=fallback_active failures=${fallback.failureCount}")
            return false
        }
        val phonemizer = phonemizerRef.get()
        if (!phonemizer.isAvailable) {
            // Don't burn a failure counter on this — it's a configuration
            // state, not a model failure.  Let system TTS take it silently.
            Log.d(TAG, "[PIPER_SPEAK_SKIP] reason=phonemizer_unavailable")
            return false
        }
        val r = try {
            st.engine.speak(text, phonemizer)
        } catch (e: Exception) {
            Log.e(TAG, "[PIPER_SPEAK_EXCEPTION] ${e.javaClass.simpleName}: ${e.message}", e)
            PiperTtsEngine.Result.Failure("speak_exception:${e.javaClass.simpleName}")
        }
        return when (r) {
            is PiperTtsEngine.Result.Ok -> {
                fallback.recordSuccess()
                true
            }
            is PiperTtsEngine.Result.Interrupted -> {
                // Treated as success — stop() was called intentionally.
                true
            }
            is PiperTtsEngine.Result.Failure -> {
                fallback.recordFailure(r.reason)
                PiperDiagnostics.update { it.copy(lastInferenceFailReason = r.reason) }
                Log.w(TAG, "[PIPER_SPEAK_FAILED] reason=${r.reason}")
                false
            }
        }
    }

    /** Stop any in-flight playback. Safe from any thread. */
    fun stop() {
        state.get()?.engine?.stop()
    }

    /**
     * Manual reset — used by the diagnostics screen "Reload Voice" button to
     * clear the fallback trip after a fix.
     */
    fun resetFallback() {
        fallback.manualReset()
    }

    /** Drop the in-memory cache + force a fresh asset re-copy on next init. */
    suspend fun clearCacheAndShutdown() = loadLock.withLock {
        Log.d(TAG, "[VOICE_CACHE_CLEAR_REQUESTED]")
        state.getAndSet(null)?.engine?.shutdown()
        loader.clearCache()
        PiperDiagnostics.reset()
        fallback.manualReset()
    }

    suspend fun shutdown() = loadLock.withLock {
        state.getAndSet(null)?.engine?.shutdown()
    }

    /**
     * Speak the standard voice-test phrase the brief specifies.  Used by the
     * diagnostics screen "Test Voice" button.  Always returns immediately
     * (suspend); spawn from a coroutine.
     */
    suspend fun speakTestPhrase(): Boolean = speak("Hello Chris. Systems are online.")

    private data class LoadedState(
        val voice: VoiceDefinition,
        val config: PiperVoiceConfig,
        val session: PiperOnnxSession,
        val engine: PiperTtsEngine,
    )
}
