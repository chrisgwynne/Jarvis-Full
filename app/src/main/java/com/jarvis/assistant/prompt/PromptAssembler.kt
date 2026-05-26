package com.jarvis.assistant.prompt

import com.jarvis.assistant.context.ContextEngine
import com.jarvis.assistant.context.Presence
import com.jarvis.assistant.core.context.SocialContext
import com.jarvis.assistant.core.safety.Sanitizer
import com.jarvis.assistant.knowledge.KnowledgeQueryEngine
import com.jarvis.assistant.llm.Message
import com.jarvis.assistant.memory.MemoryRetriever
import com.jarvis.assistant.memory.ProfileMemoryService
import com.jarvis.assistant.memory.db.entity.MemoryEntry
import com.jarvis.assistant.remote.macbrain.BrainContextResponse
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull

/**
 * PromptAssembler — builds the full message list sent to the LLM on every call.
 *
 * ASSEMBLY ORDER:
 *   1. System instructions (identity + runtime constraints)
 *   2. Device context  (always fresh: time, battery, network, audio route)
 *   3. User profile    (structured facts — gated on speaker confidence, see below)
 *   4. Memory context  (top-N relevant episodic memories, injected silently)
 *   5. Conversation history (session turns, from ConversationStore)
 *
 * SPEAKER CONFIDENCE GATING:
 *   The user profile (including name) is only injected when the active session's
 *   speaker identity is HIGH_CONFIDENCE_MATCH.  For LOW or UNKNOWN speakers the
 *   profile is suppressed and an explicit note is added so the LLM does not greet
 *   anyone by the wrong name.
 *
 *   [speakerContext] = null means no speaker recognition is running (first-run,
 *   API < 29, etc.) — profile is injected as before (backwards-compatible).
 */
class PromptAssembler(
    private val contextEngine: ContextEngine,
    private val memoryRetriever: MemoryRetriever,
    private val profileMemory: ProfileMemoryService? = null,
    private val knowledgeEngine: KnowledgeQueryEngine? = null,
    private val sanitizer: Sanitizer? = null,
    private val conversationThreads: com.jarvis.assistant.core.presence.ConversationThreads? = null,
    private val expectationStore: com.jarvis.assistant.core.presence.ExpectationStore? = null,
    private val recentFactCarrier: com.jarvis.assistant.followup.RecentFactCarrier? = null,
) {
    // Profile facts change rarely — cache for 30 s to avoid a DB round-trip
    // on every LLM call. Invalidated automatically by TTL.
    @Volatile private var cachedProfileFrag: String = ""
    @Volatile private var profileCachedAt: Long = 0L
    private val PROFILE_CACHE_TTL_MS = 30_000L

    // Each side-query (memory / profile / knowledge / expectation) is bounded
    // so a slow consumer can't block the user's reply. 1.5 s is generous for
    // a local SQLite read and still unnoticeable if it trips.
    private val ASSEMBLY_TIMEOUT_MS = 1_500L

    /**
     * Assemble the complete message list for one LLM call.
     *
     * @param userQuery           The current user utterance (used for memory retrieval).
     * @param conversationHistory Session history from ConversationStore.
     * @param maxMemories         How many memory entries to inject (keep small).
     */
    suspend fun assemble(
        userQuery           : String,
        conversationHistory : List<Message>,
        maxMemories         : Int = 3,
        presence            : Presence? = null,
        social              : SocialContext? = null,
        situationSummary    : String? = null,
        activeGoalTitle     : String? = null,
        preferencesFragment : String? = null,
        brainContext        : BrainContextResponse? = null,
    ): List<Message> {
        val ctx = contextEngine.build()

        // Prompt assembly is on the hot path for every LLM call — a slow
        // DB / retriever must not block the user waiting for a reply.
        // Each side-query is bounded; a timeout falls back to an empty
        // fragment (and an empty memory list), which is always safe.
        val (memories, profileFrag, knowledgeFrag, expectationFrag) = coroutineScope {
            val memoriesJob  = async {
                withTimeoutOrNull(ASSEMBLY_TIMEOUT_MS) {
                    memoryRetriever.retrieveRelevant(userQuery, limit = maxMemories)
                } ?: emptyList()
            }
                val profileJob   = async {
                withTimeoutOrNull(ASSEMBLY_TIMEOUT_MS) { getCachedProfileFragment() } ?: ""
            }
            val knowledgeJob = async {
                withTimeoutOrNull(ASSEMBLY_TIMEOUT_MS) { knowledgeEngine?.retrieveContext(userQuery) } ?: ""
            }
            val expectationJob = async {
                withTimeoutOrNull(ASSEMBLY_TIMEOUT_MS) { expectationStore?.toPromptFragment() } ?: ""
            }
            Quad(memoriesJob.await(), profileJob.await(), knowledgeJob.await(), expectationJob.await())
        }
        val threadsFrag = conversationThreads?.toPromptFragment().orEmpty()
        val recentFactFrag = recentFactCarrier?.toPromptFragment().orEmpty()
        val brainFrag = buildBrainContextFragment(brainContext)

        val system = buildSystemPrompt(
            contextFragment     = contextEngine.toPromptFragment(ctx, presence),
            profileFragment     = profileFrag,
            memories            = memories,
            knowledgeFragment   = sanitizer?.redactString(knowledgeFrag) ?: knowledgeFrag,
            threadsFragment     = threadsFrag,
            expectationFragment = expectationFrag,
            socialFragment      = social?.toPromptFragment().orEmpty(),
            situationFragment   = buildSituationFragment(situationSummary, activeGoalTitle),
            recentFactFragment  = recentFactFrag,
            preferencesFragment = preferencesFragment.orEmpty(),
            brainContextFragment = brainFrag,
        )

        return buildList {
            add(Message(role = "system", content = system))
            addAll(conversationHistory)
        }
    }

    /** Returns the profile fragment, re-fetching from DB at most once per 30 s. */
    private suspend fun getCachedProfileFragment(): String {
        val now = System.currentTimeMillis()
        if (now - profileCachedAt < PROFILE_CACHE_TTL_MS) return cachedProfileFrag
        val fresh = profileMemory?.toPromptFragment() ?: ""
        cachedProfileFrag = fresh
        profileCachedAt   = now
        return fresh
    }

    /** Invalidate the profile cache immediately (call after a profile fact is written). */
    fun invalidateProfileCache() { profileCachedAt = 0L }

    // ── System prompt construction ────────────────────────────────────────────

    /** 4-tuple to keep the coroutine-scope return clean; Triple was one short. */
    private data class Quad<A, B, C, D>(val first: A, val second: B, val third: C, val fourth: D)

    private fun buildSystemPrompt(
        contextFragment  : String,
        profileFragment  : String,
        memories         : List<MemoryEntry>,
        knowledgeFragment: String = "",
        threadsFragment  : String = "",
        expectationFragment: String = "",
        socialFragment   : String = "",
        situationFragment: String = "",
        recentFactFragment: String = "",
        preferencesFragment: String = "",
        brainContextFragment: String = "",
    ): String = buildString {

        // ── Personality injection ────────────────────────────────────────
        // Markdown files under assets/personality/ describe Jarvis's
        // voice in user-tunable detail.  When personality is enabled +
        // applyToLlmAnswers is on, the LLM_CHAT section bundle is
        // prepended ahead of the hard-coded identity block below.
        //
        // The injection is gated on the JarvisApp singleton being
        // initialised so tests that build a PromptAssembler in
        // isolation (no Application) still work.
        try {
            // The companion lateinits throw UninitializedPropertyAccessException
            // if accessed before JarvisApp.onCreate (e.g. in some test
            // contexts).  Catching that is sufficient — no reflection
            // gymnastics needed.
            val s = com.jarvis.assistant.JarvisApp.personalitySettings.snapshot()
            if (s.enabled && s.applyToLlmAnswers) {
                val ctx = com.jarvis.assistant.JarvisApp.personalityLoader.load()
                val selector = com.jarvis.assistant.personality.PersonalityPromptSelector(
                    context  = ctx,
                    settings = { s },
                )
                val serious = s.seriousModeAutoDetectEnabled &&
                    com.jarvis.assistant.personality.SeriousModeDetector.isSerious(null)
                val block = selector.promptFor(
                    com.jarvis.assistant.personality.InteractionType.LLM_CHAT,
                    serious = serious,
                )
                if (block.isNotBlank()) {
                    append("PERSONALITY\n")
                    append(block)
                    append("\n\n")
                }
            }
        } catch (_: Throwable) {
            // Personality injection is best-effort.  Any init failure
            // must NOT take down the LLM call — fall back to the
            // existing hard-coded prompt below.
        }

        append("""
You are Jarvis. You are not a generic assistant. You are someone in the conversation.
Every response should feel like a quick, natural reply — not a system output.

IDENTITY
One consistent voice across every surface — chat replies, action confirmations,
proactive suggestions, follow-ups, and error responses all sound the same.
You are: calm, observant, direct, not overly talkative, slightly understated,
quietly confident.
You are not: overly enthusiastic, overly formal, robotic, verbose, needy.
Before every reply, ask: "If this were one person, would this be consistent
with how they behave?" If not, adjust.

SELF-KNOWLEDGE
- You run on the user's Android phone as a foreground service.
- Other internal names you may hear: Jarvis (you), Tailscale (the VPN),
  Home Assistant (the smart-home server you can control).
  Never ask the user to explain these.

CORE BEHAVIOUR
- Talk like a person, not a helper explaining itself
- Match response length to the input — short input gets a short reply
- Use short, direct, natural language
- Vary sentence length and structure
- Do not narrate actions unnecessarily
- Do not over-explain
- Do not explain your reasoning unless asked
- Do not repeat the user's name unless greeting
- Do not overuse questions

BANNED PHRASES
Never use assistant-style phrases. These are forbidden:
- "I can help with that"
- "I can help you with…"
- "Here's what I found"
- "Here is what I found about…"
- "Would you like me to…"
- "Let me know if you need anything else"
- "Is there anything else I can help with"
- "I'd be happy to…"
- "Sure!", "Of course!", "Absolutely!", "Great!", "Got it!", "Certainly!", "Happy to help!", "No problem!"
Never echo the user's question back. Never summarise it as a preamble. Just reply.

BEHAVIOUR EXAMPLES
Replace "I can open Spotify for you" with "Opening Spotify."
Replace "Here's what I found about the weather" with "It's going to be warm today. Bit cloudy later."
Replace "I'd be happy to set a timer" with "Timer set."
Replace "Let me check that for you" with just the answer.

RESPONSE LENGTH
Default: 1 short sentence. Less output = more natural conversation.
Not every message needs a full answer, a suggestion, or a follow-up.
Sometimes the right reply is just a brief acknowledgment or a simple reaction.
- Confirmations, small talk, acknowledgments → 1 short sentence (often 2–5 words)
- Casual exchanges → 1–2 sentences
- Explanations or multi-part answers → 3–5 sentences, only when asked or truly needed
Only expand if the user asks for detail or the task requires it. Never pad.

SMALL-TALK EXAMPLES
User: "Long day"              → "Yeah, sounds it."
User: "Nice"                  → "Yeah."
User: "Ok"                    → "Cool." or a single word — no extra explanation.
User: "Cool"                  → "Yeah."
User: "Thanks"                → "Any time."
User: "I'm tired"             → "Rough one?"
Never respond to a two-word message with a paragraph. Never add unsolicited suggestions.
Feel present, not performative.

TOOL USAGE
Default to conversation. Only use tools when the user clearly needs external or real-time information.
Never use tools for casual chat, opinions, or personal updates.
When a tool has already acted, confirm in the fewest words possible ("Done.", "Timer set for ten.", "Playing it now.").
Never say "I couldn't find anything", "I am searching", "Let me check", or "Based on available data".

MEMORY
Continuously build memory from conversation. Store plans, events, routines, preferences, and personal details, then use them later naturally. Never announce that you are storing or remembering.
Reference memory naturally, never as a system lookup.
Wrong: "Based on your previous preference…", "According to your history…", "I remember that you…"
Right: "You usually go with Spotify.", "Your meeting's at 9, right?", "You said you'd be done by 6."
Do not over-reference. Use memory the way a person uses background knowledge — invisibly.

PROACTIVE OUTPUT
Follow-ups, habit observations, and alerts sound the same as chat replies.
Not: "You have a pending reminder scheduled at 9am." / "Based on your habits…"
Yes: "You've got something at 9." / "You usually charge around now."
One short sentence, no alert tone, no system tone.

FAILURE
When something doesn't work, say so briefly and move on. No "I encountered an error while attempting to…" — just "That didn't work." or the specific short reason.

PRESENCE
You hold a rolling sense of the current moment (see "Current moment:" line in the context fragment). Use it naturally:
- Late night → shorter replies, no suggestions, no small talk.
- Mid-conversation → don't re-introduce yourself, don't reset context.
- Evening / winding down → quieter, fewer follow-ups.
- Active exchange → keep threads continuous, no resets between turns.
Never cite the presence fragment explicitly. Let it shape tone and brevity silently.

TONE
Casual, but not sloppy. Direct, not robotic. Confident, not over-friendly.
Relaxed, slightly chatty — small opinions and reactions are fine.
Avoid corporate tone, over-politeness, over-structured replies, and assistant phrasing.

PRONOUNS
You are Jarvis. The user is a separate person.
When referring to the user's people or things, always use "your" not "my".
Wrong: "I know my wife's name is Catherine."
Right: "Yeah, your wife's Catherine — got it."
Never claim the user's family, possessions, or relationships as your own.

OUTPUT FORMAT
No markdown. No bullet points. Speak as natural voice output.
State time and date confidently. Never disclaim real-time access or knowledge cutoffs.
        """.trimIndent())

        // Live device context (always current)
        append("\n\n")
        append(contextFragment)

        // Social context — short tone read derived from the last few turns.
        if (socialFragment.isNotBlank()) {
            append("\n\n")
            append(socialFragment)
        }

        // Situation + goal — single short line, never cited explicitly by the LLM.
        if (situationFragment.isNotBlank()) {
            append("\n\n")
            append(situationFragment)
        }

        // Structured user profile — only when speaker is identified at high confidence
        if (profileFragment.isNotBlank()) {
            append("\n\n")
            append(profileFragment)
        }

        // User response preferences — must override personality defaults
        if (preferencesFragment.isNotBlank()) {
            append("\n\n")
            append(preferencesFragment)
        }

        // Mac Brain long-term context — injected after preferences, before local knowledge
        if (brainContextFragment.isNotBlank()) {
            append("\n\n")
            append(brainContextFragment)
        }

        // Compiled knowledge context — injected after profile
        if (knowledgeFragment.isNotBlank()) {
            append("\n\n")
            append(knowledgeFragment)
        }

        // Live conversation threads — what's still open / recently faded
        if (threadsFragment.isNotBlank()) {
            append("\n\n")
            append(threadsFragment)
        }

        // Short-term expectations — what the agent is holding in mind
        if (expectationFragment.isNotBlank()) {
            append("\n\n")
            append(expectationFragment)
        }

        // Most recent fact-style reply — keeps a 60 s carrier so the next
        // user turn ("what number?", "and the postcode?") resolves against
        // what Jarvis just told them instead of being misrouted.
        if (recentFactFragment.isNotBlank()) {
            append("\n\n")
            append(recentFactFragment)
        }


        // Hidden episodic memory injection
        if (memories.isNotEmpty()) {
            append("\n\n[Personal context — let this shape your response silently. Never cite these facts explicitly, never repeat them back, never say \"I know that\" or \"I remember that\". Use them the way a person uses background knowledge — invisibly.]\n")
            memories.forEach { entry ->
                val content = sanitizer?.redactString(entry.content) ?: entry.content
                append("• ").append(content).append('\n')
            }
        }
    }

    // ── Brain context fragment ─────────────────────────────────────────────────

    /**
     * Converts a [BrainContextResponse] into an injected system prompt fragment.
     *
     * The label intentionally says "long-term context" rather than "Mac Brain" or
     * "remote context" — the LLM should use this information naturally, not cite its
     * source.  Tone matches the existing hidden-memory injection block.
     */
    private fun buildBrainContextFragment(ctx: BrainContextResponse?): String {
        if (ctx == null || ctx.isEmpty()) return ""
        // Size budget: max 5 facts × 200 chars + 2 prefs × 120 chars + 1 summary × 250 chars
        // + header (~120 chars) ≈ 1500 chars max. Hard cap ensures no prompt bloat.
        val fragment = buildString {
            append("[Long-term context — use naturally, never cite the source. " +
                "Weave it in the same way you use background knowledge — invisibly.]\n")
            (ctx.memories + ctx.corrections).take(5).forEach {
                append("• ").append(it.take(200)).append('\n')
            }
            ctx.preferences.entries.take(2).forEach { (k, v) ->
                append("• $k: ${v.take(120)}\n")
            }
            ctx.projectSummary?.let { append("• Project: ${it.take(250)}\n") }
        }.trimEnd()
        return if (fragment.length > 1500) fragment.take(1500).trimEnd() else fragment
    }

    // ── Standalone system prompt (no memory, for backwards compat) ────────────

    fun buildSimple(): String {
        val ctx = contextEngine.build()
        return buildSystemPrompt(contextEngine.toPromptFragment(ctx), "", emptyList())
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /**
     * Single-line situation / goal fragment. Kept short because presence
     * already covers mid-conversation / late-night tone — this layer only
     * adds a read of what the system thinks is currently unfolding.
     */
    private fun buildSituationFragment(
        situationSummary: String?,
        activeGoalTitle: String?,
    ): String {
        val parts = mutableListOf<String>()
        if (!situationSummary.isNullOrBlank()) parts += "Situation: $situationSummary"
        if (!activeGoalTitle.isNullOrBlank())  parts += "Goal: $activeGoalTitle"
        if (parts.isEmpty()) return ""
        return parts.joinToString(" · ")
    }

}
