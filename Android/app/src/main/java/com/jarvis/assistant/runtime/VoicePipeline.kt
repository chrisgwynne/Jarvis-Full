package com.jarvis.assistant.runtime

import android.content.Context
import android.util.Log
import com.jarvis.assistant.audio.AudioFocusManager
import com.jarvis.assistant.audio.BargeInDetector
import com.jarvis.assistant.audio.TtsEngine
import com.jarvis.assistant.brain.BrainEngine
import com.jarvis.assistant.context.Presence
import com.jarvis.assistant.conversation.ConversationClassifier
import com.jarvis.assistant.core.state.JarvisState
import com.jarvis.assistant.core.state.JarvisStateMachine
import com.jarvis.assistant.core.store.DeviceStateStore
import com.jarvis.assistant.data.ConversationCompressor
import com.jarvis.assistant.llm.LlmResult
import com.jarvis.assistant.llm.LlmRouter
import com.jarvis.assistant.llm.Message
import com.jarvis.assistant.llm.NetworkClient
import com.jarvis.assistant.memory.MemoryWriter
import com.jarvis.assistant.prompt.PromptAssembler
import com.jarvis.assistant.remote.macbrain.BrainContextRequest
import com.jarvis.assistant.remote.brain.BrainRoutingPolicy
import com.jarvis.assistant.remote.macbrain.MacBrainClient
import com.jarvis.assistant.security.ActionPolicyGate
import com.jarvis.assistant.speaker.SpeakerSessionContext
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolRegistry
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.util.LatencyTracker
import com.jarvis.assistant.util.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.CancellationException

/**
 * VoicePipeline — the extracted conversation processing pipeline.
 *
 * EXTRACTION STATUS:
 *   Interface and dependency list defined. JarvisRuntime still owns the
 *   implementation in its internal conversation loop (lines ~1030–1900).
 *
 * MIGRATION PLAN:
 *   Step A (current): Skeleton established with full dependency list.
 *   Step B: Move streamAndSpeak(), callLlm(), speakAndRecord() here.
 *   Step C: Move the while(true) conversation loop here; JarvisRuntime
 *           calls voicePipeline.run(scope) to start the loop.
 *
 * WHY EXTRACT:
 *   JarvisRuntime is ~2080 lines. The voice conversation loop (the part that
 *   processes one user turn from transcript → tool/LLM → TTS) is ~900 lines
 *   and has well-defined inputs/outputs, making it the natural extraction target.
 *   Separating it here would let us unit-test the conversation path against
 *   fake implementations of LlmRouter, TtsEngine, and ToolRegistry.
 */
class VoicePipeline(
    private val context: Context,
    private val machine: JarvisStateMachine,
    private val llmRouter: LlmRouter,
    private val promptAssembler: PromptAssembler,
    private val toolRegistry: ToolRegistry,
    private val tts: TtsCoordinator,
    private val bargeIn: BargeInDetector,
    private val memoryWriter: MemoryWriter,
    private val conversationCompressor: ConversationCompressor,
    private val conversationClassifier: ConversationClassifier,
    private val brainEngine: BrainEngine?,
    private val settings: SettingsStore,
    private val audioFocus: AudioFocusManager,
    private val drivingModeManager: DrivingModeManager,
    private val planRunner: com.jarvis.assistant.runtime.plan.PlanRunner,
    private val preferenceEngine: com.jarvis.assistant.preferences.ResponsePreferenceEngine,
    /** Called to sync the UI/diagnostic state when the pipeline transitions the machine. */
    private val syncState: (JarvisState) -> Unit,
    /** Called to retrieve the current speaker session context. */
    private val speakerContextProvider: () -> SpeakerSessionContext,
    /** Called to retrieve the current session ID. */
    private val sessionIdProvider: () -> String,
    /** Called to compute the current presence for the LLM. */
    private val presenceProvider: () -> Presence,
    private val macBrainClient: MacBrainClient? = null,
) {

    companion object {
        private const val TAG = "VoicePipeline"
        private const val MAX_TOOL_HOPS = 3
        private const val BRAIN_CONTEXT_TIMEOUT_MS = 2_000L
    }

    // Shared buffers for barge-in snapshot — populated as tokens arrive in streamAndSpeak().
    @Volatile private var currentSpokenSoFar : String = ""
    @Volatile private var currentPendingTail : String = ""
    @Volatile private var currentTurnTranscript : String = ""

    @Volatile private var pendingPlan : com.jarvis.assistant.runtime.plan.Plan? = null

    /**
     * Stored state for a response that was cut off by barge-in.
     * Populated by handleBargeIn(), consumed by the next conversation turn.
     */
    var lastInterrupted: com.jarvis.assistant.conversation.ResumableResponse? = null
        private set

    /**
     * Handle a barge-in event from the BargeInDetector.
     * Stops TTS, snapshots the current turn state for resumption, and transitions
     * the machine back to Listening.
     */
    fun handleBargeIn() {
        if (machine.current !is JarvisState.Speaking) return
        val tBarge = android.os.SystemClock.elapsedRealtime()
        Log.d(TAG, "[BARGE_IN_TRIGGERED] t=$tBarge")
        
        tts.stop()
        Log.d(TAG, "[BARGE_IN_TTS_STOPPED] +${android.os.SystemClock.elapsedRealtime() - tBarge}ms")
        LatencyTracker.mark("TURN_TIMING_BARGE_IN_CANCELLED")
        bargeIn.stop()

        // Snapshot unfinished reply so the next turn can decide whether to resume
        val spoken  = currentSpokenSoFar.trim()
        val pending = currentPendingTail.trim()
        if (spoken.isNotBlank() || pending.isNotBlank()) {
            lastInterrupted = com.jarvis.assistant.conversation.ResumableResponse(
                userTranscript = currentTurnTranscript,
                spokenSoFar    = spoken,
                pendingTail    = pending,
                topic          = spoken.take(60).ifBlank { pending.take(60) }
            )
            Log.d(TAG, "Stored resumable: spoken='${spoken.take(40)}' pending='${pending.take(40)}'")
        }

        machine.transition(JarvisState.Interrupted)
        syncState(JarvisState.Interrupted)
        machine.transition(JarvisState.Listening)
        syncState(JarvisState.Listening)
        Log.d(TAG, "[BARGE_IN_LISTEN_STARTED]")
    }

    /**
     * Start the conversation loop. Suspends until the pipeline is cancelled.
     *
     * @param scope Coroutine scope for launching sub-jobs (barge-in, memory writes).
     *
     * EXTRACTION TARGET: JarvisRuntime's while(true) loop at ~line 1030.
     */
    suspend fun run(scope: CoroutineScope) {
        // TODO: Extract conversation loop from JarvisRuntime here.
        // Current stub — JarvisRuntime still runs the loop directly.
        Log.d(TAG, "VoicePipeline.run() — delegation to JarvisRuntime (extraction pending)")
    }

    /**
     * Process one completed assistant turn: stream LLM response sentence by
     * sentence, feed each to TTS, handle barge-in, and save to history.
     *
     * EXTRACTION TARGET: JarvisRuntime.streamAndSpeak() at ~line 1740.
     */
    suspend fun streamAndSpeak(transcript: String, isOnline: Boolean) {
        if (!isOnline) {
            machine.transition(JarvisState.OfflineFallback)
            syncState(JarvisState.OfflineFallback)
            val fallback = com.jarvis.assistant.runtime.OfflineManager.offlineLlmFallback(transcript)
            machine.transition(JarvisState.Thinking)
            speakAndRecord(fallback)
            return
        }

        // Shared buffers for barge-in snapshot — populated as tokens arrive.
        currentSpokenSoFar = ""
        currentPendingTail = ""
        currentTurnTranscript = transcript

        try {
            llmRouter.conversationStore.addMessage("user", transcript)
            val history  = llmRouter.conversationStore.getContextMessages()
                .filter { it.role != "system" }
            val prefFrag = preferenceEngine.buildPromptFragment()
            // Skip Brain during interrupted flows — keep rapid back-and-forth fully local.
            val brainContext = when {
                lastInterrupted != null -> {
                    LatencyTracker.mark("TURN_TIMING_BRAIN_SKIPPED")
                    null
                }
                macBrainClient == null -> {
                    LatencyTracker.mark("TURN_TIMING_BRAIN_SKIPPED")
                    null
                }
                else -> {
                    val hint = BrainRoutingPolicy.intentHint(transcript)
                    if (hint == null) {
                        LatencyTracker.mark("TURN_TIMING_BRAIN_SKIPPED")
                        null
                    } else {
                        val allowed = when (hint) {
                            "project"           -> settings.macBrainAllowProject
                            "memory", "history" -> settings.macBrainAllowMemory
                            else                -> true
                        }
                        if (!allowed) {
                            LatencyTracker.mark("TURN_TIMING_BRAIN_SKIPPED")
                            null
                        } else {
                            val result = withTimeoutOrNull(BRAIN_CONTEXT_TIMEOUT_MS) {
                                macBrainClient.fetchContext(BrainContextRequest(
                                    transcript = transcript,
                                    intentHint = hint,
                                ))
                            }
                            LatencyTracker.mark("TURN_TIMING_BRAIN_DONE")
                            result
                        }
                    }
                }
            }
            val messages = promptAssembler.assemble(
                transcript, history, maxMemories = 4,
                speakerContext      = speakerContextProvider(),
                presence            = presenceProvider(),
                preferencesFragment = prefFrag,
                brainContext        = brainContext,
            )

            // ── Agentic tool chaining (up to MAX_TOOL_HOPS per turn) ──────────────
            val schemas = toolRegistry.availableSchemas(isOnline)
            if (schemas.isNotEmpty()) {
                val chainMessages = messages.toMutableList()
                var hopsUsed = 0
                var fcHandled = false

                while (hopsUsed < MAX_TOOL_HOPS) {
                    val fcResult = llmRouter.completeWithFunctionCalling(chainMessages, schemas)
                    when {
                        fcResult == null -> break   // provider has no FC — fall through to streaming

                        fcResult is LlmResult.Text -> {
                            val cleaned = llmRouter.stripReasoningTags(fcResult.content)
                            if (cleaned.isNotBlank()) {
                                llmRouter.conversationStore.addMessage("assistant", cleaned)
                                speakAndRecord(cleaned)
                                fcHandled = true
                            }
                            break
                        }

                        fcResult is LlmResult.MultiToolCall -> {
                            hopsUsed++
                            val proposal = planRunner.proposeFromMultiCall(fcResult, transcript)
                            when (proposal) {
                                is com.jarvis.assistant.runtime.plan.PlanRunner.Proposal.Pending -> {
                                    pendingPlan = proposal.plan
                                    llmRouter.conversationStore.addMessage("assistant", proposal.confirmation)
                                    speakAndRecord(proposal.confirmation)
                                    fcHandled = true
                                    break
                                }
                                is com.jarvis.assistant.runtime.plan.PlanRunner.Proposal.Empty -> {
                                    Log.d(TAG, "MultiToolCall didn't resolve to any registered tool")
                                    break
                                }
                                is com.jarvis.assistant.runtime.plan.PlanRunner.Proposal.SingleStep -> {
                                    // Fall through to parallel path
                                }
                            }

                            val callList = fcResult.calls
                            val feedbacks = coroutineScope {
                                callList.map { tc ->
                                    async<String?>(Dispatchers.IO) {
                                        val tool = toolRegistry.findByName(tc.toolName) ?: return@async null
                                        @Suppress("UNCHECKED_CAST")
                                        val argsMap = try {
                                            (NetworkClient.gson.fromJson(tc.argsJson, Map::class.java) as Map<*, *>)
                                                .entries.associate { (k, v) -> k.toString() to v.toString() }
                                        } catch (e: Exception) {
                                            Log.w(TAG, "Malformed tool args for ${tc.toolName}: ${e.message}")
                                            emptyMap()
                                        }
                                        LatencyTracker.mark("TURN_TIMING_LOCAL_TOOL_START")
                                        val result = toolRegistry.execute(context, tool, ToolInput(transcript, argsMap))
                                        LatencyTracker.mark("TURN_TIMING_LOCAL_TOOL_DONE")
                                        val fb = when (result) {
                                            is ToolResult.Success -> result.spokenFeedback
                                            is ToolResult.Failure -> result.spokenFeedback
                                            else -> null
                                        }
                                        fb?.let { "[${tool.name}]: $it" }
                                    }
                                }.awaitAll().filterNotNull()
                            }

                            if (feedbacks.isEmpty() || hopsUsed >= MAX_TOOL_HOPS) {
                                val combined = feedbacks.joinToString(". ")
                                if (combined.isNotBlank()) {
                                    llmRouter.conversationStore.addMessage("assistant", combined)
                                    speakAndRecord(combined)
                                    fcHandled = true
                                }
                                break
                            }
                            feedbacks.forEach { chainMessages.add(Message("assistant", it)) }
                        }

                        fcResult is LlmResult.ToolCall -> {
                            hopsUsed++
                            val tool = toolRegistry.findByName(fcResult.toolName)
                            if (tool == null) break

                            @Suppress("UNCHECKED_CAST")
                            val argsMap = try {
                                (NetworkClient.gson.fromJson(fcResult.argsJson, Map::class.java) as Map<*, *>)
                                    .entries.associate { (k, v) -> k.toString() to v.toString() }
                            } catch (e: Exception) {
                                Log.w(TAG, "Malformed tool args for ${fcResult.toolName}: ${e.message}")
                                emptyMap()
                            }

                            LatencyTracker.mark("TURN_TIMING_LOCAL_TOOL_START")
                            val result = toolRegistry.execute(context, tool, ToolInput(transcript, argsMap))
                            LatencyTracker.mark("TURN_TIMING_LOCAL_TOOL_DONE")

                            val feedback = when (result) {
                                is ToolResult.Success -> result.spokenFeedback
                                is ToolResult.Failure -> result.spokenFeedback
                                else -> null
                            }

                            if (feedback == null || result is ToolResult.Failure || hopsUsed >= MAX_TOOL_HOPS) {
                                if (feedback != null) {
                                    llmRouter.conversationStore.addMessage("assistant", feedback)
                                    speakAndRecord(feedback)
                                    fcHandled = true
                                }
                                break
                            }
                            chainMessages.add(Message("assistant", "[${tool.name}]: $feedback"))
                        }
                        else -> break
                    }
                }
                if (fcHandled) return   // agentic chain complete
            }

            val fullResponse    = StringBuilder()
            var speakingStarted = false

            llmRouter.streamWithMessages(messages).collect { sentence ->
                fullResponse.append(sentence).append(" ")

                if (!speakingStarted) {
                    speakingStarted = true
                    LatencyTracker.mark("LLM_FIRST_TOKEN")
                    LatencyTracker.mark("LLM_FIRST_SENTENCE")
                    machine.transition(JarvisState.Speaking)
                    DeviceStateStore.update { copy(ttsPlaying = true) }
                    syncState(JarvisState.Speaking)
                    if (settings.voiceResponse) {
                        LatencyTracker.mark("TTS_START")
                        LatencyTracker.mark("TURN_TIMING_TTS_START")
                        Log.d(TAG, "[AUDIO_FOCUS_REQUEST] local llm stream start")
                        audioFocus.requestFocus()
                        bargeIn.start()
                    }
                }

                val stillSpeaking = machine.current is JarvisState.Speaking
                if (stillSpeaking) {
                    currentSpokenSoFar += "$sentence "
                } else {
                    currentPendingTail += "$sentence "
                }

                if (settings.voiceResponse && stillSpeaking) {
                    tts.speak(sentence)
                }
            }

            if (settings.voiceResponse && speakingStarted) {
                bargeIn.stop()
                audioFocus.abandonFocus()
                Log.d(TAG, "[AUDIO_FOCUS_ABANDON] local llm stream done")
            }
            DeviceStateStore.update { copy(ttsPlaying = false) }
            LatencyTracker.mark("PIPELINE_DONE")

            val responseText = fullResponse.toString().trim()
            if (responseText.isNotBlank()) {
                val base      = ResponseFormatter.format(responseText)
                val formatted = if (drivingModeManager.isDriving)
                    base.split(Regex("(?<=[.!?])\\s+")).take(2).joinToString(" ")
                else base
                memoryWriter.writeTurn(sessionIdProvider(), "assistant", formatted)
                brainEngine?.collector?.onJarvisResponse(formatted)
                llmRouter.conversationStore.addMessage("assistant", responseText)
                DeviceStateStore.update { copy(lastAssistantResponse = formatted) }
            }

        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "Stream error: ${e.message}", e)
            speakAndRecord("Sorry, I had trouble thinking that through.")
        }
    }

    /**
     * Call the LLM with the full conversation history and return the complete
     * response string.
     *
     * EXTRACTION TARGET: JarvisRuntime.callLlm() at ~line 1700.
     */
    suspend fun callLlm(transcript: String, isOnline: Boolean): String {
        return try {
            llmRouter.conversationStore.addMessage("user", transcript)
            val history = llmRouter.conversationStore.getContextMessages()
                .filter { it.role != "system" }
            val prefFrag = preferenceEngine.buildPromptFragment()
            val brainContext = if (lastInterrupted != null) null
            else macBrainClient?.let { client ->
                BrainRoutingPolicy.intentHint(transcript)?.let { hint ->
                    withTimeoutOrNull(BRAIN_CONTEXT_TIMEOUT_MS) {
                        client.fetchContext(BrainContextRequest(
                            transcript = transcript,
                            intentHint = hint,
                        ))
                    }
                }
            }
            val messages = promptAssembler.assemble(
                transcript, history, maxMemories = 2,
                speakerContext      = speakerContextProvider(),
                presence            = presenceProvider(),
                preferencesFragment = prefFrag,
                brainContext        = brainContext,
            )
            llmRouter.completeWithMessages(messages)

        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "LLM error: ${e.message}", e)
            if (!isOnline) {
                // This branch shouldn't really be reached if isOnline is checked before
                // calling, but we keep it for symmetry with JarvisRuntime.
                "Hmm, I'm offline and can't reach the brain."
            } else {
                "Hmm, that didn't go through. Try me again?"
            }
        }
    }

    /**
     * Format a response, write it to memory, and speak it via TTS.
     *
     * EXTRACTION TARGET: JarvisRuntime.speakAndRecord() at ~line 1850.
     */
    suspend fun speakAndRecord(text: String) {
        val base = ResponseFormatter.format(text)
        // In driving mode, truncate to first 2 sentences to keep responses brief
        val formatted = if (drivingModeManager.isDriving) {
            base.split(Regex("(?<=[.!?])\\s+")).take(2).joinToString(" ")
        } else base
        memoryWriter.writeTurn(sessionIdProvider(), "assistant", formatted)
        brainEngine?.collector?.onJarvisResponse(formatted)
        DeviceStateStore.update { copy(lastAssistantResponse = formatted) }

        machine.transition(JarvisState.Speaking)
        DeviceStateStore.update { copy(ttsPlaying = true) }
        syncState(JarvisState.Speaking)

        if (settings.voiceResponse) {
            LatencyTracker.mark("TTS_START")
            LatencyTracker.mark("TURN_TIMING_TTS_START")
            Log.d(TAG, "[AUDIO_FOCUS_REQUEST] speakAndRecord")
            audioFocus.requestFocus()
            try {
                bargeIn.start()
                tts.speak(formatted)
                bargeIn.stop()
            } finally {
                audioFocus.abandonFocus()
                Log.d(TAG, "[AUDIO_FOCUS_ABANDON] speakAndRecord done")
            }
        }

        DeviceStateStore.update { copy(ttsPlaying = false) }
        LatencyTracker.mark("PIPELINE_DONE")
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    /**
     * Returns true when [transcript] contains signals that something should be
     * remembered or a preference is being expressed.
     *
     * These turns are queued as [com.jarvis.assistant.remote.macbrain.AndroidInteractionEvent.EventType.MEMORY_CANDIDATE]
     * for Brain to persist, so future sessions can recall them.
     */
    private fun isMemoryCandidate(transcript: String): Boolean {
        val t = transcript.lowercase()
        return "remember that" in t || "don't forget" in t || "remember, " in t ||
               "i prefer " in t || "i like " in t || "i hate " in t || "i dislike " in t ||
               "my name is " in t || "i'm called " in t || "call me " in t ||
               "i always " in t || "i never " in t
    }
}
