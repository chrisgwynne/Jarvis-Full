package com.jarvis.assistant.accessibility.profiles

import android.util.Log
import com.jarvis.assistant.accessibility.AppActionResult
import com.jarvis.assistant.accessibility.JarvisAccessibilityService
import kotlinx.coroutines.delay

/**
 * WhatsAppProfile — quick-reply for WhatsApp and WhatsApp Business.
 *
 * Differences from [GenericAndroidProfile]:
 *   • Knows WhatsApp's specific send-button resource IDs across app versions,
 *     so icon-only send buttons (no text label) are found reliably.
 *   • Arms [JarvisAccessibilityService.arm] as a safety net after typing, so
 *     the existing WhatsApp auto-send logic fires if the direct tap misses.
 *   • Guards on [snapshot.foregroundPackage] to avoid operating on a stale
 *     snapshot from a previous WhatsApp session.
 */
object WhatsAppProfile : AppProfile {

    private const val TAG = "WhatsAppProfile"

    override val packages = setOf("com.whatsapp", "com.whatsapp.w4b")

    private val WA_SEND_IDS = listOf(
        "com.whatsapp:id/send",
        "com.whatsapp:id/send_btn",
        "com.whatsapp:id/send_button",
        "com.whatsapp.w4b:id/send",
        "com.whatsapp.w4b:id/send_btn",
        "com.whatsapp.w4b:id/send_button",
    )

    override suspend fun quickReply(text: String): AppActionResult {
        if (!JarvisAccessibilityService.isConnected()) {
            return AppActionResult.Failure(
                "accessibility not connected",
                "I need accessibility access to send that. Enable it in Settings.",
            )
        }

        val snapshot = JarvisAccessibilityService.snapshot(withScreenshot = false)
            ?: return AppActionResult.Failure("snapshot null", "Can't see the screen.")

        val pkg = snapshot.foregroundPackage ?: ""
        if (pkg !in packages) {
            return AppActionResult.NotSupported("foreground is $pkg, not WhatsApp")
        }

        val composeField = snapshot.textTree.firstOrNull { it.isEditable && it.isEnabled }
            ?: return AppActionResult.Failure("no compose field", "WhatsApp compose box isn't visible.")

        Log.d(TAG, "quickReply: typing '$text'")
        val typed = JarvisAccessibilityService.setText(composeField, text)
        if (!typed) {
            return AppActionResult.Failure("setText failed", "Couldn't type in the message box.")
        }

        delay(150)

        // Arm the existing auto-send mechanism as a safety net
        JarvisAccessibilityService.arm(pkg)

        // Attempt a direct tap on the send button so the user gets faster feedback
        val afterSnapshot = JarvisAccessibilityService.snapshot(withScreenshot = false)
        val sendNode = afterSnapshot?.textTree?.firstOrNull { node ->
            node.isClickable && node.isEnabled && WA_SEND_IDS.any { node.viewId == it }
        } ?: afterSnapshot?.textTree?.firstOrNull { node ->
            node.isClickable && node.isEnabled && node.matchLabel.lowercase().trim() == "send"
        }

        if (sendNode != null) {
            JarvisAccessibilityService.disarm()
            val ok = JarvisAccessibilityService.click(sendNode)
            Log.d(TAG, "quickReply: direct tap on '${sendNode.viewId}' ok=$ok")
            return if (ok) AppActionResult.Success("Sent.")
            else AppActionResult.Failure("click failed", "Couldn't tap send.")
        }

        // Auto-send is armed — it will fire on the next WhatsApp window event
        Log.d(TAG, "quickReply: armed auto-send (no send button found directly)")
        return AppActionResult.Success("Sending.")
    }
}
