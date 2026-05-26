package com.jarvis.assistant.voice.piper

import android.util.Log

/**
 * PiperPhonemizer — text → list of phoneme-id sequences for the ONNX model.
 *
 * Piper models do NOT take raw text as input.  They take an integer
 * sequence drawn from the JSON config's [PiperVoiceConfig.phonemeIdMap].
 * Mainline Piper produces those sequences with espeak-ng on desktop.  On
 * Android there are three viable integration paths:
 *
 *   1. Bundle espeak-ng compiled for Android NDK (~3 MB native + a small
 *      JNI wrapper).  Most faithful to mainline Piper.
 *   2. Use sherpa-onnx's bundled phonemizer (depend on
 *      `com.k2-fsa:sherpa-onnx`).  Heavier but turnkey.
 *   3. Ship a pure-Kotlin G2P (much smaller, English-only, lower quality).
 *
 * This module ships ONLY the interface plus a [NoopPhonemizer] that
 * always returns empty.  Callers MUST install a real implementation
 * before [PiperVoiceManager] will produce audio.
 *
 * Why no default G2P: a half-working phonemizer is worse than none — it
 * makes the engine sound broken instead of failing fast and falling back
 * to system TTS.  Returning empty triggers the failure path cleanly.
 */
interface PiperPhonemizer {

    /** Locale-friendly identifier for diagnostics ("noop", "espeak-ng", …). */
    val name: String

    /** True when the phonemizer is initialised and producing ids. */
    val isAvailable: Boolean

    /**
     * Convert [text] into a sequence of phoneme-id sequences.  Each top-level
     * sentence/utterance becomes one inner list of ids.  An empty result
     * tells [PiperTtsEngine] to bail and fall back.
     *
     * The [config] is supplied so the implementation can apply the voice's
     * [PiperVoiceConfig.phonemeMap] aliasing and look up ids via
     * [PiperVoiceConfig.phonemeIdMap].
     */
    fun textToPhonemeIds(text: String, config: PiperVoiceConfig): List<List<Int>>

    companion object {
        private const val TAG = "PiperPhonemizer"

        /**
         * Default no-op installed at boot.  Always returns empty so the
         * fallback path fires.  Replace via [PiperVoiceManager.setPhonemizer]
         * once a real phonemizer is wired in.
         */
        val NOOP: PiperPhonemizer = NoopPhonemizer

        private object NoopPhonemizer : PiperPhonemizer {
            override val name: String = "noop"
            override val isAvailable: Boolean = false
            override fun textToPhonemeIds(text: String, config: PiperVoiceConfig): List<List<Int>> {
                Log.d(TAG, "[PHONEMIZER_NOOP_INVOKED] chars=${text.length} — phonemizer not configured")
                return emptyList()
            }
        }
    }
}
