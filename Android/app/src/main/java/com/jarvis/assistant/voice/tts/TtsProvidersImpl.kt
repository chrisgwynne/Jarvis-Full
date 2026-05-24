package com.jarvis.assistant.voice.tts

import android.content.Context
import android.util.Log
import com.jarvis.assistant.audio.TtsEngine
import kotlinx.coroutines.delay

/**
 * AndroidTtsProvider — [TtsProvider] implementation using the built-in
 * Android TextToSpeech engine via [TtsEngine].
 */
class AndroidTtsProvider(private val engine: TtsEngine) : TtsProvider {

    override val kind: TtsProvider.Kind = TtsProvider.Kind.ANDROID_BUILTIN

    override fun isReady(): Boolean = true // TtsEngine handles its own async init

    override suspend fun speak(text: String) {
        engine.speak(text)
    }

    override fun stop() {
        engine.stopSpeaking()
    }

    override fun release() {
        engine.shutdown()
    }

    fun applyVoice(voiceName: String) {
        engine.applyVoice(voiceName)
    }
}

/**
 * LocalOnDeviceTtsProvider — [TtsProvider] implementation using Piper ONNX
 * models via [PiperVoiceManager].
 */
class LocalOnDeviceTtsProvider(
    private val manager: com.jarvis.assistant.voice.piper.PiperVoiceManager
) : TtsProvider {

    override val kind: TtsProvider.Kind = TtsProvider.Kind.LOCAL_ONDEVICE

    override fun isReady(): Boolean = manager.isReady()

    override suspend fun speak(text: String) {
        if (!manager.speak(text)) {
            Log.w("LocalTtsProvider", "[PIPER_SPEAK_FAILED] falling back to Android TTS handled by selector")
        }
    }

    override fun stop() {
        // PiperVoiceManager doesn't expose a global stop() yet;
        // it's usually handled per-speak session cancellation.
    }

    override fun release() {
        // manager.shutdown() // managed by JarvisApp
    }
}
