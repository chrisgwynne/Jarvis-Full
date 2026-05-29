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
            MicProfile.BLUETOOTH_HEADSET -> 0.4f   // BT SCO: mouth-close, narrowband (lowered from 0.8f)
            MicProfile.WIRED_HEADSET     -> 1.0f   // wired: mouth-close, wider band (lowered from 1.2f)
            MicProfile.PHONE_MIC         -> 2.0f   // built-in: arm's-length, room noise
        }

        // Per-profile fast-VAD silence window (ms) — BT/wired tolerate slightly
        // longer pauses so a natural mid-sentence breath doesn't cut the utterance.
        // PHONE_MIC re-tuned (#25): the built-in mic has clean, well-defined
        // endpoints at arm's length, so a shorter window cuts the turn promptly
        // instead of leaving the user waiting on a dead pause.
        fun vadSilenceMs(profile: MicProfile): Long = when (profile) {
            MicProfile.BLUETOOTH_HEADSET -> 800L    // Increased from 500L
            MicProfile.WIRED_HEADSET     -> 600L    // Increased from 450L
            MicProfile.PHONE_MIC         -> 400L    // Re-tuned (#25): was 500L — snappier end-of-turn on the built-in mic
        }

        // Per-profile SpeechRecognizer end-of-speech silence lengths (ms).
        // BT/wired give a slightly longer trailing window to avoid cutting off
        // sentences that end quietly (common with headset mics at low volume).
        // PHONE_MIC re-tuned (#25): 2_500L matched BLUETOOTH and felt laggy on
        // the phone speaker path; the built-in mic endpoints cleanly so a
        // shorter complete-silence window keeps turn-taking responsive.
        fun completeSilenceMs(profile: MicProfile): Long = when (profile) {
            MicProfile.BLUETOOTH_HEADSET -> 2_500L // Increased from 1_500L
            MicProfile.WIRED_HEADSET     -> 2_000L // Increased from 1_350L
            MicProfile.PHONE_MIC         -> 1_600L // Re-tuned (#25): was 2_500L — shorter trailing window for the built-in mic
        }

        fun possiblyCompleteSilenceMs(profile: MicProfile): Long = when (profile) {
            MicProfile.BLUETOOTH_HEADSET -> 1_500L // Increased from 800L
            MicProfile.WIRED_HEADSET     -> 1_200L // Increased from 700L
            MicProfile.PHONE_MIC         -> 900L   // Re-tuned (#25): was 1_500L — earlier soft endpoint on the built-in mic
        }

        // ── Barge-in detection (#21) ──────────────────────────────────────────
        // RMS energy threshold the BargeInDetector must exceed to count a frame
        // as voice while Jarvis is speaking.  Higher on PHONE_MIC because the
        // built-in path mixes in loudspeaker TTS bleed (worst echo case); much
        // lower on close headset mics where bleed is minimal and the user's
        // voice dominates.  Falls back to the detector's own default when no
        // profile is supplied.
        fun bargeInEnergyThreshold(profile: MicProfile): Double = when (profile) {
            MicProfile.BLUETOOTH_HEADSET -> 1_200.0 // close mic, little speaker bleed
            MicProfile.WIRED_HEADSET     -> 1_400.0 // close mic, wider band
            MicProfile.PHONE_MIC         -> 2_200.0 // loudspeaker bleed — keep strict
        }

        // Sustained-voice hold (ms) required before declaring a barge-in.
        // Slightly longer on PHONE_MIC so a brief burst of the device's own TTS
        // echo can't masquerade as a single-word interruption; shorter on
        // headsets where short commands ("stop", "wait") should land fast.
        fun bargeInHoldMs(profile: MicProfile): Long = when (profile) {
            MicProfile.BLUETOOTH_HEADSET -> 280L
            MicProfile.WIRED_HEADSET     -> 300L
            MicProfile.PHONE_MIC         -> 360L
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
