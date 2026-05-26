package com.jarvis.assistant.owner

import android.content.Context
import android.content.SharedPreferences

/**
 * OwnerProfileStore — persists the single owner identity for this app instance.
 *
 * No voice embeddings. No biometric gating. The owner is whoever said their
 * name during first-run setup.  setupComplete == true is the only gate needed.
 */
class OwnerProfileStore(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    companion object {
        private const val PREFS_NAME  = "owner_profile"
        private const val KEY_NAME    = "owner_name"
        private const val KEY_CONFIRMED  = "owner_confirmed"
        private const val KEY_COMPLETE   = "setup_complete"
        private const val KEY_CREATED_AT = "created_at"
        private const val KEY_UPDATED_AT = "updated_at"
    }

    var ownerName: String
        get() = prefs.getString(KEY_NAME, "") ?: ""
        set(v) {
            prefs.edit().putString(KEY_NAME, v)
                .putLong(KEY_UPDATED_AT, System.currentTimeMillis()).apply()
        }

    var ownerConfirmed: Boolean
        get() = prefs.getBoolean(KEY_CONFIRMED, false)
        set(v) { prefs.edit().putBoolean(KEY_CONFIRMED, v).apply() }

    var setupComplete: Boolean
        get() = prefs.getBoolean(KEY_COMPLETE, false)
        set(v) { prefs.edit().putBoolean(KEY_COMPLETE, v).apply() }

    val createdAt: Long
        get() = prefs.getLong(KEY_CREATED_AT, 0L)

    val updatedAt: Long
        get() = prefs.getLong(KEY_UPDATED_AT, 0L)

    /**
     * Save the owner name, mark confirmed and setup complete in one atomic write.
     * Called immediately after the user says their name during first-run.
     */
    fun saveOwner(name: String) {
        val now = System.currentTimeMillis()
        prefs.edit()
            .putString(KEY_NAME, name.trim())
            .putBoolean(KEY_CONFIRMED, true)
            .putBoolean(KEY_COMPLETE, true)
            .putLong(KEY_CREATED_AT, if (createdAt == 0L) now else createdAt)
            .putLong(KEY_UPDATED_AT, now)
            .apply()
    }

    /** Clear all owner data (factory reset / sign-out). */
    fun clear() {
        prefs.edit().clear().apply()
    }
}
