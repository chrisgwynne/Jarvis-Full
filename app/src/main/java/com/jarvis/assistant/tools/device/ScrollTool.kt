package com.jarvis.assistant.tools.device

import com.jarvis.assistant.accessibility.AppControlService
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * ScrollTool — "scroll down", "scroll up", "swipe down", "page down", etc.
 *
 * Routes through [AppControlService.scroll] → [JarvisAccessibilityService.scroll]
 * → [ScreenActuator.scroll].  Silent on success — no verbal confirmation
 * needed for a scroll gesture.
 */
class ScrollTool : Tool {

    override val name        = "scroll_screen"
    override val description = "Scroll the current screen up or down"

    private val SCROLL_DOWN_RE = Regex(
        """(?:scroll|swipe|page|move)\s+down|scroll\s+the\s+page\s+down""",
        RegexOption.IGNORE_CASE
    )
    private val SCROLL_UP_RE = Regex(
        """(?:scroll|swipe|page|move)\s+up|scroll\s+the\s+page\s+up""",
        RegexOption.IGNORE_CASE
    )

    override fun matches(transcript: String): ToolInput? {
        val t = transcript.trim()
        return when {
            SCROLL_DOWN_RE.containsMatchIn(t) -> ToolInput(transcript, mapOf("direction" to "down"))
            SCROLL_UP_RE.containsMatchIn(t)   -> ToolInput(transcript, mapOf("direction" to "up"))
            else                              -> null
        }
    }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Scroll the foreground screen up or down.",
        parameters  = mapOf(
            "type"       to "object",
            "properties" to mapOf(
                "direction" to mapOf(
                    "type"        to "string",
                    "description" to "Scroll direction: 'up' or 'down'.",
                    "enum"        to listOf("up", "down"),
                )
            ),
            "required" to listOf("direction"),
        )
    )

    override suspend fun execute(input: ToolInput): ToolResult {
        val direction = when (input.param("direction").lowercase()) {
            "up"   -> AppControlService.ScrollDirection.UP
            else   -> AppControlService.ScrollDirection.DOWN
        }
        val result = AppControlService.scroll(direction)
        return if (result.isSuccess) {
            ToolResult.Success(spokenFeedback = "", silent = true)
        } else {
            ToolResult.Failure(result.spokenFeedback)
        }
    }
}
