package com.jarvis.assistant.tools.device.messaging

/**
 * Holds a single parked reply target across two turns.
 *
 * Flow:
 *   Turn 1: user says "reply to Mike" → tool parks (targetName="Mike", entryKey=sbnKey)
 *            and asks "What do you want to say to Mike?"
 *   Turn 2: user says "On my way" → [ReplyNotificationTool.matches] claims it as the body
 *            and includes [entryKey] so execute() can look up the entry directly.
 *
 * TTL is 60 s — long enough for the user to think, short enough not to stale.
 */
object PendingReplyStore {

    private const val TTL_MS = 60_000L

    private val lock = Any()
    private var pending: PendingReply? = null

    data class PendingReply(
        val targetName:  String,
        val entryKey:    String?,
        val expiresAtMs: Long,
    )

    fun park(targetName: String, entryKey: String?, nowMs: Long = System.currentTimeMillis()) {
        synchronized(lock) {
            pending = PendingReply(
                targetName  = targetName,
                entryKey    = entryKey,
                expiresAtMs = nowMs + TTL_MS,
            )
        }
    }

    fun get(nowMs: Long = System.currentTimeMillis()): PendingReply? = synchronized(lock) {
        val p = pending ?: return null
        if (nowMs >= p.expiresAtMs) { pending = null; return null }
        p
    }

    fun hasPending(nowMs: Long = System.currentTimeMillis()): Boolean = get(nowMs) != null

    fun clear() { synchronized(lock) { pending = null } }
}
