package com.jarvis.assistant.tools.device

import android.content.Context
import android.util.Log
import com.jarvis.assistant.tools.ContactAliasStore
import com.jarvis.assistant.tools.ContactLookup
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * ContactAliasTool — teach Jarvis a nickname for a real contact, or forget one.
 *
 * Voice grammar:
 *   SAVE   — "save wifey as Sarah", "remember wifey is Sarah Smith",
 *            "use wifey for Sarah"
 *   FORGET — "forget the alias wifey", "remove wifey alias"
 *
 * The save form requires the target name to actually exist in the address
 * book — otherwise we'd save an alias the user can never message.  The
 * existence check uses [ContactLookup.find] which already handles fuzzy
 * matches, so "save wifey as Sara" still resolves to "Sara Smith" if she's
 * in contacts.
 */
class ContactAliasTool(
    private val context: Context,
    private val aliasStore: ContactAliasStore,
    private val contactLookup: ContactLookup,
) : Tool {

    override val name            = "contact_alias"
    override val description     = "Teach Jarvis a contact nickname or remove one"
    override val requiresNetwork = false
    override val isLocalFallback = true
    override val requiredPermissions: List<String> = emptyList()

    companion object {
        private const val TAG = "ContactAliasTool"

        // "save wifey as Sarah", "remember wifey as Sarah", "use wifey for Sarah Smith"
        private val SAVE_RE = Regex(
            """(?ix)
            ^\s*
            (?:save|remember|set|store|teach|use)
            \s+
            (?<alias>[a-z][a-z0-9'\-\s]{0,30}?)
            \s+
            (?:as|is|for|=|to\s+mean|to\s+be)
            \s+
            (?<target>[a-z][a-z0-9'\-\s\.]+?)
            \s*[.?!]?\s*$
            """,
        )

        // "<alias> is <target>" — quick teach form (only matches single-word alias)
        private val QUICK_SAVE_RE = Regex(
            """(?ix)
            ^\s*
            (?<alias>[a-z]+)
            \s+is\s+(?:my\s+)?
            (?<target>[a-z][a-z0-9'\-\s\.]+?)
            \s*[.?!]?\s*$
            """,
        )

        // "forget the alias wifey", "remove wifey alias", "delete the wifey nickname"
        private val FORGET_RE = Regex(
            """(?ix)
            (?:forget|remove|delete|clear)\s+
            (?:the\s+)?(?:alias|nickname)\s+(?<a1>[a-z][a-z0-9'\-\s]{0,30}?)
            |
            (?:forget|remove|delete|clear)\s+
            (?:the\s+)?(?<a2>[a-z][a-z0-9'\-\s]{0,30}?)\s+(?:alias|nickname)
            \s*[.?!]?\s*$
            """,
        )

        /**
         * Aliases / targets we never accept — purely defensive against the
         * QUICK_SAVE_RE pattern catching philosophical statements like
         * "happiness is contagious" or "love is patient".
         */
        private val BLACKLIST_TOKENS = setOf(
            "this", "that", "it", "everything", "nothing",
            "love", "life", "happiness", "trust", "memory",
            "home", "work", "good", "bad", "fine", "okay",
        )
    }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Manage contact aliases (e.g. 'wifey' → 'Sarah Smith').",
        parameters  = mapOf(
            "type" to "object",
            "properties" to mapOf(
                "action" to mapOf("type" to "string",
                    "enum" to listOf("SAVE", "FORGET")),
                "alias"  to mapOf("type" to "string"),
                "target" to mapOf("type" to "string"),
            ),
            "required" to listOf("action", "alias"),
        )
    )

    override fun matches(transcript: String): ToolInput? {
        val t = transcript.trim()

        SAVE_RE.find(t)?.let { m ->
            val alias  = m.groups["alias"]?.value?.trim().orEmpty().lowercase()
            val target = m.groups["target"]?.value?.trim().orEmpty()
            if (alias.isBlank() || target.isBlank()) return@let
            if (alias in BLACKLIST_TOKENS || target.lowercase() in BLACKLIST_TOKENS) return@let
            return ToolInput(t, mapOf("action" to "SAVE", "alias" to alias, "target" to target))
        }

        FORGET_RE.find(t)?.let { m ->
            val alias = (m.groups["a1"] ?: m.groups["a2"])?.value?.trim()?.lowercase().orEmpty()
            if (alias.isBlank() || alias in BLACKLIST_TOKENS) return@let
            if (aliasStore.resolve(alias) == null) return@let
            return ToolInput(t, mapOf("action" to "FORGET", "alias" to alias))
        }

        // QUICK_SAVE — only fire when alias hasn't been used elsewhere AND the
        // target genuinely resolves to a contact.  This is the most error-prone
        // path, so guard it hard: no aliasing common chat words.
        QUICK_SAVE_RE.find(t)?.let { m ->
            val alias  = m.groups["alias"]?.value?.trim().orEmpty().lowercase()
            val target = m.groups["target"]?.value?.trim().orEmpty()
            if (alias.isBlank() || target.isBlank()) return@let
            if (alias in BLACKLIST_TOKENS || target.lowercase() in BLACKLIST_TOKENS) return@let
            // Must be 1-2 word alias to keep false positives low.
            if (alias.split(Regex("\\s+")).size > 2) return@let
            // Target must resolve to a real contact.
            val resolved = contactLookup.find(target) ?: return@let
            return ToolInput(t, mapOf("action" to "SAVE", "alias" to alias,
                "target" to resolved.displayName))
        }

        return null
    }

    override suspend fun execute(input: ToolInput): ToolResult {
        val action = input.param("action")
        val alias  = input.param("alias")
        Log.d(TAG, "[CONTACT_ALIAS_ACTION] action=$action alias=\"$alias\"")

        return when (action) {
            "SAVE" -> {
                val target = input.param("target")
                val resolved = contactLookup.find(target)
                if (resolved == null) {
                    return ToolResult.Failure(
                        "I can't see $target in your contacts. Save them first, then I can alias."
                    )
                }
                aliasStore.save(alias, resolved.displayName)
                ToolResult.Success("Got it — $alias is ${resolved.displayName}.")
            }
            "FORGET" -> {
                aliasStore.remove(alias)
                ToolResult.Success("Forgot the $alias alias.")
            }
            else -> ToolResult.Failure("Unknown alias action.")
        }
    }
}
