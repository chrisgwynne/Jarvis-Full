package com.jarvis.assistant.federation

import android.util.Log
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

private const val TAG = "OutboundQueue"
private const val MAX_RETRY_COUNT = 3
private const val BASE_RETRY_DELAY_MS = 2_000L
private const val MAX_RETRY_DELAY_MS = 30_000L

/**
 * Coroutine-based, in-memory, bounded FIFO queue with per-message retry.
 *
 * Internally backed by [Channel.UNLIMITED] but a soft cap ([maxSize]) is
 * enforced on [enqueue]: once the queue reaches the cap the oldest item is
 * dropped and a warning is logged, keeping memory bounded.
 *
 * Retry policy: each message can fail up to [MAX_RETRY_COUNT] times.
 * Retry delay doubles per attempt (2 s → 4 s → 8 s, capped at 30 s).
 * After [MAX_RETRY_COUNT] failures the message is dropped and a warning logged.
 */
class OutboundQueue(private val maxSize: Int = 200) {

    data class QueueEntry(
        val message: FederationMessage,
        val retryCount: Int = 0,
        val nextRetryMs: Long = 0L,
    )

    private val channel = Channel<QueueEntry>(Channel.UNLIMITED)
    private val mutex = Mutex()
    private var _size = 0

    /** Current number of items waiting in the queue. */
    val size: Int get() = _size

    /**
     * Add [message] to the tail of the queue.
     * If the queue is already at [maxSize], the oldest item is silently
     * dropped and a warning is logged before the new item is added.
     */
    suspend fun enqueue(message: FederationMessage) {
        mutex.withLock {
            if (_size >= maxSize) {
                // Drop the oldest entry to make room
                val dropped = channel.tryReceive().getOrNull()
                if (dropped != null) {
                    _size--
                    Log.w(TAG, "Queue full ($maxSize) — dropped oldest message " +
                            "${dropped.message::class.simpleName} id=${dropped.message.messageId}")
                }
            }
            channel.send(QueueEntry(message))
            _size++
        }
    }

    /**
     * Attempt to drain the queue by calling [send] for each ready entry.
     *
     * [send] should return true on success, false on transient failure.
     *
     * - Successful entries are consumed.
     * - Failed entries are re-enqueued with an incremented retry count and
     *   an exponential back-off timestamp, unless they have exhausted
     *   [MAX_RETRY_COUNT] retries (in which case they are dropped).
     * - Entries whose [QueueEntry.nextRetryMs] has not yet elapsed are
     *   re-enqueued as-is (not retried this pass).
     *
     * Returns the number of messages successfully sent.
     */
    suspend fun flush(send: suspend (FederationMessage) -> Boolean): Int {
        val now = System.currentTimeMillis()
        var sent = 0

        // Drain everything currently in the channel into a local snapshot so we
        // don't loop forever on re-enqueued failures.
        val snapshot = mutableListOf<QueueEntry>()
        mutex.withLock {
            while (true) {
                val result = channel.tryReceive()
                val entry = result.getOrNull() ?: break
                snapshot.add(entry)
                _size--
            }
        }

        for (entry in snapshot) {
            if (entry.nextRetryMs > now) {
                // Not yet ready — put back without counting as attempted
                mutex.withLock {
                    channel.send(entry)
                    _size++
                }
                continue
            }

            val success = try {
                send(entry.message)
            } catch (e: Exception) {
                Log.e(TAG, "flush: send threw for ${entry.message::class.simpleName}", e)
                false
            }

            if (success) {
                sent++
                Log.d(TAG, "flush: sent ${entry.message::class.simpleName} id=${entry.message.messageId}")
            } else {
                val newRetryCount = entry.retryCount + 1
                if (newRetryCount > MAX_RETRY_COUNT) {
                    Log.w(TAG, "flush: dropped ${entry.message::class.simpleName} " +
                            "id=${entry.message.messageId} after $MAX_RETRY_COUNT retries")
                } else {
                    val delayMs = minOf(BASE_RETRY_DELAY_MS * (1L shl (newRetryCount - 1)), MAX_RETRY_DELAY_MS)
                    val retryEntry = entry.copy(
                        retryCount = newRetryCount,
                        nextRetryMs = now + delayMs,
                    )
                    mutex.withLock {
                        channel.send(retryEntry)
                        _size++
                    }
                    Log.d(TAG, "flush: re-queued ${entry.message::class.simpleName} " +
                            "id=${entry.message.messageId} attempt=$newRetryCount delay=${delayMs}ms")
                }
            }
        }

        return sent
    }

    /** Remove all pending entries from the queue. */
    suspend fun clear() {
        mutex.withLock {
            while (true) {
                channel.tryReceive().getOrNull() ?: break
            }
            _size = 0
        }
        Log.d(TAG, "clear: queue emptied")
    }
}
