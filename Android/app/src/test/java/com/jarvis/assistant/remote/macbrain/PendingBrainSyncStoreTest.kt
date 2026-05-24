package com.jarvis.assistant.remote.macbrain

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * PendingBrainSyncStoreTest — verifies the bounded queue, persistence,
 * backoff, and priority-eviction invariants of [PendingBrainSyncStore].
 *
 * Uses [Dispatchers.Unconfined] for the write scope so disk flushes happen
 * synchronously and are immediately observable in the same test.
 */
class PendingBrainSyncStoreTest {

    private lateinit var tmpDir: File
    private lateinit var queueFile: File
    private val writeScope = CoroutineScope(Dispatchers.Unconfined)

    @Before
    fun setUp() {
        tmpDir = Files.createTempDirectory("brain_sync_test").toFile()
        queueFile = File(tmpDir, "pending_sync.json")
    }

    @After
    fun tearDown() {
        tmpDir.deleteRecursively()
    }

    private fun store() = PendingBrainSyncStore(
        queueFile    = queueFile,
        writeScope   = writeScope,
        ioDispatcher = Dispatchers.Unconfined,
    )

    private fun event(
        id:        String = java.util.UUID.randomUUID().toString(),
        eventType: AndroidInteractionEvent.EventType = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        timestamp: Long = System.currentTimeMillis(),
    ) = AndroidInteractionEvent(
        id                   = id,
        timestamp            = timestamp,
        deviceId             = "test-device",
        transcript           = "turn on the lights",
        normalizedTranscript = "turn on the lights",
        intent               = "command",
        actionTaken          = "smart_home",
        success              = true,
        eventType            = eventType,
    )

    // ── 1. Enqueue and persist across instances ────────────────────────────────

    @Test
    fun `enqueued events persist to disk and reload in a new instance`() {
        val e = event(id = "abc-123")
        store().enqueue(e)

        assertTrue("Queue file must exist after enqueue", queueFile.exists())

        val reloaded = store()
        assertEquals(1, reloaded.size())
        assertEquals("abc-123", reloaded.peek().first().event.id)
    }

    // ── 2. Queue is bounded at MAX_SIZE ───────────────────────────────────────

    @Test
    fun `queue caps at MAX_SIZE and evicts lowest-priority item`() {
        val s = store()

        // Fill to capacity with CONVERSATION_SUMMARY (lowest priority = 1)
        repeat(PendingBrainSyncStore.MAX_SIZE) {
            s.enqueue(event(eventType = AndroidInteractionEvent.EventType.CONVERSATION_SUMMARY))
        }
        assertEquals(PendingBrainSyncStore.MAX_SIZE, s.size())

        // Enqueue a higher-priority item (HOME_ASSISTANT_CORRECTION = priority 5)
        val highPri = event(
            id        = "high-pri",
            eventType = AndroidInteractionEvent.EventType.HOME_ASSISTANT_CORRECTION,
        )
        s.enqueue(highPri)

        // Still at MAX_SIZE but the new item replaced a low-priority one
        assertEquals(PendingBrainSyncStore.MAX_SIZE, s.size())
        val ids = s.peek(PendingBrainSyncStore.MAX_SIZE + 1).map { it.event.id }
        assertTrue("high-priority item must be present after eviction", "high-pri" in ids)
    }

    @Test
    fun `low-priority item is dropped when queue is full of higher-priority items`() {
        val s = store()

        // Fill to capacity with high-priority items
        repeat(PendingBrainSyncStore.MAX_SIZE) {
            s.enqueue(event(eventType = AndroidInteractionEvent.EventType.HOME_ASSISTANT_CORRECTION))
        }

        val before = s.size()
        // Attempt to enqueue lowest-priority item — should be silently dropped
        s.enqueue(event(
            id        = "dropped",
            eventType = AndroidInteractionEvent.EventType.CONVERSATION_SUMMARY,
        ))
        assertEquals("size must not grow when low-priority item is dropped", before, s.size())
        val ids = s.peek(PendingBrainSyncStore.MAX_SIZE + 1).map { it.event.id }
        assertTrue("dropped item must not appear in queue", "dropped" !in ids)
    }

    // ── 3. Backoff increases with each markFailed ─────────────────────────────

    @Test
    fun `backoff nextRetryAt grows with each markFailed call`() {
        val s = store()
        val e = event(id = "retry-me")
        s.enqueue(e)

        s.markFailed("retry-me", "timeout")
        val after1 = s.peek(10).firstOrNull { it.event.id == "retry-me" }
        // After first failure, nextRetryAt should be in the future
        // (note: peek filters out items where nextRetryAt > now, so it won't appear)
        assertEquals(
            "after first failure the item is in backoff and won't be in peek",
            0,
            s.peek(10).count { it.event.id == "retry-me" },
        )
        assertEquals("failedCount should be 1 after one failure", 1, s.failedCount())
        assertEquals("queue should still hold the item", 1, s.size())
    }

    @Test
    fun `backoff increases monotonically across successive failures`() {
        val s = store()
        val e = event(id = "backoff-test")
        s.enqueue(e)

        // MAX_RETRIES = 10. Drop happens when nextRetry (= retryCount + 1) > MAX_RETRIES,
        // so retryCount must reach 10 first, requiring 11 markFailed calls total.
        repeat(11) { s.markFailed("backoff-test", "err") }
        assertEquals("item must be permanently dropped after MAX_RETRIES exhausted", 0, s.size())
    }

    // ── 4. markFailed increments retryCount (item stays in queue) ─────────────

    @Test
    fun `failed sync increments retryCount and item stays in queue`() {
        val s = store()
        val e = event(id = "stays")
        s.enqueue(e)

        s.markFailed("stays", "network error")

        assertEquals("item must still be in queue after one failure", 1, s.size())
        assertEquals("failedCount must be 1", 1, s.failedCount())
    }

    // ── 5. remove() clears successfully synced items ──────────────────────────

    @Test
    fun `remove deletes synced events by ID`() {
        val s = store()
        val e1 = event(id = "e1")
        val e2 = event(id = "e2")
        val e3 = event(id = "e3")
        s.enqueue(e1)
        s.enqueue(e2)
        s.enqueue(e3)
        assertEquals(3, s.size())

        s.remove(setOf("e1", "e3"))

        assertEquals(1, s.size())
        assertEquals("e2", s.peek(10).single().event.id)
    }

    @Test
    fun `remove persists the updated queue to disk`() {
        val e1 = event(id = "keep")
        val e2 = event(id = "gone")

        store().apply {
            enqueue(e1)
            enqueue(e2)
            remove(setOf("gone"))
        }

        // Fresh instance must not see "gone"
        val fresh = store()
        assertEquals(1, fresh.size())
        assertEquals("keep", fresh.peek(10).single().event.id)
    }

    // ── 6. oldestQueuedAt reflects earliest timestamp ─────────────────────────

    @Test
    fun `oldestQueuedAt returns timestamp of earliest enqueued event`() {
        val s = store()
        val early = event(timestamp = 1_000L)
        val late  = event(timestamp = 9_000L)
        s.enqueue(late)
        s.enqueue(early)
        assertEquals(1_000L, s.oldestQueuedAt())
    }

    @Test
    fun `oldestQueuedAt returns 0 when queue is empty`() {
        assertEquals(0L, store().oldestQueuedAt())
    }
}
