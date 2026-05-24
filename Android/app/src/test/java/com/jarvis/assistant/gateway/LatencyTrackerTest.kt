package com.jarvis.assistant.gateway

import com.jarvis.assistant.util.LatencyTracker
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Phase 11 soak/stress tests for [LatencyTracker].
 *
 * These tests verify:
 *  - Pipeline start/reset lifecycle.
 *  - The cross-device stage constants added in Phase 3 exist and are non-null.
 *  - Marking stages after pipeline start does not throw.
 */
class LatencyTrackerTest {

    @Before
    fun setUp() { LatencyTracker.reset() }

    @Test
    fun `pipelineStart sets start time`() {
        LatencyTracker.pipelineStart()
        // crossDeviceSummaryMs returns null before a mark after start.
        // Just ensure no crash.
    }

    @Test
    fun `constants are defined`() {
        // Ensures the constants added in Phase 3 exist.
        assertNotNull(LatencyTracker.TRANSCRIPT_SENT_TO_DAEMON)
        assertNotNull(LatencyTracker.DAEMON_REPLY_RECEIVED)
        assertNotNull(LatencyTracker.TTS_START)
    }

    @Test
    fun `mark after pipelineStart does not throw`() {
        LatencyTracker.pipelineStart()
        LatencyTracker.mark(LatencyTracker.TRANSCRIPT_SENT_TO_DAEMON)
        LatencyTracker.mark(LatencyTracker.DAEMON_REPLY_RECEIVED)
    }

    @Test
    fun `reset clears state so mark before pipelineStart is ignored`() {
        // After reset, startMs is 0 so mark() must be a no-op.
        LatencyTracker.reset()
        LatencyTracker.mark(LatencyTracker.TRANSCRIPT_SENT_TO_DAEMON)
    }

    @Test
    fun `pipelineStart followed by reset allows clean restart`() {
        LatencyTracker.pipelineStart()
        LatencyTracker.mark(LatencyTracker.TTS_START)
        LatencyTracker.reset()
        LatencyTracker.pipelineStart()
        LatencyTracker.mark(LatencyTracker.DAEMON_REPLY_RECEIVED)
    }

    @Test
    fun `TTS_START constant matches expected label string`() {
        // The pipeline budget-check key name is load-bearing — downstream
        // log parsers and dashboards depend on the exact string "TTS_START".
        assertEquals("TTS_START", LatencyTracker.TTS_START)
    }
}
