package com.jarvis.assistant.accessibility

import android.util.Log
import com.jarvis.assistant.accessibility.profiles.AppProfile
import com.jarvis.assistant.accessibility.profiles.GenericAndroidProfile
import com.jarvis.assistant.accessibility.profiles.SupportedAppProfiles

/**
 * AppControlService — orchestrates UAC (Universal App Controller) operations.
 *
 * Entry points match the five voice-controlled actions:
 *   • [scroll]          — scroll up / down via ACTION_SCROLL_FORWARD/BACKWARD
 *   • [pressButton]     — find and tap a visible button by label
 *   • [quickReply]      — type text into the active compose field and send
 *   • [startNavigation] — tap the Start button in a navigation route preview
 *
 * Profile resolution: [SupportedAppProfiles.forPackage] selects the best
 * [AppProfile] for the foreground package.  On [AppActionResult.NotSupported]
 * the service falls through to [GenericAndroidProfile].
 *
 * All public methods are suspend funs — call from a coroutine scope.
 */
object AppControlService {

    private const val TAG = "AppControlService"

    enum class ScrollDirection { UP, DOWN }

    // ── Scroll ────────────────────────────────────────────────────────────────

    suspend fun scroll(direction: ScrollDirection): AppActionResult {
        if (!JarvisAccessibilityService.isConnected()) {
            return AppActionResult.Failure(
                "accessibility not connected",
                "I need accessibility access for that. Enable it in Settings.",
            )
        }
        val ok = JarvisAccessibilityService.scroll(direction)
        return if (ok) AppActionResult.Success()   // silent — scroll needs no verbal ack
        else AppActionResult.Failure("scroll dispatch failed", "Couldn't scroll.")
    }

    // ── Press button ──────────────────────────────────────────────────────────

    suspend fun pressButton(label: String): AppActionResult {
        if (!JarvisAccessibilityService.isConnected()) {
            return AppActionResult.Failure(
                "accessibility not connected",
                "I need accessibility access for that. Enable it in Settings.",
            )
        }

        val snapshot = JarvisAccessibilityService.snapshot(withScreenshot = false)
            ?: return AppActionResult.Failure("snapshot null", "I can't see the screen.")

        if (snapshot.isStale()) {
            return AppActionResult.Failure("snapshot stale", "The screen changed before I could act.")
        }

        val candidates = snapshot.textTree.filter { it.isClickable && it.isEnabled }
        val match = pickMatch(candidates, label.lowercase().trim())
            ?: return AppActionResult.Failure(
                "no match for '$label'",
                "I can't find \"$label\" on screen.",
            )

        Log.d(TAG, "pressButton: tapping '${match.matchLabel}' for label='$label'")
        val ok = JarvisAccessibilityService.click(match)
        return if (ok) AppActionResult.Success("Done.")
        else AppActionResult.Failure("click failed on '${match.matchLabel}'", "Couldn't tap that.")
    }

    // ── Quick reply ───────────────────────────────────────────────────────────

    suspend fun quickReply(text: String): AppActionResult {
        val snapshot = JarvisAccessibilityService.snapshot(withScreenshot = false)
        val pkg = snapshot?.foregroundPackage

        Log.d(TAG, "quickReply: pkg=$pkg text='$text'")

        val profile = SupportedAppProfiles.forPackage(pkg)
        val result  = profile.quickReply(text)

        // Fall through to generic if the specific profile declined
        if (result is AppActionResult.NotSupported && profile !== GenericAndroidProfile) {
            Log.d(TAG, "quickReply: profile ${profile::class.simpleName} not supported, trying generic")
            return GenericAndroidProfile.quickReply(text)
        }
        return result
    }

    // ── Start navigation ──────────────────────────────────────────────────────

    suspend fun startNavigation(mode: AppProfile.NavMode = AppProfile.NavMode.DRIVING): AppActionResult {
        val snapshot = JarvisAccessibilityService.snapshot(withScreenshot = false)
        val pkg = snapshot?.foregroundPackage

        Log.d(TAG, "startNavigation: pkg=$pkg mode=$mode")

        val profile = SupportedAppProfiles.forPackage(pkg)
        val result  = profile.startNavigation(mode)

        if (result is AppActionResult.NotSupported && profile !== GenericAndroidProfile) {
            Log.d(TAG, "startNavigation: profile ${profile::class.simpleName} not supported, " +
                "trying generic")
            return GenericAndroidProfile.startNavigation(mode)
        }
        return result
    }

    // ── Shared helpers ────────────────────────────────────────────────────────

    /**
     * Score-based label match — mirrors [TapScreenTool.pickMatch] so UAC and
     * direct-tap feel consistent.
     */
    internal fun pickMatch(candidates: List<ScreenNode>, needle: String): ScreenNode? {
        val scored = candidates.mapNotNull { node ->
            val label = node.matchLabel.lowercase()
            if (label.isBlank()) return@mapNotNull null
            val score = when {
                label == needle                         -> 1000
                label.startsWith("$needle ")            -> 800
                label == needle.removePrefix("the ")    -> 750
                label.startsWith(needle)                -> 700
                label.contains(" $needle ")             -> 500
                label.contains(needle)                  -> 300
                else                                    -> 0
            }
            if (score == 0) null else node to score
        }
        if (scored.isEmpty()) return null
        return scored
            .sortedWith(
                compareByDescending<Pair<ScreenNode, Int>> { it.second }
                    .thenBy { val n = it.first; (n.boundsRight - n.boundsLeft) * (n.boundsBottom - n.boundsTop) }
            )
            .first().first
    }
}
