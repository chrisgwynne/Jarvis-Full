package com.jarvis.assistant.gmail

import android.util.Log

/**
 * GmailService — scaffold for Gmail triage features.
 *
 * STATUS:
 *   PARTIAL — this module is intentionally not wired yet. Email triage needs
 *   a Google OAuth flow that the user must consent to once.  The shape below
 *   is the public surface the rest of Jarvis will depend on — implementations
 *   plug in behind it.
 *
 * SETUP CHECKLIST (to bring this online):
 *   1. Register an OAuth client in the Google Cloud project that already
 *      hosts Distance Matrix + GA4 (`sigma-heuristic-486316-k7`).
 *      Scope: `https://www.googleapis.com/auth/gmail.modify`.
 *   2. Build a Settings screen that fires the consent flow and stores the
 *      resulting refresh token in EncryptedSharedPreferences.
 *   3. Implement `loadAccessToken` here against the stored refresh token.
 *   4. Replace each stub below with the real Gmail REST call
 *      (`gmail/v1/users/me/messages`, `…/messages/{id}/modify`).
 *   5. Register the corresponding voice tools (GmailTriageTool,
 *      GmailReplyTool) in ToolRegistry.
 *
 * SAFETY NOTES:
 *   - Reading email is LOW_RISK; replying / sending is HIGH_RISK and must
 *     route through AutonomyEngine even when this is wired.
 *   - All Gmail data MUST be skipped when [com.jarvis.assistant.runtime
 *     .GuestMode.isActive] is true — Gmail content is exactly the kind of
 *     secret a guest must not see.
 */
class GmailService {

    companion object {
        private const val TAG = "GmailService"
    }

    /**
     * Whether the user has completed the OAuth flow and Gmail features are
     * available.  Stub: always false until [setRefreshToken] is implemented.
     */
    val isConfigured: Boolean
        get() = false

    /**
     * List up to [limit] recent unread messages from the inbox.
     *
     * Stub returns an empty list — wire to the Gmail REST API in the
     * implementation phase.
     */
    suspend fun recentUnread(limit: Int = 5): List<GmailSummary> {
        if (!isConfigured) {
            Log.d(TAG, "[GMAIL_NOT_CONFIGURED] recentUnread skipped")
            return emptyList()
        }
        if (com.jarvis.assistant.runtime.GuestMode.isActive) {
            Log.d(TAG, "[GMAIL_GUEST_SKIP] recentUnread skipped")
            return emptyList()
        }
        // TODO: implement Gmail REST call.
        return emptyList()
    }

    /** Stub: mark a thread as read.  No-op until wired. */
    suspend fun markRead(messageId: String): Boolean {
        if (!isConfigured) return false
        // TODO: implement.
        return false
    }
}

/** Lightweight shape returned by triage queries — no body, only headers. */
data class GmailSummary(
    val id:           String,
    val fromName:     String,
    val fromAddress:  String,
    val subject:      String,
    val snippet:      String,
    val receivedAtMs: Long,
    val isUnread:     Boolean,
)
