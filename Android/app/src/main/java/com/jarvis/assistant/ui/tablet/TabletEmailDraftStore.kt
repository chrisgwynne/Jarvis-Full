package com.jarvis.assistant.ui.tablet

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject

/**
 * TabletEmailDraftStore — persists a single email compose draft to
 * [SharedPreferences] for process-death recovery.
 *
 * Serialises only the scalar fields (to/cc/bcc/subject/body) and attachment
 * metadata.  Content URIs are included so re-opening the draft can re-attach
 * files; however, URI grants may have expired — the ViewModel gracefully
 * handles a missing attachment by showing it as "unavailable".
 *
 * This is intentionally plain SharedPreferences (not EncryptedSharedPreferences)
 * because email drafts are not stored credentials; they are transient work in
 * progress that the user is about to send anyway.
 */
class TabletEmailDraftStore(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun save(state: TabletEmailComposeState) {
        if (!state.isDirty) return
        prefs.edit()
            .putString(KEY_TO,      state.to)
            .putString(KEY_CC,      state.cc)
            .putString(KEY_BCC,     state.bcc)
            .putString(KEY_SUBJECT, state.subject)
            .putString(KEY_BODY,    state.body)
            .putString(KEY_ATTACHMENTS, serialiseAttachments(state.attachments))
            .apply()
    }

    fun load(): TabletEmailComposeState? {
        if (!prefs.contains(KEY_TO)) return null
        return TabletEmailComposeState(
            to          = prefs.getString(KEY_TO,      "") ?: "",
            cc          = prefs.getString(KEY_CC,      "") ?: "",
            bcc         = prefs.getString(KEY_BCC,     "") ?: "",
            subject     = prefs.getString(KEY_SUBJECT, "") ?: "",
            body        = prefs.getString(KEY_BODY,    "") ?: "",
            attachments = deserialiseAttachments(prefs.getString(KEY_ATTACHMENTS, "[]") ?: "[]"),
            isDirty     = true,
        )
    }

    fun clear() {
        prefs.edit().clear().apply()
    }

    val hasDraft: Boolean get() = prefs.contains(KEY_TO)

    // ── Serialisation ─────────────────────────────────────────────────────────

    private fun serialiseAttachments(files: List<TabletSelectedFile>): String {
        val arr = JSONArray()
        files.forEach { f ->
            arr.put(JSONObject().apply {
                put("uri",       f.uri.toString())
                put("name",      f.name)
                put("mimeType",  f.mimeType)
                put("sizeBytes", f.sizeBytes)
                put("modifiedMs",f.modifiedMs)
            })
        }
        return arr.toString()
    }

    private fun deserialiseAttachments(json: String): List<TabletSelectedFile> {
        return try {
            val arr = JSONArray(json)
            (0 until arr.length()).mapNotNull { i ->
                val obj = arr.optJSONObject(i) ?: return@mapNotNull null
                TabletSelectedFile(
                    uri        = Uri.parse(obj.getString("uri")),
                    name       = obj.getString("name"),
                    mimeType   = obj.getString("mimeType"),
                    sizeBytes  = obj.getLong("sizeBytes"),
                    modifiedMs = obj.getLong("modifiedMs"),
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    companion object {
        private const val PREFS_NAME       = "jarvis_tablet_email_draft"
        private const val KEY_TO           = "to"
        private const val KEY_CC           = "cc"
        private const val KEY_BCC          = "bcc"
        private const val KEY_SUBJECT      = "subject"
        private const val KEY_BODY         = "body"
        private const val KEY_ATTACHMENTS  = "attachments"
    }
}
