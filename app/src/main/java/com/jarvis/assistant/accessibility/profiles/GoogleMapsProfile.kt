package com.jarvis.assistant.accessibility.profiles

import android.util.Log
import com.jarvis.assistant.accessibility.AppActionResult
import com.jarvis.assistant.accessibility.JarvisAccessibilityService

/**
 * GoogleMapsProfile — taps the "Start" button in a Maps route-preview to begin
 * navigation without the user reaching for the phone.
 *
 * ### When this fires
 * The user has already asked Jarvis for directions (handled by [NavigateTool] /
 * [DirectionsTool]), Google Maps is in the foreground showing the route card,
 * and they say "start driving directions" / "start navigation" / "go".
 *
 * ### What it does
 * Scans the text tree for a clickable "Start" button and taps it.  If the
 * button isn't visible (route preview not shown), it returns a clear spoken
 * failure so the user knows to ask for directions first.
 *
 * ### What it does NOT do
 * Launch Maps or request new directions — those go through [NavigateTool].
 */
object GoogleMapsProfile : AppProfile {

    private const val TAG = "GoogleMapsProfile"

    override val packages = setOf("com.google.android.apps.maps")

    private val START_LABELS = setOf(
        "start", "start navigation", "go", "begin navigation",
        "start driving", "start walking", "start cycling",
    )

    override suspend fun startNavigation(mode: AppProfile.NavMode): AppActionResult {
        if (!JarvisAccessibilityService.isConnected()) {
            return AppActionResult.Failure(
                "accessibility not connected",
                "I need accessibility access to start navigation. Enable it in Settings.",
            )
        }

        val snapshot = JarvisAccessibilityService.snapshot(withScreenshot = false)
            ?: return AppActionResult.Failure("snapshot null", "Can't see the screen.")

        val pkg = snapshot.foregroundPackage ?: ""
        if (pkg !in packages) {
            return AppActionResult.NotSupported("foreground is $pkg, not Google Maps")
        }

        Log.d(TAG, "startNavigation: mode=$mode scanning ${snapshot.textTree.size} nodes")

        val startBtn = snapshot.textTree.firstOrNull { node ->
            node.isClickable && node.isEnabled &&
                node.matchLabel.lowercase().trim() in START_LABELS
        }

        if (startBtn == null) {
            Log.d(TAG, "startNavigation: Start button not found — route preview may not be visible")
            return AppActionResult.Failure(
                reason = "no Start button visible",
                spoken = "There's no route ready to start. Ask me for directions first.",
            )
        }

        Log.d(TAG, "startNavigation: tapping '${startBtn.matchLabel}' " +
            "@ (${startBtn.centerX}, ${startBtn.centerY})")
        val ok = JarvisAccessibilityService.click(startBtn)
        return if (ok) AppActionResult.Success("Starting navigation.")
        else AppActionResult.Failure("click failed on '${startBtn.matchLabel}'", "Couldn't tap Start.")
    }
}
