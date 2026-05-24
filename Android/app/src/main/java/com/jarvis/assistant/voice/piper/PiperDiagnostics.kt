package com.jarvis.assistant.voice.piper

import java.util.concurrent.atomic.AtomicReference

/**
 * PiperDiagnostics — process-wide snapshot of the Piper TTS state for the
 * Settings > Voice Diagnostics screen.
 *
 * Every field is optional and starts null/0 — the screen renders "—" when
 * a field hasn't been populated yet.  Mutators are concurrency-safe via
 * [AtomicReference] so the runtime can update from a background coroutine
 * while Compose collects.
 *
 * No business logic lives here — this is a write-only sink for status
 * reporting and a read-only source for the diagnostics UI.
 */
object PiperDiagnostics {

    private val state: AtomicReference<Snapshot> = AtomicReference(Snapshot())

    fun snapshot(): Snapshot = state.get()

    fun update(transform: (Snapshot) -> Snapshot) {
        while (true) {
            val prev = state.get()
            val next = transform(prev)
            if (state.compareAndSet(prev, next)) return
        }
    }

    /** Reset to all-defaults — used when the user clears the voice cache. */
    fun reset() {
        state.set(Snapshot())
    }

    /**
     * @param activeVoiceId       Id of the active voice ([VoiceDefinition.id])
     * @param modelPath           Absolute filesystem path of the loaded .onnx
     * @param modelSizeBytes      File size of the .onnx file
     * @param jsonLoaded          Did the JSON config parse successfully?
     * @param onnxLoaded          Was an OrtSession built successfully?
     * @param phonemizerAvailable Did a non-stub phonemizer initialise?
     * @param sampleRate          Sample rate read from the JSON config
     * @param loadDurationMs      Wall-clock ms spent in the last load attempt
     * @param memoryBeforeLoad    Heap bytes recorded before the load
     * @param memoryAfterLoad     Heap bytes recorded after the load
     * @param lastInferenceMs     Wall-clock ms spent on the last synth
     * @param lastInferenceChars  Length of the text passed to the last synth
     * @param lastInferenceFailReason
     *                             "" when the last call succeeded, otherwise
     *                             the operator-friendly reason (no PII)
     * @param fallbackActive      True when [VoiceFallbackManager] has tripped
     * @param failureCount        Consecutive Piper failures since boot
     */
    data class Snapshot(
        val activeVoiceId: String?       = null,
        val modelPath: String?           = null,
        val modelSizeBytes: Long         = 0L,
        val jsonLoaded: Boolean          = false,
        val onnxLoaded: Boolean          = false,
        val phonemizerAvailable: Boolean = false,
        val phonemizerName: String       = "noop",
        val sampleRate: Int              = 0,
        val loadDurationMs: Long         = 0L,
        val memoryBeforeLoadBytes: Long  = 0L,
        val memoryAfterLoadBytes: Long   = 0L,
        val lastInferenceMs: Long        = 0L,
        val lastInferenceChars: Int      = 0,
        val lastInferenceFailReason: String = "",
        val fallbackActive: Boolean      = false,
        val failureCount: Int            = 0,

        // ── Phonemiser + inference detail (populated by SherpaPiperPhonemizer
        //    and PiperOnnxSession) ──────────────────────────────────────────
        /** Phoneme tokens produced by the G2P for the last utterance. */
        val lastPhonemeCount: Int            = 0,
        /** Wall-clock ms the G2P spent on the last utterance. */
        val lastPhonemeGenerationMs: Long    = 0L,
        /** Length of the post-normalised text — never the text itself. */
        val lastNormalizedTextLen: Int       = 0,
        /** Phonemes the model's phoneme_id_map didn't recognise, last call. */
        val lastPhonemeIdSkips: Int          = 0,
        /** Total phoneme ids fed to the ONNX session, last call. */
        val lastPhonemeIdCount: Int          = 0,
        /**
         * Fraction of generated phonemes that successfully mapped to model
         * ids on the last call, expressed as 0–100.  0 means "no last call
         * ran" or "every phoneme missed".  Below the threshold defined in
         * [com.jarvis.assistant.voice.piper.SherpaPiperPhonemizer
         * .MIN_MAPPING_SUCCESS_PERCENT] the phonemizer aborts and Android
         * TTS handles the utterance.
         */
        val phonemeMappingSuccessPercent: Int = 0,
        /** True when the last call aborted because the success % was below the threshold. */
        val phonemeMappingAbortedLowCoverage: Boolean = false,
        /** True when the experimental Kotlin G2P feature flag is currently ON. */
        val experimentalKotlinG2pEnabled: Boolean = false,
        /** Sample count of the last PCM output. */
        val lastPcmSamples: Int              = 0,
        /** PCM duration in ms for the last call. */
        val lastPcmDurationMs: Long          = 0L,
        /** Input tensor shape ("[1, N]"), last call. */
        val lastInputTensorShape: String     = "",
        /** True if playback started for the last utterance. */
        val lastPlaybackStarted: Boolean     = false,
        /** True if playback finished without being interrupted. */
        val lastPlaybackCompleted: Boolean   = false,

        // ── Debug-only fields (populated only when verbose flags enabled).
        //    Empty in release.
        val lastNormalizedTextDebug: String  = "",
        val lastPhonemeListDebug: String     = "",
    )
}
