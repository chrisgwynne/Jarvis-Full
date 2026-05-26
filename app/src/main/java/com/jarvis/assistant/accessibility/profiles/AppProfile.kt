package com.jarvis.assistant.accessibility.profiles

import com.jarvis.assistant.accessibility.AppActionResult

/**
 * AppProfile — app-specific action handler for the Universal App Controller.
 *
 * Profiles carry knowledge about one or more packages: the exact resource IDs
 * their send buttons use, how their compose fields are structured, what "Start
 * navigation" looks like in the UI tree, etc.
 *
 * The [AppControlService] resolves a profile via [SupportedAppProfiles], calls
 * the matching method, and falls back to [GenericAndroidProfile] when the result
 * is [AppActionResult.NotSupported].
 *
 * Default implementations return [AppActionResult.NotSupported] so subclasses
 * only override the actions they know about.
 */
interface AppProfile {

    /** Package names this profile covers. Empty set is reserved for [GenericAndroidProfile]. */
    val packages: Set<String>

    /**
     * Mode passed to [startNavigation] so the profile can select the correct
     * transport-mode button when the route-preview shows multiple options.
     */
    enum class NavMode { DRIVING, WALKING, CYCLING }

    /** Type into the active compose field and tap the send button. */
    suspend fun quickReply(text: String): AppActionResult =
        AppActionResult.NotSupported("quickReply not implemented by ${javaClass.simpleName}")

    /** Tap the "Start" button in a navigation app's route-preview screen. */
    suspend fun startNavigation(mode: NavMode = NavMode.DRIVING): AppActionResult =
        AppActionResult.NotSupported("startNavigation not implemented by ${javaClass.simpleName}")
}
