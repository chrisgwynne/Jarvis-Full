package com.jarvis.assistant.ui.tablet

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * TabletEmailCommandStore — process-wide channel for voice-originated email intents.
 *
 * Producer: [com.jarvis.assistant.tools.device.EmailTool] (tablet-mode path) and
 *   [TabletComposeVoiceTool] emit here instead of launching Android intents.
 *
 * Consumers:
 *   - [TabletEmailComposeViewModel] — applies field mutations to compose state.
 *   - [TabletShell] — handles navigation side-effects (e.g. navigate to Email panel).
 *
 * Uses [SharedFlow] with `replay = 1` so a ViewModel that subscribes AFTER a voice
 * command was issued still receives the most recent intent on first collection.
 * Late-arriving intents older than [STALE_THRESHOLD_MS] are silently ignored.
 */
object TabletEmailCommandStore {

    /** Voice commands older than this are not applied (stale SharedFlow replay guard). */
    const val STALE_THRESHOLD_MS = 30_000L

    private val _commands = MutableSharedFlow<TabletEmailVoiceIntent>(
        replay           = 1,
        extraBufferCapacity = 4,
    )

    /** Hot flow of voice-originated email intents.  Always call [post] to emit. */
    val commands: SharedFlow<TabletEmailVoiceIntent> = _commands.asSharedFlow()

    /**
     * Post a new intent.  Fire-and-forget — never suspends.
     * Called from tool execute() on the background dispatcher.
     */
    fun post(intent: TabletEmailVoiceIntent) {
        _commands.tryEmit(intent)
    }
}
