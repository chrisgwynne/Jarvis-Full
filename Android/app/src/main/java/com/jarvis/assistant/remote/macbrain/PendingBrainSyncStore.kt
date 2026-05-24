package com.jarvis.assistant.remote.macbrain

import android.util.Log
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Retry metadata wrapper for a queued [AndroidInteractionEvent].
 */
internal data class QueuedEvent(
    val event: AndroidInteractionEvent,
    val retryCount: Int = 0,
    val lastErrorAt: Long = 0L,
    val lastError: String = "",
    /** Epoch-ms after which this item is eligible for the next retry attempt. 0 = immediately. */
    val nextRetryAt: Long = 0L,
)

/**
 * PendingBrainSyncStore — persistent, bounded FIFO queue for [AndroidInteractionEvent]s
 * waiting to be reported to Mac Brain.
 *
 * DESIGN
 *   • In-memory [MutableList] for fast reads; flushed to a JSON file on every mutation.
 *   • Atomic writes via `.tmp` → rename to avoid partial-write corruption.
 *   • Capacity: [MAX_SIZE] entries. When full, the lowest-priority entry is evicted
 *     rather than the new one (unless the new one has equal-or-lower priority).
 *   • Exponential backoff: 30 s × 2^retryCount, capped at 24 h.
 *   • Items are permanently dropped after [MAX_RETRIES] failed attempts.
 *   • All queue mutations are @Synchronized; disk I/O runs on [ioDispatcher].
 *
 * TESTING
 *   Inject [ioDispatcher] = [Dispatchers.Unconfined] for synchronous writes that
 *   are immediately observable in the same test coroutine.
 */
class PendingBrainSyncStore(
    private val queueFile:    File,
    private val writeScope:   CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    companion object {
        private const val TAG          = "BrainSyncStore"
        const val MAX_SIZE             = 250
        private const val MAX_RETRIES  = 10
        private const val BASE_BACKOFF = 30_000L          // 30 s
        private const val MAX_BACKOFF  = 24 * 3_600_000L  // 24 h
    }

    private val queue = mutableListOf<QueuedEvent>()

    init {
        loadFromDisk()
    }

    // ── Public API ─────────────────────────────────────────────────────────────

    /**
     * Add [event] to the queue.
     *
     * When the queue is at [MAX_SIZE], the item with the lowest [AndroidInteractionEvent.priority]
     * is evicted to make room — unless the new item has equal-or-lower priority, in which
     * case the new item is silently dropped.
     */
    @Synchronized fun enqueue(event: AndroidInteractionEvent) {
        if (queue.size >= MAX_SIZE) {
            val victim = queue.minByOrNull { it.event.priority() }
            if (victim == null || victim.event.priority() >= event.priority()) {
                Log.d(TAG, "[BRAIN_SYNC_EVICT] dropped inbound type=${event.eventType} (queue full, lower priority)")
                return
            }
            queue.remove(victim)
            Log.d(TAG, "[BRAIN_SYNC_EVICT] removed id=${victim.event.id} type=${victim.event.eventType}")
        }
        queue.add(QueuedEvent(event))
        Log.d(TAG, "[BRAIN_SYNC_ENQUEUE] id=${event.id} type=${event.eventType} size=${queue.size}")
        persistAsync()
    }

    /**
     * Returns up to [limit] events that are due for a sync attempt
     * ([QueuedEvent.nextRetryAt] ≤ now).
     */
    @Synchronized internal fun peek(limit: Int = 20): List<QueuedEvent> {
        val now = System.currentTimeMillis()
        return queue.filter { it.nextRetryAt <= now }.take(limit)
    }

    /** Remove successfully synced events by ID. */
    @Synchronized fun remove(ids: Set<String>) {
        if (ids.isEmpty()) return
        val before = queue.size
        queue.removeAll { it.event.id in ids }
        val removed = before - queue.size
        if (removed > 0) {
            Log.d(TAG, "[BRAIN_SYNC_REMOVE] count=$removed remaining=${queue.size}")
            persistAsync()
        }
    }

    /**
     * Record a sync failure for [id]. Applies exponential backoff.
     * Permanently drops the item after [MAX_RETRIES] attempts.
     */
    @Synchronized fun markFailed(id: String, error: String) {
        val idx = queue.indexOfFirst { it.event.id == id }
        if (idx < 0) return
        val item     = queue[idx]
        val nextRetry = item.retryCount + 1
        if (nextRetry > MAX_RETRIES) {
            queue.removeAt(idx)
            Log.d(TAG, "[BRAIN_SYNC_DROP] id=$id exhausted after $MAX_RETRIES retries")
        } else {
            val backoffMs = minOf(BASE_BACKOFF shl nextRetry.coerceAtMost(20), MAX_BACKOFF)
            queue[idx] = item.copy(
                retryCount  = nextRetry,
                lastError   = error.take(200),
                lastErrorAt = System.currentTimeMillis(),
                nextRetryAt = System.currentTimeMillis() + backoffMs,
            )
            Log.d(TAG, "[BRAIN_SYNC_BACKOFF] id=$id retry=$nextRetry backoff=${backoffMs / 1000}s")
        }
        persistAsync()
    }

    @Synchronized fun size(): Int = queue.size

    /** Epoch-ms of the oldest event in the queue, or 0 if empty. */
    @Synchronized fun oldestQueuedAt(): Long =
        queue.minOfOrNull { it.event.timestamp } ?: 0L

    /** Count of events that have had at least one failed sync attempt. */
    @Synchronized fun failedCount(): Int = queue.count { it.retryCount > 0 }

    // ── Disk I/O ───────────────────────────────────────────────────────────────

    @Synchronized private fun loadFromDisk() {
        if (!queueFile.exists()) return
        try {
            val arr = JSONArray(queueFile.readText(Charsets.UTF_8))
            for (i in 0 until arr.length()) {
                deserializeQueued(arr.getJSONObject(i))?.let { queue.add(it) }
            }
            Log.d(TAG, "[BRAIN_SYNC_LOAD] loaded=${queue.size}")
        } catch (e: Exception) {
            Log.w(TAG, "[BRAIN_SYNC_LOAD_FAILED] ${e.message?.take(80)}")
        }
    }

    /** Snapshot the queue and flush it to disk asynchronously. */
    private fun persistAsync() {
        val snapshot = synchronized(this) { ArrayList(queue) }
        writeScope.launch(ioDispatcher) {
            try {
                val arr = JSONArray()
                snapshot.forEach { arr.put(serializeQueued(it)) }
                val tmp = File(queueFile.parentFile ?: queueFile.absoluteFile.parentFile, "${queueFile.name}.tmp")
                tmp.writeText(arr.toString(), Charsets.UTF_8)
                if (!tmp.renameTo(queueFile)) {
                    // renameTo can fail cross-device; fall back to direct write
                    queueFile.writeText(arr.toString(), Charsets.UTF_8)
                    tmp.delete()
                }
            } catch (e: Exception) {
                Log.w(TAG, "[BRAIN_SYNC_SAVE_FAILED] ${e.message?.take(80)}")
            }
        }
    }

    // ── Serialisation ──────────────────────────────────────────────────────────

    private fun serializeQueued(q: QueuedEvent): JSONObject = JSONObject().apply {
        put("retryCount",  q.retryCount)
        put("lastErrorAt", q.lastErrorAt)
        put("lastError",   q.lastError)
        put("nextRetryAt", q.nextRetryAt)
        put("event",       serializeEvent(q.event))
    }

    private fun serializeEvent(e: AndroidInteractionEvent): JSONObject = JSONObject().apply {
        put("id",                   e.id)
        put("timestamp",            e.timestamp)
        put("deviceId",             e.deviceId)
        put("transcript",           e.transcript)
        put("normalizedTranscript", e.normalizedTranscript)
        put("intent",               e.intent)
        put("actionTaken",          e.actionTaken)
        put("success",              e.success)
        put("confidence",           e.confidence.toDouble())
        put("shouldStore",          e.shouldStore)
        put("eventType",            e.eventType.name)
        e.correction?.let { put("correction", it) }
        e.error?.let      { put("error",      it) }
        e.appContext?.let  { put("appContext", it) }
        if (e.entities.isNotEmpty()) {
            val ents = JSONObject()
            e.entities.forEach { (k, v) -> ents.put(k, v) }
            put("entities", ents)
        }
    }

    private fun deserializeQueued(obj: JSONObject): QueuedEvent? = try {
        val event = deserializeEvent(obj.getJSONObject("event")) ?: return null
        QueuedEvent(
            event       = event,
            retryCount  = obj.optInt("retryCount", 0),
            lastErrorAt = obj.optLong("lastErrorAt", 0L),
            lastError   = obj.optString("lastError", ""),
            nextRetryAt = obj.optLong("nextRetryAt", 0L),
        )
    } catch (_: Exception) { null }

    private fun deserializeEvent(obj: JSONObject): AndroidInteractionEvent? = try {
        val entities = mutableMapOf<String, String>()
        obj.optJSONObject("entities")?.let { ents ->
            ents.keys().forEach { k -> entities[k] = ents.optString(k) }
        }
        AndroidInteractionEvent(
            id                   = obj.getString("id"),
            timestamp            = obj.getLong("timestamp"),
            deviceId             = obj.getString("deviceId"),
            transcript           = obj.getString("transcript"),
            normalizedTranscript = obj.getString("normalizedTranscript"),
            intent               = obj.getString("intent"),
            entities             = entities,
            actionTaken          = obj.optString("actionTaken", ""),
            success              = obj.getBoolean("success"),
            confidence           = obj.optDouble("confidence", 1.0).toFloat(),
            correction           = obj.optString("correction").takeIf { it.isNotBlank() },
            error                = obj.optString("error").takeIf { it.isNotBlank() },
            appContext            = obj.optString("appContext").takeIf { it.isNotBlank() },
            shouldStore          = obj.optBoolean("shouldStore", true),
            eventType            = AndroidInteractionEvent.EventType.valueOf(obj.getString("eventType")),
        )
    } catch (_: Exception) { null }
}
