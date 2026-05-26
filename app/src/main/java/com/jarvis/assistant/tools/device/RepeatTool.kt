package com.jarvis.assistant.tools.device

import android.util.Log
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * RepeatTool — "say that again", "what?", "repeat that".
 *
 * Reads the last spoken assistant utterance (held in [com.jarvis.assistant.audio.TtsEngine.lastSpokenText])
 * via the [getLastSpokenText] callback the runtime passes in, and returns it for
 * re-speaking.  No LLM round-trip; no remote call; no echo into AttentionGate
 * because the same field powers its echo-guard reference.
 *
 * Why a Tool, not a runtime intercept: the conversational classifier already
 * has clean Tool plumbing (matches → execute → spoken result), and the cost of
 * the extra Tool is one regex check per turn.
 */
class RepeatTool(
    private val getLastSpokenText: () -> String?,
) : Tool {

    override val name            = "repeat_last"
    override val description     = "Repeat the most recent assistant reply"
    override val requiresNetwork = false
    override val isLocalFallback = true
    override val requiredPermissions: List<String> = emptyList()

    companion object {
        private const val TAG = "RepeatTool"

        // High-specificity short phrases.  We intentionally don't match "what?"
        // alone — it's too ambiguous and would shadow legitimate clarifying
        // utterances during multi-turn flows.
        private val REPEAT_RE = Regex(
            """(?ix)
            ^\s*
            (?:
                (?:say|read|tell\s+me)\s+(?:that|it)\s+again
              | repeat\s+(?:that|it|what\s+you\s+(?:said|just\s+said))
              | what\s+(?:did|was)\s+(?:you|that)\s+(?:say|just\s+say)
              | say\s+again
              | come\s+again
              | once\s+more
              | one\s+more\s+time
            )
            [.?!]?
            \s*$
            """,
        )
    }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Re-speak the most recent assistant reply verbatim.",
    )

    override fun matches(transcript: String): ToolInput? =
        if (REPEAT_RE.containsMatchIn(transcript.trim()))
            ToolInput(transcript, emptyMap())
        else null

    override suspend fun execute(input: ToolInput): ToolResult {
        val last = getLastSpokenText()?.takeIf { it.isNotBlank() }
        Log.d(TAG, "[REPEAT_REQUESTED] hasLast=${last != null}")
        return if (last != null) {
            ToolResult.Success(last)
        } else {
            ToolResult.Success("Nothing to repeat yet.")
        }
    }
}
