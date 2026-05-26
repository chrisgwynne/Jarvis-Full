package com.jarvis.assistant.remote.macbrain

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * BrainSyncRunnerTest — verifies gate logic, enqueue helpers, and sync dispatch
 * in [BrainSyncRunner].
 *
 * ## Design choices
 *
 * - [BrainSyncRunner] accepts lambda-based settings gates so tests pass `{ true }`
 *   or `{ false }` without constructing a real [com.jarvis.assistant.util.SettingsStore]
 *   (which requires Android EncryptedSharedPreferences).
 * - [FakeClient] is a local implementation of [MacBrainClient] that records calls and
 *   lets tests control the accepted ID list.
 * - [syncNow] is `internal` and called directly — no need to advance virtual time or
 *   deal with the 2-second debounce.
 * - [PendingBrainSyncStore] uses [Dispatchers.Unconfined] so disk I/O is synchronous.
 */
class BrainSyncRunnerTest {

    private lateinit var tmpDir: File
    private lateinit var queueFile: File
    private val writeScope = CoroutineScope(Dispatchers.Unconfined)
    private val testScope  = CoroutineScope(Dispatchers.Unconfined)

    @Before
    fun setUp() {
        tmpDir    = Files.createTempDirectory("brain_runner_test").toFile()
        queueFile = File(tmpDir, "pending_sync.json")
    }

    @After
    fun tearDown() {
        tmpDir.deleteRecursively()
    }

    // ── Fake client ───────────────────────────────────────────────────────────

    private class FakeClient(
        /** When non-null, only these IDs are returned as accepted (simulates partial success). */
        private val acceptOnly: Set<String>? = null,
        /** When true, reportEvents throws to simulate a total network failure. */
        private val throws: Boolean = false,
    ) : MacBrainClient {
        val reportedBatches = mutableListOf<List<AndroidInteractionEvent>>()

        override suspend fun fetchContext(request: BrainContextRequest): BrainContextResponse? = null
        override suspend fun health(): Boolean = true

        override suspend fun reportEvents(events: List<AndroidInteractionEvent>): List<String> {
            if (throws) throw RuntimeException("network failure")
            reportedBatches.add(events.toList())
            return acceptOnly?.let { ids -> events.map { it.id }.filter { it in ids } }
                ?: events.map { it.id }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun store() = PendingBrainSyncStore(
        queueFile    = queueFile,
        writeScope   = writeScope,
        ioDispatcher = Dispatchers.Unconfined,
    )

    private fun runner(
        store:         PendingBrainSyncStore = store(),
        client:        MacBrainClient?       = FakeClient(),
        circuit:       BrainCircuitBreaker   = BrainCircuitBreaker(),
        enabled:       () -> Boolean         = { true },
        wifiOnly:      () -> Boolean         = { false },
        allowOutcomes: () -> Boolean         = { true },
        allowHa:       () -> Boolean         = { true },
        allowMemory:   () -> Boolean         = { true },
        isWifi:        () -> Boolean         = { true },
    ) = BrainSyncRunner(
        store          = store,
        circuit        = circuit,
        client         = client,
        scope          = testScope,
        enabled        = enabled,
        wifiOnly       = wifiOnly,
        allowOutcomes  = allowOutcomes,
        allowHa        = allowHa,
        allowMemory    = allowMemory,
        isWifiProvider = isWifi,
    )

    // ── 1. Wi-Fi only gate blocks sync ────────────────────────────────────────

    @Test
    fun `syncNow skips when wifi-only is set and device is not on wifi`() = runBlocking {
        val s = store()
        // Pre-populate a queued event so there's something to sync
        s.enqueue(AndroidInteractionEvent(
            deviceId             = "dev",
            transcript           = "test",
            normalizedTranscript = "test",
            intent               = "command",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        ))

        val client = FakeClient()
        runner(
            store    = s,
            client   = client,
            wifiOnly = { true },
            isWifi   = { false },
        ).syncNow()

        assertEquals("reportEvents must not be called when wifi-only blocks sync",
            0, client.reportedBatches.size)
        assertEquals("item must remain in queue", 1, s.size())
    }

    @Test
    fun `syncNow proceeds when wifi-only is set and device is on wifi`() = runBlocking {
        val s = store()
        s.enqueue(AndroidInteractionEvent(
            deviceId             = "dev",
            transcript           = "test",
            normalizedTranscript = "test",
            intent               = "command",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        ))

        val client = FakeClient()
        runner(
            store    = s,
            client   = client,
            wifiOnly = { true },
            isWifi   = { true },
        ).syncNow()

        assertEquals(1, client.reportedBatches.size)
        assertEquals(0, s.size())
    }

    // ── 2. Disabled Brain blocks sync ─────────────────────────────────────────

    @Test
    fun `syncNow skips entirely when Brain is disabled`() = runBlocking {
        val s = store()
        s.enqueue(AndroidInteractionEvent(
            deviceId             = "dev",
            transcript           = "test",
            normalizedTranscript = "test",
            intent               = "command",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        ))

        val client = FakeClient()
        runner(store = s, client = client, enabled = { false }).syncNow()

        assertEquals("must not send when Brain is disabled", 0, client.reportedBatches.size)
        assertEquals("item must remain in queue", 1, s.size())
    }

    // ── 3. Command outcome event is queued ────────────────────────────────────

    @Test
    fun `enqueueCommandOutcome adds event to store`() {
        val s = store()
        runner(store = s).enqueueCommandOutcome(
            deviceId   = "dev",
            transcript = "turn on the lights",
            toolName   = "smart_home",
            success    = true,
        )
        assertEquals(1, s.size())
        val queued = s.peek().single()
        assertEquals(AndroidInteractionEvent.EventType.COMMAND_OUTCOME, queued.event.eventType)
        assertEquals("smart_home", queued.event.actionTaken)
        assertTrue(queued.event.success)
    }

    @Test
    fun `enqueueCommandOutcome is no-op when outcome reporting is disabled`() {
        val s = store()
        runner(store = s, allowOutcomes = { false }).enqueueCommandOutcome(
            deviceId   = "dev",
            transcript = "do something",
            toolName   = "tool",
            success    = true,
        )
        assertEquals(0, s.size())
    }

    // ── 4. HA correction event is queued (with name mismatch) ─────────────────

    @Test
    fun `enqueueHaCorrection adds event when entity names differ`() {
        val s = store()
        runner(store = s).enqueueHaCorrection(
            deviceId      = "dev",
            transcript    = "turn on living room",
            entitySaid    = "living room",
            entityMatched = "Living Room Light",
            entityId      = "light.living_room",
            success       = true,
        )
        assertEquals(1, s.size())
        val queued = s.peek().single()
        assertEquals(AndroidInteractionEvent.EventType.HOME_ASSISTANT_CORRECTION, queued.event.eventType)
    }

    @Test
    fun `enqueueHaCorrection is no-op when entity names match exactly`() {
        val s = store()
        runner(store = s).enqueueHaCorrection(
            deviceId      = "dev",
            transcript    = "turn on kitchen light",
            entitySaid    = "kitchen light",
            entityMatched = "kitchen light",   // exact match
            entityId      = "light.kitchen",
            success       = true,
        )
        assertEquals(0, s.size())
    }

    // ── 5. Memory candidate event is queued ───────────────────────────────────

    @Test
    fun `enqueueMemoryCandidate adds event to store`() {
        val s = store()
        runner(store = s).enqueueMemoryCandidate(
            deviceId   = "dev",
            transcript = "remember that I prefer dark mode",
        )
        assertEquals(1, s.size())
        val queued = s.peek().single()
        assertEquals(AndroidInteractionEvent.EventType.MEMORY_CANDIDATE, queued.event.eventType)
        assertEquals("memory", queued.event.intent)
    }

    @Test
    fun `enqueueMemoryCandidate is no-op when memory reporting is disabled`() {
        val s = store()
        runner(store = s, allowMemory = { false }).enqueueMemoryCandidate(
            deviceId   = "dev",
            transcript = "remember that I like jazz",
        )
        assertEquals(0, s.size())
    }

    // ── 6. Successful sync removes items from queue ───────────────────────────

    @Test
    fun `syncNow removes accepted events from store`() = runBlocking {
        val s = store()
        val e1 = AndroidInteractionEvent(
            deviceId             = "dev",
            transcript           = "lights on",
            normalizedTranscript = "lights on",
            intent               = "command",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        )
        val e2 = AndroidInteractionEvent(
            deviceId             = "dev",
            transcript           = "lights off",
            normalizedTranscript = "lights off",
            intent               = "command",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        )
        s.enqueue(e1)
        s.enqueue(e2)
        assertEquals(2, s.size())

        runner(store = s, client = FakeClient()).syncNow()

        assertEquals("all accepted events must be removed", 0, s.size())
    }

    // ── 7. Failed sync keeps items in queue ───────────────────────────────────

    @Test
    fun `syncNow keeps items in queue when reportEvents throws`() = runBlocking {
        val s = store()
        s.enqueue(AndroidInteractionEvent(
            deviceId             = "dev",
            transcript           = "test",
            normalizedTranscript = "test",
            intent               = "command",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        ))

        runner(store = s, client = FakeClient(throws = true)).syncNow()

        assertEquals("item must remain after sync failure", 1, s.size())
        assertEquals("failedCount must be 1 after one failure", 1, s.failedCount())
    }

    @Test
    fun `syncNow keeps un-accepted items in queue on partial success`() = runBlocking {
        val s = store()
        val e1 = AndroidInteractionEvent(
            id                   = "id-1",
            deviceId             = "dev",
            transcript           = "lights on",
            normalizedTranscript = "lights on",
            intent               = "command",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        )
        val e2 = AndroidInteractionEvent(
            id                   = "id-2",
            deviceId             = "dev",
            transcript           = "alarm off",
            normalizedTranscript = "alarm off",
            intent               = "command",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        )
        s.enqueue(e1)
        s.enqueue(e2)

        // Server accepts only e1
        runner(store = s, client = FakeClient(acceptOnly = setOf("id-1"))).syncNow()

        // e2 must still be in the store (in backoff after markFailed)
        assertEquals("only e2 must remain in store", 1, s.size())
        assertEquals("e2 must be counted as failed (retryCount > 0)", 1, s.failedCount())
        // e2 is in backoff so peek() (nextRetryAt ≤ now) won't return it yet — this is expected
    }

    // ── Circuit-open gate ─────────────────────────────────────────────────────

    @Test
    fun `syncNow skips when circuit breaker is open`() = runBlocking {
        val s = store()
        s.enqueue(AndroidInteractionEvent(
            deviceId             = "dev",
            transcript           = "test",
            normalizedTranscript = "test",
            intent               = "command",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        ))

        // Threshold of 1 so a single recordFailure trips it
        val trippedCircuit = BrainCircuitBreaker(failureThreshold = 1)
        trippedCircuit.recordFailure()

        val client = FakeClient()
        runner(store = s, client = client, circuit = trippedCircuit).syncNow()

        assertEquals("must not send when circuit is open", 0, client.reportedBatches.size)
        assertEquals("item must remain in queue", 1, s.size())
    }

    // ── Permission gates remove non-reportable events ─────────────────────────

    @Test
    fun `syncNow removes HA events from queue when HA reporting is disabled`() = runBlocking {
        val s = store()
        // Enqueue an HA event while allowHa was true (simulating a queued item from before toggle)
        s.enqueue(AndroidInteractionEvent(
            deviceId             = "dev",
            transcript           = "turn on lights",
            normalizedTranscript = "turn on lights",
            intent               = "smart_home",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.HOME_ASSISTANT_CORRECTION,
        ))

        // Now HA reporting is disabled — the item should be dropped rather than retried forever
        val client = FakeClient()
        runner(store = s, client = client, allowHa = { false }).syncNow()

        assertEquals("HA event must be removed when HA reporting disabled", 0, s.size())
        assertEquals("client must not be called for gated items", 0, client.reportedBatches.size)
    }

    @Test
    fun `syncNow removes memory events from queue when memory reporting is disabled`() = runBlocking {
        val s = store()
        s.enqueue(AndroidInteractionEvent(
            deviceId             = "dev",
            transcript           = "remember that I prefer dark mode",
            normalizedTranscript = "remember that i prefer dark mode",
            intent               = "memory",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.MEMORY_CANDIDATE,
        ))

        val client = FakeClient()
        runner(store = s, client = client, allowMemory = { false }).syncNow()

        assertEquals("memory event must be removed when memory reporting disabled", 0, s.size())
    }

    // ── enqueueHaCorrection exact-match guard ─────────────────────────────────

    @Test
    fun `enqueueHaCorrection skips exact case-insensitive match`() {
        val s = store()
        runner(store = s).enqueueHaCorrection(
            deviceId      = "dev",
            transcript    = "turn on Kitchen Light",
            entitySaid    = "Kitchen Light",
            entityMatched = "kitchen light",   // same when trimmed+lowercased
            entityId      = "light.kitchen",
            success       = true,
        )
        assertEquals("case-insensitive exact match must not be queued", 0, s.size())
    }

    // ── Null client ───────────────────────────────────────────────────────────

    @Test
    fun `syncNow is a no-op when client is null`() = runBlocking {
        val s = store()
        s.enqueue(AndroidInteractionEvent(
            deviceId             = "dev",
            transcript           = "test",
            normalizedTranscript = "test",
            intent               = "command",
            success              = true,
            eventType            = AndroidInteractionEvent.EventType.COMMAND_OUTCOME,
        ))

        runner(store = s, client = null).syncNow()

        // Item stays — null client is not a failure, just a skip
        assertEquals("item must stay when client is null", 1, s.size())
    }
}
