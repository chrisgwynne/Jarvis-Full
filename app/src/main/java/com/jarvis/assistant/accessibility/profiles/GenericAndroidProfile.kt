package com.jarvis.assistant.accessibility.profiles

import android.util.Log
import com.jarvis.assistant.accessibility.AppActionResult
import com.jarvis.assistant.accessibility.JarvisAccessibilityService
import kotlinx.coroutines.delay

/**
 * GenericAndroidProfile — fallback quick-reply handler for any app.
 *
 * Algorithm:
 *   1. Take a text-tree snapshot (no screenshot — latency-sensitive).
 *   2. Find the first enabled, editable node (compose / reply field).
 *   3. Set text via ACTION_SET_TEXT.
 *   4. Wait 120 ms for the app to re-enable the send button.
 *   5. Re-snapshot, find the send button by label OR resource-ID suffix.
 *   6. Tap it.
 *
 * Send-button detection uses two passes:
 *   Pass 1 — known human-visible labels ("send", "post", "submit", …)
 *   Pass 2 — known resource-ID suffixes ("/send", "/action_send", …)
 * This covers both text-labelled buttons and icon-only buttons.
 */
object GenericAndroidProfile : AppProfile {

    private const val TAG = "GenericAndroidProfile"

    override val packages: Set<String> = emptySet()

    override suspend fun quickReply(text: String): AppActionResult {
        if (!JarvisAccessibilityService.isConnected()) {
            return AppActionResult.Failure(
                reason = "accessibility not connected",
                spoken = "I need accessibility access to reply. Enable it in Settings.",
            )
        }

        val snapshot = JarvisAccessibilityService.snapshot(withScreenshot = false)
            ?: return AppActionResult.Failure("snapshot null", "I can't see the screen.")

        val composeField = snapshot.textTree.firstOrNull { it.isEditable && it.isEnabled }
            ?: return AppActionResult.Failure(
                "no editable field",
                "There's no text box visible to type into.",
            )

        Log.d(TAG, "quickReply: setting text='$text' on field viewId=${composeField.viewId}")
        val typed = JarvisAccessibilityService.setText(composeField, text)
        if (!typed) {
            return AppActionResult.Failure("setText failed", "Couldn't type in the message box.")
        }

        delay(120)

        val afterSnapshot = JarvisAccessibilityService.snapshot(withScreenshot = false)
            ?: return AppActionResult.Failure("post-type snapshot null", "Lost the screen after typing.")

        // Pass 1: label match
        val byLabel = afterSnapshot.textTree.firstOrNull { node ->
            node.isClickable && node.isEnabled &&
                node.matchLabel.lowercase().trim() in SEND_LABELS
        }
        if (byLabel != null) {
            val ok = JarvisAccessibilityService.click(byLabel)
            return if (ok) AppActionResult.Success("Sent.")
            else AppActionResult.Failure("click failed label='${byLabel.matchLabel}'", "Couldn't tap send.")
        }

        // Pass 2: resource-ID suffix match (icon-only send buttons)
        val byId = afterSnapshot.textTree.firstOrNull { node ->
            node.isClickable && node.isEnabled &&
                SEND_ID_SUFFIXES.any { suffix -> node.viewId.endsWith(suffix) }
        }
        if (byId != null) {
            Log.d(TAG, "quickReply: send by id '${byId.viewId}'")
            val ok = JarvisAccessibilityService.click(byId)
            return if (ok) AppActionResult.Success("Sent.")
            else AppActionResult.Failure("click failed id='${byId.viewId}'", "Couldn't tap send.")
        }

        return AppActionResult.Failure("no send button", "Can't find a send button.")
    }

    private val SEND_LABELS = setOf(
        "send", "send message", "send reply", "reply", "submit", "post", "done",
    )

    private val SEND_ID_SUFFIXES = setOf(
        "/send", "/send_btn", "/send_button", "/action_send",
        "/reply_send", "/message_send", "/input_send", "/btn_send",
    )
}
