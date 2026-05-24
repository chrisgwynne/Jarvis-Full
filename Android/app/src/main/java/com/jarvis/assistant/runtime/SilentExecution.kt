package com.jarvis.assistant.runtime

/**
 * SilentExecution — process-wide policy for "execute without speaking".
 *
 * For obvious, safe, deterministic actions the user hears + sees the result
 * (Spotify pauses, Maps opens, the light turns off) — narrating "Closing
 * Spotify." adds latency, steals audio focus from the music, and feels
 * robotic.  Replacing speech with a brief earcon (or no audible feedback at
 * all when paired with haptic) keeps Jarvis calm and out of the way.
 *
 * Policy:
 *   - For tools in [SILENT_SUCCESS_TOOLS], a successful invocation produces
 *     NO spoken feedback.  The runtime plays a subtle earcon instead.
 *   - Failures ALWAYS speak — the user needs the reason.
 *   - For tools that gate on follow-up (whatsapp, sms, call) the spoken text
 *     stays; those flows are conversational by nature.
 *   - The user can opt out via [enabled = false] (Settings hook).
 */
object SilentExecution {

    @Volatile var enabled: Boolean = true

    /**
     * Tools whose success message should be replaced by an earcon.
     * Drawn from the audit's "obvious local commands" list — Phase 6 of the
     * principal-architect brief.
     */
    val SILENT_SUCCESS_TOOLS: Set<String> = setOf(
        // app launcher / closer
        "open_app",
        "close_app",
        // media controls (also already silent via ToolResult.silent for some)
        "media_control",
        "music_search",
        // device toggles
        "flashlight",
        "volume",
        "brightness",
        "dnd",
        "screen_rotation",
        // smart home
        "smart_home",
        // home/saved-place navigation that fires an intent
        "home_navigation",
        "saved_place",
    )

    fun shouldBeSilentOnSuccess(toolName: String): Boolean =
        enabled && toolName in SILENT_SUCCESS_TOOLS
}
