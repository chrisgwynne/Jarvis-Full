package com.jarvis.assistant.accessibility

/**
 * Result from an [AppControlService] action.
 *
 * [Success.spoken] is intentionally short — one sentence at most.  Callers
 * map this to [com.jarvis.assistant.tools.framework.ToolResult] and route
 * through TTS.  An empty [spoken] string signals a silent success (scroll,
 * for example, needs no confirmation).
 */
sealed class AppActionResult {

    /** Action completed. [spoken] is empty for silent actions like scrolling. */
    data class Success(val spoken: String = "") : AppActionResult()

    /**
     * Action failed.  [reason] is an internal diagnostic label; [spoken] is
     * the concise user-facing line TTS will read.  Defaults [spoken] to
     * [reason] so callers don't have to supply both for one-liner failures.
     */
    data class Failure(
        val reason: String,
        val spoken: String = reason,
    ) : AppActionResult()

    /**
     * The current profile does not handle this action for the current screen
     * state.  The dispatcher falls through to [GenericAndroidProfile].
     */
    data class NotSupported(val reason: String) : AppActionResult()

    val isSuccess: Boolean get() = this is Success

    val spokenFeedback: String
        get() = when (this) {
            is Success      -> spoken
            is Failure      -> spoken
            is NotSupported -> reason
        }
}
