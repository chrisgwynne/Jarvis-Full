package com.jarvis.assistant.phrases

import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * PhraseStore — persistence contract for user-overridden phrase variants.
 *
 * All suspend functions run on the caller's coroutine context; implementations
 * must dispatch to an appropriate dispatcher (e.g. Dispatchers.IO for Room).
 */
interface PhraseStore {
    suspend fun getOverride(key: String): List<PhraseVariant>
    suspend fun getAllOverrides(): Map<String, List<PhraseVariant>>
    suspend fun saveVariant(key: String, variant: PhraseVariant)
    suspend fun deleteVariant(key: String, variantId: String)
    suspend fun resetKey(key: String)
    suspend fun exportJson(): String
    suspend fun importJson(json: String): PhraseStore.ImportResult

    data class ImportResult(
        val imported: Int,
        val failed: Int,
        val errors: List<String>,
    )
}

/**
 * PhraseResolver — resolves a phrase key + variable map to a final string.
 *
 * Resolution order:
 *  1. In-memory cache of user overrides for the key.
 *  2. If enabled variants exist in the cache → pick a random enabled variant.
 *  3. Fall back to PhraseRegistry.defaults[key]?.defaultText.
 *  4. Apply variable substitution via [applyVars].
 *  5. Unknown key → log warning, return "".
 *  6. Unresolved {var} tokens → replace with "", log diagnostic warning.
 *
 * Thread safety: the cache is a [ConcurrentHashMap]; [resolve] and
 * [resolveOrNull] are safe to call from any thread without suspension.
 * [refreshCache] must be called from a coroutine scope.
 */
class PhraseResolver(
    private val registry: PhraseRegistry = PhraseRegistry,
    private val store: PhraseStore,
) {

    private val cache = ConcurrentHashMap<String, List<PhraseVariant>>()

    // ── Public API ────────────────────────────────────────────────────────────

    /**
     * Resolve [key] with optional [vars], returning the final spoken string.
     * Returns "" if the key is unknown or the resolved text is empty.
     * Never throws.
     */
    fun resolve(key: String, vars: Map<String, String> = emptyMap()): String =
        resolveOrNull(key, vars) ?: run {
            Log.w(TAG, "resolve: unknown key '$key' — returning empty string")
            ""
        }

    /**
     * Same as [resolve] but returns null when the key has no registered default
     * AND no cached override.
     */
    fun resolveOrNull(key: String, vars: Map<String, String> = emptyMap()): String? {
        val template = pickTemplate(key) ?: return null
        if (template.isEmpty()) return ""
        val warnings = validateTemplate(template, vars)
        if (warnings.isNotEmpty()) {
            warnings.forEach { Log.d(TAG, "resolveOrNull: $it") }
        }
        return applyVars(template, vars)
    }

    /**
     * Re-populate the in-memory cache from the store.
     * Must be called from a coroutine (suspend).
     */
    suspend fun refreshCache() {
        val all = store.getAllOverrides()
        cache.clear()
        cache.putAll(all)
        Log.d(TAG, "refreshCache: loaded ${cache.size} override keys")
    }

    /**
     * Evict a single key from the cache (e.g. after a write).
     * Safe to call from any thread.
     */
    fun invalidateCache(key: String) {
        cache.remove(key)
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    private fun pickTemplate(key: String): String? {
        // 1 & 2: user overrides in cache
        val userVariants = cache[key]
        if (userVariants != null) {
            val enabled = userVariants.filter { it.isEnabled }
            if (enabled.isNotEmpty()) {
                return enabled.random().text
            }
        }
        // 3: default from registry
        return registry.defaults[key]?.defaultText
    }

    // ── Companion ─────────────────────────────────────────────────────────────

    companion object {
        private const val TAG = "PhraseResolver"

        /**
         * Replace all `{key}` tokens in [template] with corresponding values from [vars].
         * Any token not present in [vars] is replaced with an empty string.
         */
        fun applyVars(template: String, vars: Map<String, String>): String {
            var result = template
            vars.forEach { (k, v) -> result = result.replace("{$k}", v) }
            // Replace any remaining {token} placeholders with ""
            result = result.replace(Regex("\\{[^}]+}"), "")
            return result.trim()
        }

        /**
         * Returns a list of diagnostic warning strings for any `{var}` tokens in
         * [template] that are NOT covered by [vars].  Returns an empty list when all
         * tokens are satisfied.
         */
        fun validateTemplate(template: String, vars: Map<String, String>): List<String> {
            val tokens = Regex("\\{([^}]+)}").findAll(template).map { it.groupValues[1] }.toList()
            return tokens
                .filter { token -> !vars.containsKey(token) }
                .map { token -> "template token '{$token}' has no value in vars map — will be blanked" }
        }
    }
}
