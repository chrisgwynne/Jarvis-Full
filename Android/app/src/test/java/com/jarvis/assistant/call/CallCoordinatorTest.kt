package com.jarvis.assistant.call

import com.jarvis.assistant.audio.SpeechCapture
import com.jarvis.assistant.runtime.TtsCoordinator
import com.jarvis.assistant.core.state.JarvisState
import com.jarvis.assistant.core.state.JarvisStateMachine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.doSuspendableAnswer
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever

@OptIn(ExperimentalCoroutinesApi::class)
class CallCoordinatorTest {

    private val testDispatcher = StandardTestDispatcher()

    private lateinit var tts:           TtsCoordinator
    private lateinit var speechCapture: SpeechCapture
    private lateinit var machine:       JarvisStateMachine
    private lateinit var resolver:      CallResolver
    private lateinit var executor:      CallActionExecutor
    private lateinit var callEvents:    MutableSharedFlow<CallEvent>

    private val stateTransitions = mutableListOf<JarvisState>()

    private fun buildCoordinator(scope: CoroutineScope) = CallCoordinator(
        tts           = tts,
        speechCapture = speechCapture,
        machine       = machine,
        resolver      = resolver,
        executor      = executor,
        syncState     = { stateTransitions.add(it) },
        scope         = scope
    )

    private fun fakeCallInfo(number: String? = "+441234567890") = CallInfo(
        incomingNumber       = number,
        resolvedDisplayName  = number ?: "Unknown caller",
        isKnownContact       = false,
        canAnswer            = true,
        canDecline           = true,
        resolutionConfidence = ResolutionConfidence.NONE
    )

    private fun knownContact(displayName: String) = ResolvedContact(
        displayName = displayName,
        isKnown     = true,
        confidence  = ResolutionConfidence.HIGH
    )

    private fun unknownCaller() = ResolvedContact(
        displayName = "Unknown caller",
        isKnown     = false,
        confidence  = ResolutionConfidence.NONE
    )

    @Before fun setUp() {
        // Install the test dispatcher as Dispatchers.Main so any
        // `withContext(Dispatchers.Main)` inside production code dispatches
        // to the same TestScheduler the test drives via advanceUntilIdle.
        kotlinx.coroutines.Dispatchers.setMain(testDispatcher)

        tts           = mock()
        speechCapture = mock()
        machine       = JarvisStateMachine()
        resolver      = mock()
        executor      = mock()
        callEvents    = MutableSharedFlow(replay = 0, extraBufferCapacity = 8)
        stateTransitions.clear()

        // Start state machine in a valid starting state
        machine.forceTransition(JarvisState.IdleWake)
    }

    @org.junit.After fun tearDown() {
        kotlinx.coroutines.Dispatchers.resetMain()
    }

    // ── Known contact call: user says "answer" ────────────────────────────────

    @Test
    fun `known contact call — answer command — transitions through full happy path`() = runTest(testDispatcher) {
        whenever(resolver.resolve(any())).thenReturn(knownContact("Chris"))
        whenever(speechCapture.listen()).thenReturn("answer")
        whenever(executor.answer()).thenReturn(CallActionResult.Success)

        val coordinator = buildCoordinator(this)
        val event = CallEvent.IncomingRinging(fakeCallInfo())

        // Launch coordinator and then emit call-ended so it can complete
        val job = launch {
            coordinator.handleIncomingCall(event, callEvents)
        }
        advanceUntilIdle()

        // After answer is called, the coordinator waits for call to end.
        // Emit CallEnded to unblock.
        callEvents.emit(CallEvent.CallEnded(fakeCallInfo().copy(callState = IncomingCallState.IDLE)))
        advanceUntilIdle()
        job.join()

        assertTrue(stateTransitions.contains(JarvisState.IncomingCallAlert))
        assertTrue(stateTransitions.contains(JarvisState.WaitingCallCommand))
        assertTrue(stateTransitions.contains(JarvisState.ExecutingCallAction))
        assertTrue(stateTransitions.contains(JarvisState.CallActive))
        assertTrue(stateTransitions.contains(JarvisState.CallRecovery))

        verify(tts).speak("Chris is calling.  Answer or decline?")
        verify(tts).speak("Answered.")
        verify(executor).answer()
    }

    // ── Unknown caller: user says "decline" ───────────────────────────────────

    @Test
    fun `unknown caller — decline command — speaks declined and recovers`() = runTest(testDispatcher) {
        whenever(resolver.resolve(null)).thenReturn(unknownCaller())
        whenever(speechCapture.listen()).thenReturn("decline")
        whenever(executor.decline()).thenReturn(CallActionResult.Success)

        val coordinator = buildCoordinator(this)
        val event = CallEvent.IncomingRinging(fakeCallInfo(number = null))

        coordinator.handleIncomingCall(event, callEvents)

        verify(tts).speak("Unknown caller is calling.  Answer or decline?")
        verify(tts).speak("Declined.")
        verify(executor).decline()
        assertTrue(stateTransitions.last() is JarvisState.CallRecovery)
    }

    // ── Caller hangs up before response ──────────────────────────────────────

    @Test
    fun `caller hangs up during listen window — speaks call ended and recovers`() = runTest(testDispatcher) {
        whenever(resolver.resolve(any())).thenReturn(knownContact("Alice"))

        // listen() never returns a transcript here — it must SUSPEND (not block a
        // thread) until the coordinator cancels it when the call ends, so cancellation
        // propagates under runTest. A thread-blocking mock (runBlocking on a
        // never-completed deferred) deadlocks the whole unit-test suite.
        whenever(speechCapture.listen()).doSuspendableAnswer { awaitCancellation() }

        val coordinator = buildCoordinator(this)
        val event = CallEvent.IncomingRinging(fakeCallInfo())

        val job = launch {
            coordinator.handleIncomingCall(event, callEvents)
        }

        // Let coordinator reach the listen window
        advanceUntilIdle()

        // Caller hangs up
        callEvents.emit(CallEvent.CallEnded(fakeCallInfo().copy(callState = IncomingCallState.IDLE)))
        advanceUntilIdle()
        job.join()

        verify(tts).speak("Call ended.")
        assertTrue(stateTransitions.last() is JarvisState.CallRecovery)
        verify(executor, never()).answer()
        verify(executor, never()).decline()
    }

    // ── Timeout (no response) ─────────────────────────────────────────────────

    @Test
    fun `no response within timeout — recovers without executing any action`() = runTest(testDispatcher) {
        whenever(resolver.resolve(any())).thenReturn(knownContact("Bob"))
        // Returns blank — simulates timeout / empty recognition
        whenever(speechCapture.listen()).thenReturn("")

        val coordinator = buildCoordinator(this)
        val event = CallEvent.IncomingRinging(fakeCallInfo())

        coordinator.handleIncomingCall(event, callEvents)

        verify(executor, never()).answer()
        verify(executor, never()).decline()
        assertTrue(stateTransitions.last() is JarvisState.CallRecovery)
    }

    // ── ANSWER_PHONE_CALLS permission denied ──────────────────────────────────

    @Test
    fun `answer denied by permission — speaks permission error and recovers`() = runTest(testDispatcher) {
        whenever(resolver.resolve(any())).thenReturn(knownContact("Sam"))
        whenever(speechCapture.listen()).thenReturn("answer")
        whenever(executor.answer()).thenReturn(CallActionResult.PermissionDenied)

        val info = fakeCallInfo().copy(canAnswer = true)  // permission granted for the check
        val coordinator = buildCoordinator(this)
        val event = CallEvent.IncomingRinging(info)

        coordinator.handleIncomingCall(event, callEvents)

        verify(tts).speak("I need the answer calls permission.")
        assertTrue(stateTransitions.last() is JarvisState.CallRecovery)
    }

    @Test
    fun `canAnswer false — speaks no-permission message without calling executor`() = runTest(testDispatcher) {
        whenever(resolver.resolve(any())).thenReturn(knownContact("Sam"))
        whenever(speechCapture.listen()).thenReturn("answer")

        // canAnswer = false → permission check inside coordinator fires
        val info = fakeCallInfo().copy(canAnswer = false)
        val coordinator = buildCoordinator(this)
        val event = CallEvent.IncomingRinging(info)

        coordinator.handleIncomingCall(event, callEvents)

        verify(executor, never()).answer()
        verify(tts).speak("I don't have permission to answer calls.")
        assertTrue(stateTransitions.last() is JarvisState.CallRecovery)
    }

    // ── Unrecognised command → second chance ──────────────────────────────────

    @Test
    fun `unrecognised command followed by valid answer on retry`() = runTest(testDispatcher) {
        whenever(resolver.resolve(any())).thenReturn(knownContact("Eve"))
        // First listen: unrecognised; second listen: "answer"
        whenever(speechCapture.listen())
            .thenReturn("uh what")
            .thenReturn("answer")
        whenever(executor.answer()).thenReturn(CallActionResult.Success)

        val coordinator = buildCoordinator(this)
        val event = CallEvent.IncomingRinging(fakeCallInfo())

        val job = launch {
            coordinator.handleIncomingCall(event, callEvents)
        }
        advanceUntilIdle()

        callEvents.emit(CallEvent.CallEnded(fakeCallInfo().copy(callState = IncomingCallState.IDLE)))
        advanceUntilIdle()
        job.join()

        verify(tts).speak("Say answer or decline.")
        verify(executor).answer()
    }

    // ── Announcement text formatting ──────────────────────────────────────────

    @Test
    fun `announcement uses resolved display name not raw number`() = runTest(testDispatcher) {
        whenever(resolver.resolve("+447911123456")).thenReturn(
            ResolvedContact("Mum", isKnown = true, confidence = ResolutionConfidence.HIGH)
        )
        whenever(speechCapture.listen()).thenReturn("decline")
        whenever(executor.decline()).thenReturn(CallActionResult.Success)

        val coordinator = buildCoordinator(this)
        val event = CallEvent.IncomingRinging(fakeCallInfo(number = "+447911123456"))

        coordinator.handleIncomingCall(event, callEvents)

        verify(tts).speak("Mum is calling.  Answer or decline?")
    }
}
