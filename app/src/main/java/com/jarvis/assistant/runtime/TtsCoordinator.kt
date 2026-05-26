package com.jarvis.assistant.runtime

import android.content.Context
import android.util.Log
import com.jarvis.assistant.voice.tts.*
import kotlinx.coroutines.withTimeoutOrNull

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

        // Hard upper bound on a single utterance.  Even the longest
        // conversational reply (capped at 3 sentences / 320 chars by
        // ResponseFormatter) should finish inside ~12 s on any backend;
        // anything past this is a hung provider — an
        // UtteranceProgressListener that never fires, an AudioTrack.write
        // blocked on a full buffer, a Piper synthesis that stalled.
        // Without this fence the caller (speakAndRecord) holds audio focus
        // forever and the state machine stays in Speaking, which the
        // listener watchdog has to clean up.  Better to abort here.
        private const val SPEAK_TIMEOUT_MS = 30_000L
    }

    /** The last text successfully sent to any provider. */
    var lastSpokenText: String = ""
        private set

    /** Speak [text] using the best available provider. */
    suspend fun speak(text: String) {
        if (text.isBlank()) return

        val provider = selector.select()
        Log.d(TAG, "[TTS_DISPATCH] provider=${provider.kind}")

        // Try primary provider with a timeout fence.  If null comes back,
        // the provider hung — fall through to the Android backend (which
        // also gets the same fence).  Exceptions go through the existing
        // catch-and-fallback path.
        val primaryOk = try {
            val finished = withTimeoutOrNull(SPEAK_TIMEOUT_MS) {
                provider.speak(text)
                true
            }
            if (finished == null) {
                Log.w(TAG, "[TTS_TIMEOUT] provider=${provider.kind} ms=$SPEAK_TIMEOUT_MS " +
                    "text.len=${text.length}")
                runCatching { provider.stop() }
                false
            } else {
                lastSpokenText = text
                true
            }
        } catch (e: Exception) {
            Log.w(TAG, "[TTS_FAILED] provider=${provider.kind} ${e.javaClass.simpleName}: ${e.message}", e)
            false
        }
        if (primaryOk) return

        // Fallback to Android — always try, even if the primary WAS
        // Android, because the failure may have been a transient one
        // (focus loss, mid-utterance device disconnect) and the second
        // attempt re-establishes state.
        try {
            val finished = withTimeoutOrNull(SPEAK_TIMEOUT_MS) {
                selector.androidBuiltIn.speak(text)
                true
            }
            if (finished == null) {
                Log.e(TAG, "[TTS_TIMEOUT] fallback=android ms=$SPEAK_TIMEOUT_MS — giving up")
                runCatching { selector.androidBuiltIn.stop() }
            } else {
                lastSpokenText = text
            }
        } catch (e: Exception) {
            Log.e(TAG, "[TTS_FALLBACK_FAILED] android ${e.javaClass.simpleName}: ${e.message}", e)
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
