package com.jarvis.assistant.voice.piper

/**
 * PiperVoiceConfig — parsed shape of `<voice>.onnx.json`.
 *
 * The Piper config JSON is the source of truth for sample rate, phoneme map,
 * and inference hyperparameters.  Only the fields the engine actually reads
 * are modelled here; unknown keys are ignored by Gson.
 *
 * Validation is in [PiperVoiceLoader] — this is a pure data class.
 */
data class PiperVoiceConfig(
    val audio: AudioConfig?           = null,
    val espeak: EspeakConfig?         = null,
    val inference: InferenceConfig?   = null,

    /**
     * Map of phoneme string → ONNX input id list.  The model takes a
     * sequence of integer ids; this map is how text-derived phonemes are
     * looked up.  Keys are the IPA-ish phoneme symbols Piper espeak emits.
     */
    @com.google.gson.annotations.SerializedName("phoneme_id_map")
    val phonemeIdMap: Map<String, List<Int>>? = null,

    /**
     * Optional phoneme aliasing — sometimes empty.  Maps source phonemes to
     * preferred phonemes before id lookup.
     */
    @com.google.gson.annotations.SerializedName("phoneme_map")
    val phonemeMap: Map<String, List<String>>? = null,

    @com.google.gson.annotations.SerializedName("phoneme_type")
    val phonemeType: String? = null,

    @com.google.gson.annotations.SerializedName("num_speakers")
    val numSpeakers: Int = 1,

    @com.google.gson.annotations.SerializedName("speaker_id_map")
    val speakerIdMap: Map<String, Int>? = null,

    val language: LanguageConfig? = null,
) {

    data class AudioConfig(
        @com.google.gson.annotations.SerializedName("sample_rate")
        val sampleRate: Int = 22_050,
    )

    data class EspeakConfig(
        val voice: String? = null,
    )

    /**
     * Default inference params from the Piper repository.  When the JSON
     * omits a key, these values keep the model running with reasonable
     * (mainline-Piper) defaults.
     */
    data class InferenceConfig(
        @com.google.gson.annotations.SerializedName("noise_scale")
        val noiseScale: Float = 0.667f,
        @com.google.gson.annotations.SerializedName("length_scale")
        val lengthScale: Float = 1.0f,
        @com.google.gson.annotations.SerializedName("noise_w")
        val noiseW: Float = 0.8f,
    )

    data class LanguageConfig(
        val code: String? = null,
    )

    /** Convenience reads — fall through to mainline-Piper defaults. */
    val sampleRate: Int   get() = audio?.sampleRate ?: 22_050
    val noiseScale: Float get() = inference?.noiseScale ?: 0.667f
    val lengthScale: Float get() = inference?.lengthScale ?: 1.0f
    val noiseW: Float     get() = inference?.noiseW ?: 0.8f
    val espeakVoice: String? get() = espeak?.voice
    val languageCode: String? get() = language?.code
    val isSingleSpeaker: Boolean get() = numSpeakers <= 1
}
