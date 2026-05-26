package com.jarvis.assistant.remote.macbrain

/**
 * BrainContextCache — TTL-bounded LRU cache for Brain context responses.
 *
 * Most repeated queries (e.g. "what are we working on?" asked twice in a session,
 * or a preference lookup that recurs across turns) become zero-latency local hits.
 *
 * DESIGN
 *   • Access-order LinkedHashMap gives LRU eviction for free.
 *   • Each entry carries its insertion timestamp; reads check TTL before returning.
 *   • [maxSize] and [ttlMs] are the only knobs — no separate expiry thread needed.
 *   • All public methods are @Synchronized so this is safe to call from Dispatchers.IO.
 */
class BrainContextCache(
    private val maxSize: Int  = 64,
    private val ttlMs:   Long = 5 * 60_000L,
) {
    private data class Entry(val response: BrainContextResponse, val insertedAt: Long)

    private val store = object : LinkedHashMap<String, Entry>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, Entry>): Boolean =
            size > maxSize
    }

    /** Returns the cached response for [key] if it exists and has not expired; null otherwise. */
    @Synchronized fun get(key: String): BrainContextResponse? {
        val entry = store[key] ?: return null
        if (System.currentTimeMillis() - entry.insertedAt > ttlMs) {
            store.remove(key)
            return null
        }
        return entry.response
    }

    /** Stores [response] under [key]. Evicts the eldest entry if [maxSize] is exceeded. */
    @Synchronized fun put(key: String, response: BrainContextResponse) {
        store[key] = Entry(response, System.currentTimeMillis())
    }

    /** Removes all cached entries. */
    @Synchronized fun clear() { store.clear() }

    /** Number of entries currently in the cache (including potentially stale ones). */
    val size: Int @Synchronized get() = store.size

    companion object {
        private val WHITESPACE = Regex("\\s+")

        /**
         * Deterministic cache key: intent-prefixed, whitespace-normalised, lowercase,
         * capped at 120 chars of transcript so tiny wording changes don't bust the cache.
         */
        fun cacheKey(transcript: String, intentHint: String): String =
            "$intentHint:${transcript.trim().lowercase().replace(WHITESPACE, " ").take(120)}"
    }
}
