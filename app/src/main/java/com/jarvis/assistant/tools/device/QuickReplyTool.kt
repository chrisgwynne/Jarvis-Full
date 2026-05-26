package com.jarvis.assistant.tools.device

import android.util.Log
import com.jarvis.assistant.accessibility.AppControlService
import com.jarvis.assistant.accessibility.JarvisAccessibilityService
import com.jarvis.assistant.overlay.OverlayEventBridge
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * QuickReplyTool — voice-driven compose + send for messaging apps.
 *
 * Supported phrases:
 *   "reply yes"          → send "yes" to open conversation
 *   "reply I'm on my way" → send "I'm on my way"
 *   "send it"            → confirm and send last dictated / pending message
 *   "type hello"         → type "hello" into the active compose field
 *
 * Guards: only fires when a messaging app (or any app with an editable compose
 * field) is in the foreground.  Does NOT fire when there is no text to send.
 *
 * Routing: delegates to [AppControlService.quickReply] which picks the best
 * [AppProfile] (WhatsApp-specific → generic Android fallback).
 */
class QuickReplyTool : Tool {

    override val name        = "quick_reply"
    override val description = "Type and send a reply in a messaging app"

    private val REPLY_RE = Regex(
        """(?:reply|respond|send)\s+(?:with\s+)?["']?(.+?)["']?\s*$""",
        RegexOption.IGNORE_CASE
    )
    private val TYPE_RE = Regex(
        """type\s+["']?(.+?)["']?\s*$""",
        RegexOption.IGNORE_CASE
    )
    // "send it" / "go ahead and send" — confirm-send with no body
    private val SEND_IT_RE = Regex(
        """(?:^|\s)(?:send\s+it|go\s+ahead(?:\s+and\s+send)?|send\s+the\s+message)\s*$""",
        RegexOption.IGNORE_CASE
    )

    override fun matches(transcript: String): ToolInput? {
        val t = transcript.trim()

        val reply = REPLY_RE.find(t)
        if (reply != null) {
            val text = reply.groupValues[1].trim().trimEnd('.', '!', '?')
            if (text.isNotBlank()) return ToolInput(transcript, mapOf("text" to text))
        }

        val type = TYPE_RE.find(t)
        if (type != null) {
            val text = type.groupValues[1].trim().trimEnd('.', '!')
            if (text.isNotBlank()) return ToolInput(transcript, mapOf("text" to text, "type_only" to "true"))
        }

        if (SEND_IT_RE.containsMatchIn(t)) {
            // Only handle "send it" when a messaging compose field is visible
            if (!JarvisAccessibilityService.isConnected()) return null
            return ToolInput(transcript, mapOf("text" to "", "confirm_send" to "true"))
        }

        return null
    }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Type a reply and send it in the foreground messaging app.",
        parameters  = mapOf(
            "type"       to "object",
            "properties" to mapOf(
                "text" to mapOf(
                    "type"        to "string",
                    "description" to "Message text to type and send.",
                )
            ),
            "required" to listOf("text"),
        )
    )

    override suspend fun execute(input: ToolInput): ToolResult {
        val text         = input.param("text").trim()
        val confirmSend  = input.paramOrNull("confirm_send") == "true"
        val typeOnly     = input.paramOrNull("type_only") == "true"

        if (text.isBlank() && !confirmSend) {
            return ToolResult.Failure("What should I reply?")
        }

        Log.d("QuickReplyTool", "execute: text='$text' confirmSend=$confirmSend typeOnly=$typeOnly")

        if (confirmSend) {
            // "send it" — try tapping the send button directly without typing
            val snapshot = JarvisAccessibilityService.snapshot(withScreenshot = false)
                ?: return ToolResult.Failure("I can't see the screen.")
            val sendNode = snapshot.textTree.firstOrNull { node ->
                node.isClickable && node.isEnabled && (
                    node.matchLabel.lowercase().trim() in SEND_LABELS ||
                    SEND_ID_SUFFIXES.any { node.viewId.endsWith(it) }
                )
            }
            return if (sendNode != null) {
                val ok = JarvisAccessibilityService.click(sendNode)
                if (ok) ToolResult.Success("Sent.") else ToolResult.Failure("Couldn't tap send.")
            } else {
                ToolResult.Failure("There's nothing in the compose box yet.")
            }
        }

        val result = AppControlService.quickReply(text)
        return if (result.isSuccess) {
            OverlayEventBridge.success(title = "Sent", dedupKey = "quick_reply_sent")
            ToolResult.Success(result.spokenFeedback)
        } else {
            OverlayEventBridge.failure(
                title    = "Couldn't send",
                message  = result.spokenFeedback,
                dedupKey = "quick_reply_failed",
            )
            ToolResult.Failure(result.spokenFeedback)
        }
    }

    private val SEND_LABELS = setOf("send", "send message", "send reply", "reply", "submit", "post")
    private val SEND_ID_SUFFIXES = setOf(
        "/send", "/send_btn", "/send_button", "/action_send", "/reply_send",
        "/message_send", "/input_send", "/btn_send",
    )
}
