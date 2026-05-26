package com.jarvis.assistant.tools.device

import android.util.Log
import com.jarvis.assistant.gmail.GmailService
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * GmailTriageTool — read-only Gmail summaries.
 *
 * STATUS: scaffolded.  Reports "Gmail isn't set up yet" until the OAuth flow
 * has been wired (see [GmailService] docs for the setup checklist).
 *
 * Voice grammar:
 *   "any urgent emails?" / "anything important in my inbox?" /
 *   "what's in my inbox?" / "check my email" / "any new emails?"
 *
 * Returns a short, spoken summary of unread mail.  Never reads bodies aloud.
 */
class GmailTriageTool(
    private val gmail: GmailService,
) : Tool {

    override val name            = "gmail_triage"
    override val description     = "Summarise recent unread Gmail messages"
    override val requiresNetwork = true
    override val isLocalFallback = false
    override val requiredPermissions: List<String> = emptyList()

    companion object {
        private const val TAG = "GmailTriageTool"

        private val TRIGGER_RE = Regex(
            """(?ix)
            \b(?:
                any\s+(?:new\s+|urgent\s+|important\s+)?(?:emails?|mail|messages?\s+in\s+(?:my\s+)?inbox)
              | what(?:'s|\s+is)\s+(?:in\s+)?(?:my\s+)?inbox
              | check\s+(?:my\s+)?(?:email|inbox|gmail)
              | read\s+(?:my\s+)?(?:email|emails|inbox)
              | summarise\s+(?:my\s+)?(?:email|inbox)
              | any\s+important\s+messages
            )\b
            """,
        )
    }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Summarise recent unread emails.  Reads sender + subject only.",
    )

    override fun matches(transcript: String): ToolInput? =
        if (TRIGGER_RE.containsMatchIn(transcript)) ToolInput(transcript, emptyMap()) else null

    override suspend fun execute(input: ToolInput): ToolResult {
        Log.d(TAG, "[GMAIL_TRIAGE_REQUESTED]")
        if (!gmail.isConfigured) {
            return ToolResult.Failure(
                "Gmail isn't set up yet — connect it in Settings."
            )
        }
        val messages = try {
            gmail.recentUnread(limit = 5)
        } catch (e: Exception) {
            Log.w(TAG, "[GMAIL_FETCH_FAILED] ${e.message}")
            return ToolResult.Failure("Couldn't reach Gmail just now.")
        }
        if (messages.isEmpty()) {
            return ToolResult.Success("Inbox is clear.")
        }
        val n = messages.size
        val word = if (n == 1) "email" else "emails"
        val opener = "$n unread $word."
        val lines = messages.take(3).joinToString(" ") { m ->
            "${m.fromName.ifBlank { m.fromAddress }}: ${m.subject.ifBlank { "(no subject)" }}."
        }
        return ToolResult.Success("$opener $lines")
    }
}
