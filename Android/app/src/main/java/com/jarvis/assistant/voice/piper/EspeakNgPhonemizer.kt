package com.jarvis.assistant.voice.piper

import android.content.Context

/**
 * EspeakNgPhonemizer — native phonemisation using espeak-ng via sherpa-onnx.
 * 
 * Disabled in this build to keep the APK lean. The dependency is removed.
 */
class EspeakNgPhonemizer(private val context: Context) : PiperPhonemizer {
    
    override val name: String = "espeak-ng-native-disabled"
    override val isAvailable: Boolean = false

    override fun textToPhonemeIds(text: String, config: PiperVoiceConfig): List<List<Int>> {
        return emptyList()
    }
}
