package com.jarvis.assistant.tools.device

import android.util.Log
import com.jarvis.assistant.runtime.GuestMode
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * GuestModeTool — voice toggle for [GuestMode].
 *
 * Grammar:
 *   ON     — "guest mode on" / "enable guest mode" / "lock it down" /
 *            "lock down for 10 minutes" / "guest mode for half an hour"
 *   OFF    — "guest mode off" / "disable guest mode" / "unlock" /
 *            "exit guest mode"
 *   STATUS — "is guest mode on?" / "are we in guest mode?"
 *
 * Status replies report the remaining time when active.
 */
class GuestModeTool : Tool {

    override val name            = "guest_mode"
    override val description     = "Enable or disable guest mode (no memory writes, no destructive actions)"
    override val requiresNetwork = false
    override val isLocalFallback = true
    override val requiredPermissions: List<String> = emptyList()

    companion object {
        private const val TAG = "GuestModeTool"

        // "guest mode on", "enable guest mode", "lock it down for 10 minutes"
        private val ON_RE = Regex(
            """(?ix)
            ^\s*
            (?:
                (?:enable|turn\s+on|start|activate)\s+guest\s+mode
              | guest\s+mode\s+(?:on|please)
              | lock(?:\s+it)?\s+down
              | go\s+(?:into\s+)?guest\s+mode
            )
            (?<dur>
                \s+for\s+
                (?:half\s+an\s+hour | \d+\s*(?:minutes?|mins?|hours?))
            )?
            \s*[.?!]?\s*$
            """,
        )

        private val OFF_RE = Regex(
            """(?ix)
            ^\s*
            (?:
                (?:disable|turn\s+off|exit|stop|deactivate)\s+guest\s+mode
              | guest\s+mode\s+off
              | unlock
              | leave\s+guest\s+mode
            )
            \s*[.?!]?\s*$
            """,
        )

        private val STATUS_RE = Regex(
            """(?ix)
            ^\s*
            (?:
                (?:are\s+we|am\s+i)\s+in\s+guest\s+mode
              | is\s+guest\s+mode\s+(?:on|active|enabled)
              | guest\s+mode\s+status
            )
            \s*[.?!]?\s*$
            """,
        )

        private val DURATION_PARSE = Regex(
            """(\d+)\s*(minutes?|mins?|hours?|hour)""",
            RegexOption.IGNORE_CASE,
        )

        private fun parseDuration(dur: String?): Long {
            if (dur.isNullOrBlank()) return GuestMode.DEFAULT_DURATION_MS
            if (dur.contains("half an hour", ignoreCase = true)) return 30 * 60_000L
            val m = DURATION_PARSE.find(dur) ?: return GuestMode.DEFAULT_DURATION_MS
            val n    = m.groupValues[1].toLongOrNull() ?: return GuestMode.DEFAULT_DURATION_MS
            val unit = m.groupValues[2].lowercase()
            return if (unit.startsWith("hour")) n * 60 * 60_000L else n * 60_000L
        }

        private fun humaniseMs(ms: Long): String {
            val totalMins = ms / 60_000L
            if (totalMins < 1L) return "under a minute"
            if (totalMins == 1L) return "a minute"
            if (totalMins < 60L) return "$totalMins minutes"
            val hours = totalMins / 60L
            val mins  = totalMins % 60L
            return when {
                hours == 1L && mins == 0L -> "an hour"
                mins == 0L                -> "$hours hours"
                hours == 1L               -> "an hour and $mins minutes"
                else                      -> "$hours hours and $mins minutes"
            }
        }
    }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Toggle guest mode on or off; report status.",
        parameters  = mapOf(
            "type" to "object",
            "properties" to mapOf(
                "action" to mapOf("type" to "string",
                    "enum" to listOf("ON", "OFF", "STATUS")),
                "durationMs" to mapOf("type" to "number"),
            ),
            "required" to listOf("action"),
        )
    )

    override fun matches(transcript: String): ToolInput? {
        val t = transcript.trim()
        ON_RE.find(t)?.let { m ->
            val dur = parseDuration(m.groups["dur"]?.value)
            return ToolInput(t, mapOf("action" to "ON", "durationMs" to dur.toString()))
        }
        if (OFF_RE.containsMatchIn(t)) return ToolInput(t, mapOf("action" to "OFF"))
        if (STATUS_RE.containsMatchIn(t)) return ToolInput(t, mapOf("action" to "STATUS"))
        return null
    }

    override suspend fun execute(input: ToolInput): ToolResult {
        val action = input.param("action")
        Log.d(TAG, "[GUEST_MODE_ACTION] action=$action")
        return when (action) {
            "ON" -> {
                val dur = input.paramOrNull("durationMs")?.toLongOrNull()
                    ?: GuestMode.DEFAULT_DURATION_MS
                GuestMode.enable(dur)
                ToolResult.Success("Guest mode on for ${humaniseMs(dur)}.")
            }
            "OFF" -> {
                GuestMode.disable()
                ToolResult.Success("Guest mode off.")
            }
            "STATUS" -> {
                if (GuestMode.isActive) {
                    ToolResult.Success("Guest mode on, about ${humaniseMs(GuestMode.remainingMs)} left.")
                } else {
                    ToolResult.Success("Guest mode is off.")
                }
            }
            else -> ToolResult.Failure("Unknown guest-mode action.")
        }
    }
}
