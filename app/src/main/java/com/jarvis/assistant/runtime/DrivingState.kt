package com.jarvis.assistant.runtime

/**
 * DrivingState — a process-wide flag that any subsystem can read to apply
 * driving-aware behaviour (terser replies, suppressed visual prompts, etc.).
 *
 * The flag is written exclusively by [DrivingModeManager] in its
 * `onDrivingStateChanged` callback; everything else only reads it.  Decoupling
 * the signal from the manager keeps the dozens of read sites (formatters,
 * tool gates, prompt assembler) free of a heavy dependency.
 *
 * Volatile, no synchronisation: it's a single boolean, set once per state
 * change, and consumers don't need to coordinate.
 */
object DrivingState {
    @Volatile var isDriving: Boolean = false

    /**
     * Tools that require the user to look at the screen or aim the camera —
     * unsafe while driving.  Names here MUST match the [com.jarvis.assistant
     * .tools.framework.Tool.name] string.
     */
    val VISUAL_TOOLS_BLOCKED_WHEN_DRIVING = setOf(
        "ocr_scan",
        "read_screen",
        "tap_screen",
        "screenshot",
        "camera_capture",
        "selfie_capture",
        "analyze_camera_view",
        "view_media",
        "share_media",
        "image_generation",
    )

    fun shouldBlockToolWhileDriving(toolName: String): Boolean =
        isDriving && toolName in VISUAL_TOOLS_BLOCKED_WHEN_DRIVING
}
