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
 * Signals that the Piper backend failed for the current utterance so the
 * coordinator can fall back to the Android engine.
 */
private class PiperSpeakFailedException : RuntimeException("piper speak returned false")

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
        // Throw on failure so [TtsCoordinator] catches it and falls back to
        // Android TTS.  Returning normally would swallow the failure and the
        // caller would believe speech happened — e.g. the wake-word ack would
        // be silently dropped, leaving the user with a chime and no spoken
        // acknowledgement that Jarvis is listening.
        if (!manager.speak(text)) {
            Log.w("LocalTtsProvider", "[PIPER_SPEAK_FAILED] signalling fallback")
            throw PiperSpeakFailedException()
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
