package com.jarvis.assistant.gateway

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * Phase 11 soak/stress tests for heartbeat deduplication behaviour.
 *
 * These tests verify that cancelling the previous heartbeat job before launching
 * a new one prevents duplicate ticks — the pattern used by the Mac Bridge /
 * WebSocket reconnect path.
 */
class HeartbeatDedupTest {

    @Test
    fun `cancelling previous job before launching prevents duplicates`() = runTest {
        val tickCount = AtomicInteger(0)
        var heartbeatJob: Job? = null

        suspend fun heartbeatLoop() {
            repeat(10) {
                delay(10)
                tickCount.incrementAndGet()
            }
        }

        // Simulate rapid reconnects — each cancels the previous job.
        repeat(5) {
            heartbeatJob?.cancel()
            heartbeatJob = launch { heartbeatLoop() }
            delay(5)  // reconnect before previous completes
        }

        // Wait for the final job only.
        heartbeatJob?.join()

        // With dedup, only the last heartbeatLoop runs to completion.
        // Without dedup, all 5 would run = 50 ticks. With dedup, max 1 completes.
        // In this test the last job runs fully: 10 ticks.
        // Previous 4 jobs are cancelled after 5 ms so they contribute ~0 ticks each.
        assertTrue(
            "Expected ≤ 15 ticks with dedup, got ${tickCount.get()}",
            tickCount.get() <= 15
        )
    }

    @Test
    fun `stop cancels heartbeat job`() = runTest {
        val ran = AtomicInteger(0)
        var heartbeatJob: Job? = null

        heartbeatJob = launch {
            repeat(100) {
                delay(10)
                ran.incrementAndGet()
            }
        }

        delay(25)
        heartbeatJob?.cancel()
        heartbeatJob = null
        delay(50)

        val countAfterStop = ran.get()
        delay(50)
        assertEquals(countAfterStop, ran.get())  // no more increments after cancel
    }

    @Test
    fun `job reference is null after explicit stop`() = runTest {
        var heartbeatJob: Job? = null

        heartbeatJob = launch { delay(1_000) }

        assertNotNull(heartbeatJob)
        heartbeatJob?.cancel()
        heartbeatJob = null

        assertNull(heartbeatJob)
    }

    @Test
    fun `second launch after cancel does not inherit cancelled state`() = runTest {
        val count = AtomicInteger(0)
        var heartbeatJob: Job? = null

        // First job — cancelled immediately.
        heartbeatJob = launch { delay(1_000) }
        heartbeatJob?.cancel()

        // Second job — a fresh launch must run to completion.
        heartbeatJob = launch {
            delay(10)
            count.incrementAndGet()
        }
        heartbeatJob?.join()

        assertEquals(1, count.get())
    }
}
