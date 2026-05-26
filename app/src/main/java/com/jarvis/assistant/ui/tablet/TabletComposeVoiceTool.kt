package com.jarvis.assistant.ui.tablet

import android.content.Context
import com.jarvis.assistant.tools.framework.RiskClass
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * TabletComposeVoiceTool — voice tool for mutating email compose state on tablet.
 *
 * Guards: [TabletContextBridge.isTabletActive] must be true.
 *
 * Handles in-compose mutations NOT covered by [EmailTool]:
 *  - "Set subject to X" / "change subject to X" / "subject: X"
 *  - "Set body to X" / "email body: X"
 *  - "Also say X" / "add X to the body"
 *  - "Send email" / "send the email now"
 *  - "Save draft" / "save this email"
 *  - "Discard email" / "clear the draft" / "cancel email"
 *  - "Remove attachment" / "remove the file"
 *  - "Attach this to the email" / "add attachment" (delegates to file tool logic)
 *
 * Each match emits a [TabletEmailVoiceIntent] to [TabletEmailCommandStore] which
 * is applied by [TabletEmailComposeViewModel].
 *
 * PHONE BEHAVIOUR: UNCHANGED — [matches] returns null when tablet is inactive.
 */
class TabletComposeVoiceTool(
    @Suppress("UNUSED_PARAMETER") context: Context,
) : Tool {

    override val name            = "tablet_compose"
    override val description     = "Mutate tablet email compose state via voice"
    override val riskClass       = RiskClass.LOW
    override val requiresNetwork = false

    override fun schema(): ToolSchema? = null

    // ── Matchers ──────────────────────────────────────────────────────────────

    private val SET_SUBJECT = Regex(
        """(?:set|change|update)\s+(?:the\s+)?(?:email\s+)?subject\s+to\s+(.+)|subject\s*:\s*(.+)""",
        RegexOption.IGNORE_CASE
    )
    private val SET_BODY = Regex(
        """(?:set|update)\s+(?:the\s+)?(?:email\s+)?body\s+to\s+(.+)|(?:email\s+)?body\s*:\s*(.+)""",
        RegexOption.IGNORE_CASE
    )
    private val APPEND_BODY = Regex(
        """(?:also\s+say|add\s+to\s+(?:the\s+)?(?:email|body)|append\s+to\s+(?:the\s+)?(?:email|body))\s+(.+)""",
        RegexOption.IGNORE_CASE
    )
    // "send email" with no trailing recipient — anchored at end so "send email to Cath"
    // is NOT captured here (EmailTool handles that on both phone and tablet).
    private val SEND_EMAIL = Regex(
        """send\s+(?:the\s+)?email(?:\s+now)?$""",
        RegexOption.IGNORE_CASE
    )
    private val SAVE_DRAFT = Regex(
        """save\s+(?:the\s+)?(?:draft|email|this\s+email)$""",
        RegexOption.IGNORE_CASE
    )
    private val CLEAR_DRAFT = Regex(
        """(?:discard|cancel|clear|delete|scrap)\s+(?:the\s+)?(?:draft|email|compose|this\s+email)$""",
        RegexOption.IGNORE_CASE
    )
    private val REMOVE_ATTACH = Regex(
        """remove\s+(?:the\s+)?(?:attachment|attached\s+file|file)$""",
        RegexOption.IGNORE_CASE
    )

    override fun matches(transcript: String): ToolInput? {
        if (!TabletContextBridge.isTabletActive) return null
        val t = transcript.trim()

        val (action, detail) = when {
            SET_SUBJECT.containsMatchIn(t) -> {
                val m = SET_SUBJECT.find(t)!!
                "set_subject" to (m.groupValues[1].ifBlank { m.groupValues[2] }).trim()
            }
            SET_BODY.containsMatchIn(t) -> {
                val m = SET_BODY.find(t)!!
                "set_body" to (m.groupValues[1].ifBlank { m.groupValues[2] }).trim()
            }
            APPEND_BODY.containsMatchIn(t) -> {
                val m = APPEND_BODY.find(t)!!
                "append_body" to m.groupValues[1].trim()
            }
            SEND_EMAIL.containsMatchIn(t)   -> "send"         to ""
            SAVE_DRAFT.containsMatchIn(t)   -> "save_draft"   to ""
            CLEAR_DRAFT.containsMatchIn(t)  -> "clear_draft"  to ""
            REMOVE_ATTACH.containsMatchIn(t)-> "remove_attach" to ""
            else -> return null
        }

        // Reject if a detail-carrying action has no detail
        if (detail.isBlank() && action in listOf("set_subject", "set_body", "append_body")) {
            return null
        }

        return ToolInput(transcript, mapOf("action" to action, "detail" to detail))
    }

    override suspend fun execute(input: ToolInput): ToolResult {
        val action = input.param("action")
        val detail = input.param("detail")

        val intent = when (action) {
            "set_subject"  -> TabletEmailVoiceIntent(subject = detail)
            "set_body"     -> TabletEmailVoiceIntent(body = detail)
            "append_body"  -> TabletEmailVoiceIntent(appendBody = detail)
            "send"         -> TabletEmailVoiceIntent(send = true)
            "save_draft"   -> TabletEmailVoiceIntent(saveDraft = true)
            "clear_draft"  -> TabletEmailVoiceIntent(clearDraft = true)
            "remove_attach"-> TabletEmailVoiceIntent(removeLastAttachment = true)
            else           -> null
        }

        if (intent != null) TabletEmailCommandStore.post(intent)

        return when (action) {
            "set_subject"   -> ToolResult.Success("Subject set to: $detail")
            "set_body"      -> ToolResult.Success("Email body updated.")
            "append_body"   -> ToolResult.Success("Added to body: $detail")
            "send"          -> ToolResult.Success("Sending email.")
            "save_draft"    -> ToolResult.Success("Draft saved.")
            "clear_draft"   -> ToolResult.Success("Email compose cleared.")
            "remove_attach" -> ToolResult.Success("Attachment removed.")
            else            -> ToolResult.Success("Done.")
        }
    }
}
