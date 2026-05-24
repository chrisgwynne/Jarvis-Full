package com.jarvis.assistant.ui.tablet

import android.content.Context
import android.content.Intent
import com.jarvis.assistant.tools.framework.RiskClass
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * TabletFileVoiceTool — voice tool for file-context operations on the tablet.
 *
 * Guards:
 *  1. [TabletContextBridge.isTabletActive] must be true.
 *  2. A file must be selected in [TabletFileContextStore].
 *
 * Handled phrases (MIME-agnostic; works for any selected file type):
 *  - "email this file" / "attach this" / "attach this to the email"
 *  - "send this PDF to Cath" / "send this file"
 *  - "share this file" / "share this image"
 *  - "open this file" / "view this document"
 *
 * PHONE BEHAVIOUR: UNCHANGED — [matches] returns null when tablet is inactive.
 */
class TabletFileVoiceTool(private val context: Context) : Tool {

    override val name            = "tablet_file_context"
    override val description     = "Perform file operations on the currently selected tablet file"
    override val riskClass       = RiskClass.LOW
    override val requiresNetwork = false

    override fun schema(): ToolSchema? = null   // not exposed to LLM function calling

    // ── Matchers ──────────────────────────────────────────────────────────────

    private val EMAIL_ATTACH = Regex(
        """(?:email|attach|send)\s+(?:this|the\s+selected|the\s+current)?\s*(?:file|pdf|image|photo|document|attachment)(?:\s+to\s+.+)?""" +
        """|attach\s+this(?:\s+to\s+(?:the\s+)?email)?""",
        RegexOption.IGNORE_CASE
    )
    private val SHARE_FILE = Regex(
        """share\s+(?:this|the\s+selected)?\s*(?:file|pdf|image|photo|document)""",
        RegexOption.IGNORE_CASE
    )
    private val OPEN_FILE = Regex(
        """(?:open|view|show)\s+(?:this|the\s+selected)?\s*(?:file|pdf|image|photo|document)""",
        RegexOption.IGNORE_CASE
    )

    override fun matches(transcript: String): ToolInput? {
        if (!TabletContextBridge.isTabletActive) return null
        if (!TabletFileContextStore.hasSelection) return null

        val t = transcript.trim()
        val action = when {
            EMAIL_ATTACH.containsMatchIn(t) -> "attach"
            SHARE_FILE.containsMatchIn(t)   -> "share"
            OPEN_FILE.containsMatchIn(t)    -> "open"
            else                            -> return null
        }
        return ToolInput(transcript, mapOf("action" to action))
    }

    override suspend fun execute(input: ToolInput): ToolResult {
        val file = TabletFileContextStore.current
            ?: return ToolResult.Success(
                "No file is selected. Open the Files panel and tap a file first."
            )

        return when (input.param("action")) {
            "attach" -> {
                TabletEmailCommandStore.post(
                    TabletEmailVoiceIntent(
                        attachCurrentFile = true,
                        navigateTo        = TabletDestination.Email,
                    )
                )
                ToolResult.Success("Attaching ${file.name} to the email compose screen.")
            }

            "share" -> {
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = file.mimeType
                    putExtra(Intent.EXTRA_STREAM, file.uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                return try {
                    context.startActivity(
                        Intent.createChooser(intent, "Share ${file.name}")
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    ToolResult.Success("Sharing ${file.name}.")
                } catch (_: Exception) {
                    ToolResult.Failure("Couldn't open the share sheet.")
                }
            }

            "open" -> {
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(file.uri, file.mimeType)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                return try {
                    context.startActivity(intent)
                    ToolResult.Success("Opening ${file.name}.")
                } catch (_: Exception) {
                    ToolResult.Failure("No app found to open that file type.")
                }
            }

            else -> ToolResult.Success("File context ready.")
        }
    }
}
