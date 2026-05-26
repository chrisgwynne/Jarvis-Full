package com.jarvis.assistant.voice.piper

import android.util.Log

/**
 * PiperVoiceRegistry — process-wide list of every Piper voice the app knows
 * about, plus the active voice id.
 *
 * Default registry contains exactly one entry — the bundled "Jarvis medium"
 * voice — but the structure supports adding downloaded voices later via
 * [register].  Removal is intentionally not exposed: removing a voice while
 * it's active would leave [PiperVoiceManager] in an undefined state.
 *
 * Voice activation is a pure data change here.  The runtime side
 * ([PiperVoiceManager.switchTo]) is responsible for tearing down the old
 * ONNX session and loading the new one.
 */
object PiperVoiceRegistry {

    private const val TAG = "PiperVoiceRegistry"

    /**
     * Default bundled voice id.  Files expected at:
     *   assets/voices/jarvis-medium.onnx
     *   assets/voices/jarvis-medium.onnx.json
     */
    const val DEFAULT_VOICE_ID = "en_GB-jarvis-medium"

    private val voices: MutableMap<String, VoiceDefinition> = LinkedHashMap()

    init {
        // Register the default bundled voice up front.  No I/O — just metadata.
        register(
            VoiceDefinition(
                id            = DEFAULT_VOICE_ID,
                displayName   = "Jarvis (medium)",
                modelAssetPath = "voices/jarvis-medium.onnx",
                jsonAssetPath  = "voices/jarvis-medium.onnx.json",
                sampleRate     = 22_050,
                quality        = "medium",
                gender         = "male",
                locale         = "en-GB",
            )
        )
    }

    fun register(voice: VoiceDefinition) {
        if (voices.containsKey(voice.id)) {
            Log.d(TAG, "[VOICE_REGISTERED_REPLACED] id=${voice.id}")
        } else {
            Log.d(TAG, "[VOICE_REGISTERED] id=${voice.id} display=\"${voice.displayName}\"")
        }
        voices[voice.id] = voice
    }

    fun all(): List<VoiceDefinition> = voices.values.toList()

    fun byId(id: String): VoiceDefinition? = voices[id]

    fun default(): VoiceDefinition = voices[DEFAULT_VOICE_ID]
        ?: voices.values.first()
}
