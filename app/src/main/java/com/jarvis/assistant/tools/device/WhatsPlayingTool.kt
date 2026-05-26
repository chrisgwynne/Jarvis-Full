package com.jarvis.assistant.tools.device

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.util.Log
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * WhatsPlayingTool — answers "what's playing?", "what song is this?", "who's
 * this by?" using [MediaSessionManager] metadata from the currently-active
 * media app (Spotify, YouTube Music, etc.).
 *
 * Permission model:
 *   [MediaSessionManager.getActiveSessions] requires either:
 *     - MEDIA_CONTENT_CONTROL (system / signature only — we never get it), OR
 *     - a connected [android.service.notification.NotificationListenerService]
 *       passed as the component.
 *
 * Jarvis already requires notification-listener access for messaging /
 * notification reading, so the same permission carries us here — we just
 * have to pass the right component.
 *
 * Falls back to a friendly "I can't tell what's playing right now" rather
 * than hitting the LLM — the user is asking about live audio state, not
 * music trivia.
 */
class WhatsPlayingTool(private val context: Context) : Tool {

    override val name            = "whats_playing"
    override val description     = "Report the currently-playing track from any media app"
    override val requiresNetwork = false
    override val isLocalFallback = true
    override val requiredPermissions: List<String> = emptyList()

    companion object {
        private const val TAG = "WhatsPlayingTool"

        private val WHATS_PLAYING_RE = Regex(
            """(?ix)
            \b(?:
                what(?:'?s|\s+is)\s+(?:this\s+(?:song|track|tune)|playing|on(?:\s+(?:now|right\s+now))?|currently\s+playing)
              | what\s+song\s+is\s+(?:this|playing|on)
              | who(?:'?s|\s+is)\s+this\s+(?:by|singing)
              | who\s+sings\s+this
              | what\s+(?:track|tune)\s+is\s+(?:this|playing|on)
              | name\s+(?:of\s+)?this\s+(?:song|track|tune)
            )\b
            """,
        )
    }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Identify the currently-playing track from the active media session.",
    )

    override fun matches(transcript: String): ToolInput? =
        if (WHATS_PLAYING_RE.containsMatchIn(transcript))
            ToolInput(transcript, emptyMap())
        else null

    override suspend fun execute(input: ToolInput): ToolResult {
        val controller = activeMediaController()
        if (controller == null) {
            Log.d(TAG, "[WHATS_PLAYING_NO_SESSION]")
            return ToolResult.Success("Nothing playing right now.")
        }

        val isPlaying = controller.playbackState?.state == PlaybackState.STATE_PLAYING
        val metadata  = controller.metadata
        val title     = metadata?.getString(android.media.MediaMetadata.METADATA_KEY_TITLE)?.takeIf { it.isNotBlank() }
        val artist    = metadata?.getString(android.media.MediaMetadata.METADATA_KEY_ARTIST)?.takeIf { it.isNotBlank() }
            ?: metadata?.getString(android.media.MediaMetadata.METADATA_KEY_ALBUM_ARTIST)?.takeIf { it.isNotBlank() }
        val app       = appLabel(controller.packageName)

        Log.d(TAG, "[WHATS_PLAYING_FOUND] pkg=${controller.packageName} " +
            "playing=$isPlaying title=\"$title\" artist=\"$artist\"")

        val core = when {
            title != null && artist != null -> "$title by $artist"
            title != null                   -> title
            artist != null                  -> "$artist"
            else                            -> null
        }

        val spoken = when {
            core != null && isPlaying  -> "$core."
            core != null && !isPlaying -> "$core — paused."
            !isPlaying                 -> "Nothing playing right now."
            else                       -> "Something's playing on $app, but it didn't say what."
        }
        return ToolResult.Success(spoken)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    /**
     * Pick the most relevant media controller — the first one that is actively
     * playing, or the first one available if none are playing (so we can still
     * report "X — paused").
     */
    private fun activeMediaController(): MediaController? {
        return try {
            val msm = context.getSystemService(MediaSessionManager::class.java) ?: return null
            // Pass our own NotificationListenerService component to satisfy the
            // permission check.  Falls back to null which throws SecurityException
            // on locked-down devices — caught below.
            val listenerComponent = ComponentName(
                context,
                com.jarvis.assistant.notifications.JarvisNotificationListener::class.java
            )
            val sessions = msm.getActiveSessions(listenerComponent)
            sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
                ?: sessions.firstOrNull()
        } catch (e: SecurityException) {
            Log.d(TAG, "[WHATS_PLAYING_NO_PERMISSION] ${e.message}")
            null
        } catch (e: Exception) {
            Log.w(TAG, "[WHATS_PLAYING_FAILED] ${e.message}")
            null
        }
    }

    private fun appLabel(pkg: String): String {
        return try {
            val pm = context.packageManager
            val info = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(info).toString()
        } catch (_: PackageManager.NameNotFoundException) {
            pkg
        }
    }
}
