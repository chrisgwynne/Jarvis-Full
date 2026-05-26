package com.jarvis.assistant.tools

import android.content.Context
import android.content.SharedPreferences
import android.util.Log

/**
 * ContactAliasStore — user-defined nicknames that resolve to a real contact
 * display name in the address book.  Example: "wifey" → "Sarah Smith".
 *
 * Used by [ContactLookup.find] BEFORE any fuzzy / LIKE search so the alias
 * always wins.  Aliases are case-folded and stored lowercase.
 *
 * Pure SharedPreferences — no Room, no migrations.  Suitable for the tens
 * to low-hundreds of aliases a single user accumulates.
 */
class ContactAliasStore(context: Context) {

    companion object {
        private const val TAG        = "ContactAliasStore"
        private const val PREFS_NAME = "jarvis_contact_aliases"
        private const val KEY_PREFIX = "alias_"
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** Save (or overwrite) [alias] → [contactDisplayName]. */
    fun save(alias: String, contactDisplayName: String) {
        if (com.jarvis.assistant.runtime.GuestMode.isActive) {
            Log.d(TAG, "[CONTACT_ALIAS_GUEST_SKIP] alias=\"$alias\"")
            return
        }
        val key = KEY_PREFIX + alias.lowercase().trim()
        prefs.edit().putString(key, contactDisplayName.trim()).apply()
        Log.d(TAG, "[CONTACT_ALIAS_SAVED] alias=\"$alias\" → \"$contactDisplayName\"")
    }

    /** Returns the real display name [alias] maps to, or null if no alias is set. */
    fun resolve(alias: String): String? {
        val key = KEY_PREFIX + alias.lowercase().trim()
        return prefs.getString(key, null)
    }

    /** Remove an alias.  No-op if not present. */
    fun remove(alias: String) {
        val key = KEY_PREFIX + alias.lowercase().trim()
        prefs.edit().remove(key).apply()
        Log.d(TAG, "[CONTACT_ALIAS_REMOVED] alias=\"$alias\"")
    }

    /** Every alias → target pair, sorted by alias. */
    fun all(): List<Pair<String, String>> =
        prefs.all
            .filterKeys { it.startsWith(KEY_PREFIX) }
            .map { it.key.removePrefix(KEY_PREFIX) to (it.value?.toString() ?: "") }
            .sortedBy { it.first }
}
