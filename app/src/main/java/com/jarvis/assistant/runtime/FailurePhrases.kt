package com.jarvis.assistant.runtime

import com.jarvis.assistant.phrases.PhraseKey
import com.jarvis.assistant.phrases.PhraseResolver

/**
 * FailurePhrases — voice-friendly error strings for tools and error paths.
 *
 * Every constant here is ALSO registered in PhraseRegistry under the corresponding
 * PhraseKey.FAILURE_* key, which means users can edit them via the Phrases settings
 * screen. The constants below serve as compile-time defaults and as direct fallbacks
 * for call sites that do not have access to a PhraseResolver.
 *
 * Call sites that DO have a PhraseResolver should use [resolve] so that user
 * edits to the phrase library take effect at runtime.
 */
object FailurePhrases {

    // ── Generic ────────────────────────────────────────────────────────────

    /** PhraseKey: [PhraseKey.FAILURE_GENERIC] */
    const val GENERIC = "That didn't work."

    /** PhraseKey: [PhraseKey.FAILURE_SOMETHING_WENT_WRONG] */
    const val SOMETHING_WENT_WRONG = "Something went wrong."

    // ── Connectivity / system ──────────────────────────────────────────────

    /** PhraseKey: [PhraseKey.FAILURE_AUDIO_UNAVAILABLE] */
    const val AUDIO_SERVICE_UNAVAILABLE  = "Audio isn't available right now."

    /** PhraseKey: [PhraseKey.FAILURE_CAMERA_UNAVAILABLE] */
    const val CAMERA_SERVICE_UNAVAILABLE = "The camera isn't available right now."

    /** PhraseKey: [PhraseKey.FAILURE_NO_FLASH] */
    const val NO_FLASH                   = "No flash on this phone."

    // ── Tools ──────────────────────────────────────────────────────────────

    /** PhraseKey: [PhraseKey.FAILURE_MEDIA_CONTROL] */
    const val MEDIA_CONTROL_FAILED      = "I couldn't control the media."

    /** PhraseKey: [PhraseKey.FAILURE_FLASHLIGHT] */
    const val FLASHLIGHT_DIDNT_RESPOND  = "Flashlight didn't respond."

    /** PhraseKey: [PhraseKey.FAILURE_RECORDING] */
    const val RECORDING_FAILED          = "Recording failed to start."

    /** PhraseKey: [PhraseKey.FAILURE_TRANSCRIPTION] */
    const val TRANSCRIPTION_FAILED      = "Transcription failed — please try again."

    /** PhraseKey: [PhraseKey.FAILURE_IMAGE_ANALYSIS] */
    const val IMAGE_ANALYSIS_FAILED     = "Image was captured but I couldn't analyse it."

    /** PhraseKey: [PhraseKey.FAILURE_IMAGE_GENERATION] */
    const val IMAGE_GENERATION_FAILED   = "Image generation failed — please try again."

    /** PhraseKey: [PhraseKey.FAILURE_CAMERA_CAPTURE] */
    const val CAMERA_CAPTURE_FAILED     = "The camera couldn't capture a photo."

    /** PhraseKey: [PhraseKey.FAILURE_EXPORT] */
    const val EXPORT_FAILED             = "Couldn't save the conversation — check storage space."

    /** PhraseKey: [PhraseKey.FAILURE_EMAIL_APP] */
    const val EMAIL_APP_UNAVAILABLE     = "Couldn't open the email app."

    /** PhraseKey: [PhraseKey.FAILURE_TIMER] */
    const val TIMER_FAILED              = "Couldn't set the timer — please try again."

    /** PhraseKey: [PhraseKey.FAILURE_TIMER_DURATION] */
    const val TIMER_DURATION_UNCLEAR    = "I couldn't work out that duration — opening the timer app."

    /** PhraseKey: [PhraseKey.FAILURE_ALARM] */
    const val ALARM_FAILED              = "Couldn't set the alarm — please try again."

    /** PhraseKey: [PhraseKey.FAILURE_CALL] */
    const val CALL_FAILED               = "Couldn't place the call — please try again."

    /** PhraseKey: [PhraseKey.FAILURE_SMS] */
    const val SMS_FAILED                = "Couldn't send the message — please try again."

    /** PhraseKey: [PhraseKey.FAILURE_FIND_PHONE_RINGER] */
    const val FIND_PHONE_RINGER_FAILED  = "Couldn't ring the phone."

    // ── App launching ──────────────────────────────────────────────────────

    /**
     * PhraseKey: [PhraseKey.FAILURE_APP_NOT_INSTALLED]
     *
     * Direct-string fallback for call sites without a resolver. Prefer
     * [resolve] with [PhraseKey.FAILURE_APP_NOT_INSTALLED] and `vars=mapOf("app" to name)`.
     */
    fun appNotInstalled(appNameCapitalised: String) =
        "$appNameCapitalised isn't installed on this phone."

    // ── Resolver helper ────────────────────────────────────────────────────

    /**
     * Resolve [phraseKey] via [resolver] if available, falling back to
     * [default]. Use this in call sites that have a PhraseResolver injected,
     * so user edits in the Phrases library are respected at runtime.
     */
    fun resolve(
        phraseKey: String,
        resolver: PhraseResolver?,
        default: String,
        vars: Map<String, String> = emptyMap(),
    ): String = resolver?.resolve(phraseKey, vars)?.takeIf { it.isNotBlank() } ?: default
}
