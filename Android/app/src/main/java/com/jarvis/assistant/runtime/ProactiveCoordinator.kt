package com.jarvis.assistant.runtime

import android.content.Context
import android.util.Log
import com.jarvis.assistant.proactive.ProactiveEngine
import com.jarvis.assistant.proactive.scheduled.ScheduledReminderEngine
import com.jarvis.assistant.proactive.followup.ConversationalProactiveEngine
import com.jarvis.assistant.intelligence.ContextIntelligenceEngine
import com.jarvis.assistant.ambient.AmbientProactiveEventEmitter
import kotlinx.coroutines.CoroutineScope

/**
 * ProactiveCoordinator — manages the proactive intelligence engines.
 * 
 * Extracted from [JarvisRuntime] as part of the god-object refactor.
 * Owns the lifecycle and dispatching of proactive events.
 */
class ProactiveCoordinator(
    private val proactiveEngine: ProactiveEngine,
    private val intelligenceEngine: ContextIntelligenceEngine,
    private val ambientEmitter: AmbientProactiveEventEmitter,
    private val scheduledReminderEngine: ScheduledReminderEngine?,
    private val convProactiveEngine: ConversationalProactiveEngine,
    private val scheduledReminderBridge: com.jarvis.assistant.proactive.scheduled.ScheduledReminderDispatchBridge?
) {
    companion object {
        private const val TAG = "ProactiveCoord"
    }

    fun start(scope: CoroutineScope) {
        Log.i(TAG, "[PROACTIVE_START]")
        proactiveEngine.start()
        intelligenceEngine.start()
        ambientEmitter.start()
        scheduledReminderEngine?.start(scope)
        convProactiveEngine.start()
    }

    fun stop() {
        Log.i(TAG, "[PROACTIVE_STOP]")
        proactiveEngine.stop()
        intelligenceEngine.stop()
        ambientEmitter.stop()
        scheduledReminderEngine?.stop()
        convProactiveEngine.stop()
        scheduledReminderBridge?.stop()
    }

    /** Latest snapshot from the main proactive engine. */
    val lastSnapshot get() = proactiveEngine.lastSnapshot
}
