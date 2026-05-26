package com.jarvis.assistant.audio

import android.content.Context
import android.media.AudioManager
import android.util.Log

/**
 * MicInputProfiler — classifies the active microphone path so callers can
 * select appropriate VAD thresholds.
 *
 * WHY DIFFERENT THRESHOLDS?
 *   Bluetooth headset mics sit ~2 cm from the mouth.  The SCO codec narrows
 *   the band to 8 kHz (HFP) or 16 kHz (mSBC), which reduces the raw RMS the
 *   Android audio stack reports compared to a built-in phone mic capturing
 *   room-ambient speech at arm's length.  Using phone-mic RMS thresholds on a
 *   BT headset causes valid speech to be rejected as silence.
 *
 *   Wired headsets share the same mouth-proximity benefit with a wider
 *   frequency response, so they land between BLUETOOTH and PHONE profiles.
 */
class MicInputProfiler(
    context: Context,
    private val bluetoothScoManager: BluetoothScoManager,
) {
    enum class MicProfile { BLUETOOTH_HEADSET, WIRED_HEADSET, PHONE_MIC }

    companion object {
        private const val TAG = "MicInputProfiler"

        // Per-profile VAD thresholds for SpeechCapture's fast-VAD gate.
        // Lower values accept quieter speech (closer mic → lower apparent RMS).
        fun vadThreshold(profile: MicProfile): Float = when (profile) {
            MicProfile.BLUETOOTH_HEADSET -> 0.4f   // BT SCO: mouth-close, narrowband
            MicProfile.WIRED_HEADSET     -> 1.0f   // wired: mouth-close, wider band
            // Lowered from 2.0f → 1.5f: normal conversational volume at arm's
            // length now clears the gate.  2.0f required louder-than-normal speech
            // and silently dropped quiet "Chris"-style single-word responses.
            MicProfile.PHONE_MIC         -> 1.5f
        }

        // Per-profile fast-VAD silence window (ms) — BT/wired tolerate slightly
        // longer pauses so a natural mid-sentence breath doesn't cut the utterance.
        fun vadSilenceMs(profile: MicProfile): Long = when (profile) {
            MicProfile.BLUETOOTH_HEADSET -> 800L    // Increased from 500L
            MicProfile.WIRED_HEADSET     -> 600L    // Increased from 450L
            MicProfile.PHONE_MIC         -> 500L    // Increased from 350L
        }

        // Per-profile SpeechRecognizer end-of-speech silence lengths (ms).
        // BT/wired give a slightly longer trailing window to avoid cutting off
        // sentences that end quietly (common with headset mics at low volume).
        fun completeSilenceMs(profile: MicProfile): Long = when (profile) {
            MicProfile.BLUETOOTH_HEADSET -> 2_500L // Increased from 1_500L
            MicProfile.WIRED_HEADSET     -> 2_000L // Increased from 1_350L
            MicProfile.PHONE_MIC         -> 2_500L // Increased from 1_200L
        }

        fun possiblyCompleteSilenceMs(profile: MicProfile): Long = when (profile) {
            MicProfile.BLUETOOTH_HEADSET -> 1_500L // Increased from 800L
            MicProfile.WIRED_HEADSET     -> 1_200L // Increased from 700L
            MicProfile.PHONE_MIC         -> 1_500L // Increased from 600L
        }
    }

    private val audioManager = context.getSystemService(AudioManager::class.java)!!

    /** Classify the active input path. */
    fun current(): MicProfile {
        val profile = when {
            bluetoothScoManager.isHeadsetConnected -> MicProfile.BLUETOOTH_HEADSET
            @Suppress("DEPRECATION") audioManager.isWiredHeadsetOn -> MicProfile.WIRED_HEADSET
            else -> MicProfile.PHONE_MIC
        }
        Log.d(TAG, "[AUDIO_INPUT_MODE] profile=$profile " +
            "btConnected=${bluetoothScoManager.isHeadsetConnected} " +
            "wired=${@Suppress("DEPRECATION") audioManager.isWiredHeadsetOn}")
        return profile
    }
}
