package com.jarvis.assistant.runtime

import android.content.Context
import android.util.Log
import com.jarvis.assistant.voice.tts.*

/**
 * TtsCoordinator — orchestrates the pluggable TTS providers.
 * 
 * Extracted from [JarvisRuntime]. Decides whether to use Piper,
 * remote streaming, or standard Android TTS based on flags and
 * voice selection.
 */
class TtsCoordinator(
    private val selector: TtsProviderSelector
) {
    companion object {
        private const val TAG = "TtsCoord"
    }

    /** The last text successfully sent to any provider. */
    var lastSpokenText: String = ""
        private set

    /** Speak [text] using the best available provider. */
    suspend fun speak(text: String) {
        if (text.isBlank()) return
        
        val provider = selector.select()
        Log.d(TAG, "[TTS_DISPATCH] provider=${provider.kind}")
        
        try {
            provider.speak(text)
            lastSpokenText = text
        } catch (e: Exception) {
            Log.w(TAG, "[TTS_FAILED] provider=${provider.kind} ${e.javaClass.simpleName}: ${e.message}", e)
            // Fallback to Android if any non-Android provider fails
            if (provider.kind != TtsProvider.Kind.ANDROID_BUILTIN) {
                selector.androidBuiltIn.speak(text)
                lastSpokenText = text
            }
        }
    }

    fun stop() {
        selector.select().stop()
    }

    /** Re-apply voice settings to the underlying engines. */
    fun applyVoice(voiceName: String) {
        (selector.androidBuiltIn as? com.jarvis.assistant.voice.tts.AndroidTtsProvider)
            ?.applyVoice(voiceName)
    }

    /** Final teardown. */
    fun shutdown() {
        selector.androidBuiltIn.release()
        selector.localOnDevice?.release()
        selector.remoteStreaming?.release()
    }
}
