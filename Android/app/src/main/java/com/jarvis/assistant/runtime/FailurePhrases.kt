package com.jarvis.assistant.runtime

/**
 * FailurePhrases — single source for the short, voice-friendly strings
 * the various tools and error paths surface when something goes wrong.
 *
 * Keeping these together matters because the Jarvis voice is consistent
 * by policy (see `CLAUDE.md`): every error should sound like the same
 * person speaking.  When new tools land they should pick an entry here
 * rather than invent a new fallback string.
 */
object FailurePhrases {

    // ── Generic ────────────────────────────────────────────────────────────

    /** All-purpose failure when we don't have anything more specific. */
    const val GENERIC = "That didn't work."

    /** Internal / unexpected error; matches LlmRouter and subagents. */
    const val SOMETHING_WENT_WRONG = "Something went wrong."

    // ── Connectivity / system ──────────────────────────────────────────────

    const val AUDIO_SERVICE_UNAVAILABLE  = "Audio isn't available right now."
    const val CAMERA_SERVICE_UNAVAILABLE = "The camera isn't available right now."
    const val NO_FLASH                   = "No flash on this phone."

    // ── Tools ──────────────────────────────────────────────────────────────

    const val MEDIA_CONTROL_FAILED      = "I couldn't control the media."
    const val FLASHLIGHT_DIDNT_RESPOND  = "Flashlight didn't respond."
    const val RECORDING_FAILED          = "Recording failed to start."
    const val TRANSCRIPTION_FAILED      = "Transcription failed — please try again."
    const val IMAGE_ANALYSIS_FAILED     = "Image was captured but I couldn't analyse it."
    const val IMAGE_GENERATION_FAILED   = "Image generation failed — please try again."
    const val CAMERA_CAPTURE_FAILED     = "The camera couldn't capture a photo."
    const val EXPORT_FAILED             = "Couldn't save the conversation — check storage space."
    const val EMAIL_APP_UNAVAILABLE     = "Couldn't open the email app."
    const val TIMER_FAILED              = "Couldn't set the timer — please try again."
    const val TIMER_DURATION_UNCLEAR    = "I couldn't work out that duration — opening the timer app."
    const val ALARM_FAILED              = "Couldn't set the alarm — please try again."
    const val CALL_FAILED               = "Couldn't place the call — please try again."
    const val SMS_FAILED                = "Couldn't send the message — please try again."
    const val FIND_PHONE_RINGER_FAILED  = "Couldn't ring the phone."

    // ── App launching ──────────────────────────────────────────────────────

    fun appNotInstalled(appNameCapitalised: String) =
        "$appNameCapitalised isn't installed on this phone."
}
