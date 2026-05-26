package com.jarvis.assistant.runtime

import android.util.Log

/**
 * Lightweight observer for listening lifecycle transitions.
 * Does NOT replace JarvisStateMachine — it logs alongside it for
 * observability and field diagnostics.
 *
 * Grep for "[LISTENING_TRANSITION]" in logcat tagged "JarvisListening".
 */
object ListeningLifecycleMonitor {

    private const val TAG = "JarvisListening"

    enum class Phase {
        Idle,
        WakeListening,
        CommandListening,
        Processing,
        Speaking,
        Restarting,
        Suspended,
        ErrorRecovering,
    }

    @Volatile
    var current: Phase = Phase.Idle
        private set

    fun transition(next: Phase, reason: String = "") {
        val prev = current
        if (prev == next) return
        current = next
        val suffix = if (reason.isBlank()) "" else " reason=$reason"
        Log.d(TAG, "[LISTENING_TRANSITION] $prev → $next$suffix")
    }

    fun isActivelyListening(): Boolean =
        current == Phase.WakeListening || current == Phase.CommandListening
}
