package com.jarvis.assistant.tools.device

import com.jarvis.assistant.accessibility.AppControlService
import com.jarvis.assistant.accessibility.profiles.AppProfile
import com.jarvis.assistant.overlay.OverlayEventBridge
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * StartNavigationTool — taps the "Start" button in a navigation app's route
 * preview screen.
 *
 * Supported phrases:
 *   "start driving directions"  / "start driving"
 *   "start walking directions"  / "start walking"
 *   "start cycling"
 *   "start navigation"          / "begin navigation"
 *   "go" (when Maps route preview is visible)
 *   "start the route"
 *
 * The tool does NOT launch Maps or request directions — those are handled by
 * [NavigateTool] and [DirectionsTool].  It only fires the Start tap once Maps
 * is already showing a route card.
 *
 * Routes through [AppControlService.startNavigation] → [GoogleMapsProfile].
 */
class StartNavigationTool : Tool {

    override val name        = "start_navigation"
    override val description = "Start turn-by-turn navigation when a route is already showing"

    private val DRIVING_RE = Regex(
        """(?:start|begin|go)\s+(?:driving|driving\s+directions|drive|the\s+route|route|navigation|driving\s+navigation)""",
        RegexOption.IGNORE_CASE
    )
    private val WALKING_RE = Regex(
        """(?:start|begin)\s+(?:walking|walking\s+directions|walk|walking\s+navigation)""",
        RegexOption.IGNORE_CASE
    )
    private val CYCLING_RE = Regex(
        """(?:start|begin)\s+(?:cycling|cycling\s+directions|cycling\s+navigation)""",
        RegexOption.IGNORE_CASE
    )
    private val GENERIC_RE = Regex(
        """(?:start|begin)\s+(?:navigation|directions|navigating)|start\s+the\s+route""",
        RegexOption.IGNORE_CASE
    )

    override fun matches(transcript: String): ToolInput? {
        val t = transcript.trim()
        return when {
            WALKING_RE.containsMatchIn(t) -> ToolInput(transcript, mapOf("mode" to "walking"))
            CYCLING_RE.containsMatchIn(t) -> ToolInput(transcript, mapOf("mode" to "cycling"))
            DRIVING_RE.containsMatchIn(t) -> ToolInput(transcript, mapOf("mode" to "driving"))
            GENERIC_RE.containsMatchIn(t) -> ToolInput(transcript, mapOf("mode" to "driving"))
            else                          -> null
        }
    }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Tap Start in a navigation app's route preview to begin turn-by-turn directions.",
        parameters  = mapOf(
            "type"       to "object",
            "properties" to mapOf(
                "mode" to mapOf(
                    "type"        to "string",
                    "description" to "Transport mode: driving, walking, or cycling.",
                    "enum"        to listOf("driving", "walking", "cycling"),
                )
            ),
            "required" to listOf("mode"),
        )
    )

    override suspend fun execute(input: ToolInput): ToolResult {
        val mode = when (input.param("mode").lowercase()) {
            "walking" -> AppProfile.NavMode.WALKING
            "cycling" -> AppProfile.NavMode.CYCLING
            else      -> AppProfile.NavMode.DRIVING
        }
        val result = AppControlService.startNavigation(mode)
        return if (result.isSuccess) {
            val modeLabel = when (mode) {
                AppProfile.NavMode.WALKING -> "Walking"
                AppProfile.NavMode.CYCLING -> "Cycling"
                else                       -> "Driving"
            }
            OverlayEventBridge.showNavigation(
                title   = "$modeLabel directions",
                message = "Navigation started",
            )
            ToolResult.Success(result.spokenFeedback)
        } else {
            OverlayEventBridge.failure(
                title    = "Navigation unavailable",
                message  = result.spokenFeedback,
                dedupKey = "nav_failed",
            )
            ToolResult.Failure(result.spokenFeedback)
        }
    }
}
