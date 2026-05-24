package com.jarvis.assistant.voice.tts

import com.jarvis.assistant.voice.VoiceFeatureFlags
import com.jarvis.assistant.util.SettingsStore

/**
 * TtsProviderSelector — logic for picking which TTS engine to use
 * for a given request.
 */
class TtsProviderSelector(
    val androidBuiltIn: TtsProvider,
    val localOnDevice: TtsProvider?,
    val remoteStreaming: TtsProvider?,
    private val settings: SettingsStore
) {
    /** Pick the best available provider based on flags and readiness. */
    fun select(): TtsProvider {
        val useNeural = VoiceFeatureFlags.isEnabled(
            VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P
        )
        
        val selectedVoice = settings.ttsVoiceName
        
        // 1. Explicitly selected Piper voice always wins
        if (selectedVoice.startsWith("piper:") && localOnDevice?.isReady() == true) {
            return localOnDevice
        }
        
        // 2. Experimental flag ON and local ready
        if (useNeural && localOnDevice?.isReady() == true) {
            return localOnDevice
        }
        
        // 3. Fallback to Android
        return androidBuiltIn
    }
}
