package com.jarvis.assistant.federation

import android.content.Context
import android.util.Log
import com.jarvis.assistant.tools.framework.RiskClass
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import java.util.UUID
import java.util.regex.Pattern

private const val TAG = "FederationHandoffTool"

/**
 * FederationHandoffTool — voice-triggered bridge between Android and Mac Jarvis.
 *
 * Recognised phrases (case-insensitive):
 *  - "send (this|that) to (the )?mac"         → [FederationMessage.ContinueOnMacRequest]
 *  - "continue (this|that) on (the )?mac"     → [FederationMessage.ContinueOnMacRequest]
 *  - "show (this|that) on (the )?mac"         → [FederationMessage.ContinueOnMacRequest] with displayHint="show"
 *  - "ask mac (jarvis )?to (.+)"              → [FederationMessage.WorkflowRequest] with description=group
 *  - "remember this on mac"                   → [FederationMessage.MemoryCaptureRequest] category="general"
 *  - "analyse this (later|on mac)?"           → [MacTaskRequest] type=CUSTOM
 *  - "review (this )?on mac"                  → [MacTaskRequest] type=CODE_REVIEW
 *  - "review this( when I get home)?"         → [MacTaskRequest] type=CUSTOM, urgency=LOW
 *
 * The [snapshotBuilder] lambda is called at execute time to build the current
 * [ContextSnapshot] — this avoids a circular dependency between the tool and
 * whatever builds context at runtime.
 *
 * [execute] never blocks the voice pipeline: it enqueues the message and returns
 * immediately.
 */
class FederationHandoffTool(
    private val context: Context,
    private val federationManager: FederationManager,
    private val snapshotBuilder: () -> ContextSnapshot,
) : Tool {

    override val name: String = "federation_handoff"
    override val description: String = "Send context, tasks, or requests to Mac Jarvis over the federation layer."
    override val riskClass: RiskClass = RiskClass.LOW
    override val requiresNetwork: Boolean = false // federation uses local/Tailscale, not internet
    override val isLocalFallback: Boolean = true  // works offline (queues for later)

    // ── Match patterns ────────────────────────────────────────────────────────

    private sealed interface MatchResult {
        data class SendToMac(val displayHint: String = "") : MatchResult
        data class ContinueOnMac(val displayHint: String = "") : MatchResult
        data class AskMac(val description: String) : MatchResult
        data class RememberOnMac(val content: String) : MatchResult
        data class AnalyseThis(val later: Boolean) : MatchResult
        data class ReviewOnMac(val codeContext: Boolean) : MatchResult
        data class ReviewWhenHome(val transcript: String) : MatchResult
    }

    private data class PatternEntry(
        val regex: Pattern,
        val factory: (java.util.regex.Matcher) -> MatchResult,
    )

    private val patterns: List<PatternEntry> = listOf(
        PatternEntry(
            Pattern.compile("""send\s+(this|that)\s+to\s+(the\s+)?mac""", Pattern.CASE_INSENSITIVE)
        ) { _ -> MatchResult.SendToMac() },

        PatternEntry(
            Pattern.compile("""continue\s+(this|that)\s+on\s+(the\s+)?mac""", Pattern.CASE_INSENSITIVE)
        ) { _ -> MatchResult.ContinueOnMac() },

        PatternEntry(
            Pattern.compile("""show\s+(this|that)\s+on\s+(the\s+)?mac""", Pattern.CASE_INSENSITIVE)
        ) { _ -> MatchResult.SendToMac(displayHint = "show") },

        PatternEntry(
            Pattern.compile("""ask\s+mac\s+(?:jarvis\s+)?to\s+(.+)""", Pattern.CASE_INSENSITIVE)
        ) { m -> MatchResult.AskMac(description = m.group(1)?.trim() ?: "") },

        PatternEntry(
            Pattern.compile("""remember\s+this\s+on\s+mac""", Pattern.CASE_INSENSITIVE)
        ) { _ -> MatchResult.RememberOnMac(content = "") },

        PatternEntry(
            Pattern.compile("""analyse\s+this(?:\s+(later|on\s+mac))?""", Pattern.CASE_INSENSITIVE)
        ) { m -> MatchResult.AnalyseThis(later = m.group(1) != null) },

        PatternEntry(
            Pattern.compile("""review(?:\s+this)?\s+on\s+mac""", Pattern.CASE_INSENSITIVE)
        ) { _ -> MatchResult.ReviewOnMac(codeContext = false) },

        PatternEntry(
            Pattern.compile("""review\s+this(?:\s+when\s+i\s+get\s+home)?""", Pattern.CASE_INSENSITIVE)
        ) { _ -> MatchResult.ReviewWhenHome(transcript = "") },
    )

    override fun matches(transcript: String): ToolInput? {
        val trimmed = transcript.trim()
        for (entry in patterns) {
            val matcher = entry.regex.matcher(trimmed)
            if (matcher.find()) {
                val matchResult = entry.factory(matcher)
                val params = buildParams(matchResult, trimmed)
                Log.d(TAG, "matches: matched '${matchResult::class.simpleName}' for transcript='$trimmed'")
                return ToolInput(transcript = trimmed, params = params)
            }
        }
        return null
    }

    private fun buildParams(match: MatchResult, transcript: String): Map<String, String> {
        return when (match) {
            is MatchResult.SendToMac        -> mapOf("action" to "send_to_mac", "displayHint" to match.displayHint)
            is MatchResult.ContinueOnMac    -> mapOf("action" to "continue_on_mac", "displayHint" to match.displayHint)
            is MatchResult.AskMac           -> mapOf("action" to "ask_mac", "description" to match.description)
            is MatchResult.RememberOnMac    -> mapOf("action" to "remember_on_mac", "content" to transcript)
            is MatchResult.AnalyseThis      -> mapOf("action" to "analyse_this", "later" to match.later.toString())
            is MatchResult.ReviewOnMac      -> mapOf("action" to "review_on_mac")
            is MatchResult.ReviewWhenHome   -> mapOf("action" to "review_when_home")
        }
    }

    // ── Execution ─────────────────────────────────────────────────────────────

    override suspend fun execute(input: ToolInput): ToolResult {
        val action = input.paramOrNull("action") ?: return ToolResult.Failure(
            spokenFeedback = "I couldn't figure out what to send to Mac."
        )

        val snapshot = try {
            snapshotBuilder()
        } catch (e: Exception) {
            Log.e(TAG, "execute: snapshotBuilder threw", e)
            ContextSnapshot()
        }

        val macAvailable = federationManager.isConnected()
        val deviceId = resolveDeviceId()

        val message: FederationMessage = when (action) {
            "send_to_mac", "continue_on_mac" -> {
                val displayHint = input.paramOrNull("displayHint") ?: ""
                val userPrompt = snapshot.currentIntent ?: input.transcript
                FederationMessage.ContinueOnMacRequest(
                    contextSnapshot = snapshot,
                    userPrompt = userPrompt,
                    displayHint = displayHint,
                    sourceDeviceId = deviceId,
                )
            }
            "ask_mac" -> {
                val description = input.paramOrNull("description") ?: input.transcript
                FederationMessage.WorkflowRequest(
                    workflowId = UUID.randomUUID().toString(),
                    title = "Voice request from Android",
                    description = description,
                    payload = emptyMap(),
                    sourceDeviceId = deviceId,
                )
            }
            "remember_on_mac" -> {
                val content = input.paramOrNull("content")
                    ?: snapshot.transcriptWindow.lastOrNull()
                    ?: input.transcript
                FederationMessage.MemoryCaptureRequest(
                    content = content,
                    category = "general",
                    source = "android_voice",
                    sourceDeviceId = deviceId,
                )
            }
            "analyse_this" -> {
                val taskRequest = MacTaskRequest(
                    taskType = MacTaskType.CUSTOM,
                    title = "Analyse — requested from Android",
                    description = snapshot.currentIntent ?: input.transcript,
                    urgency = TaskUrgency.NORMAL,
                    returnPreference = ReturnPreference.SPOKEN_SUMMARY,
                    contextSnapshot = snapshot,
                )
                federationManager.requestMacTask(taskRequest)
                return queuedOrSentResult(macAvailable)
            }
            "review_on_mac" -> {
                val hasCodeContext = snapshot.screenContentSummary?.contains("code", ignoreCase = true) == true
                    || snapshot.activeAppPackage?.contains("code", ignoreCase = true) == true
                val taskRequest = MacTaskRequest(
                    taskType = if (hasCodeContext) MacTaskType.CODE_REVIEW else MacTaskType.CUSTOM,
                    title = "Review — requested from Android",
                    description = snapshot.currentIntent ?: input.transcript,
                    urgency = TaskUrgency.NORMAL,
                    returnPreference = ReturnPreference.SPOKEN_SUMMARY,
                    contextSnapshot = snapshot,
                )
                federationManager.requestMacTask(taskRequest)
                return queuedOrSentResult(macAvailable)
            }
            "review_when_home" -> {
                val taskRequest = MacTaskRequest(
                    taskType = MacTaskType.CUSTOM,
                    title = "Review when home — queued from Android",
                    description = snapshot.currentIntent ?: input.transcript,
                    urgency = TaskUrgency.LOW,
                    returnPreference = ReturnPreference.SPOKEN_SUMMARY,
                    contextSnapshot = snapshot,
                )
                federationManager.requestMacTask(taskRequest)
                return queuedOrSentResult(macAvailable)
            }
            else -> {
                Log.w(TAG, "execute: unknown action '$action'")
                return ToolResult.Failure(spokenFeedback = "I'm not sure how to hand that off to Mac.")
            }
        }

        // For non-MacTaskRequest paths, send via federationManager
        federationManager.sendAsync(message)
        return queuedOrSentResult(macAvailable)
    }

    private fun queuedOrSentResult(macAvailable: Boolean): ToolResult.Success {
        return if (macAvailable) {
            ToolResult.Success(spokenFeedback = "Sent to Mac.")
        } else {
            ToolResult.Success(spokenFeedback = "Queued for Mac when it's available.")
        }
    }

    private fun resolveDeviceId(): String {
        return try {
            android.provider.Settings.Secure.getString(
                context.contentResolver,
                android.provider.Settings.Secure.ANDROID_ID,
            ) ?: "unknown"
        } catch (e: Exception) {
            Log.w(TAG, "resolveDeviceId: failed to read ANDROID_ID", e)
            "unknown"
        }
    }
}
