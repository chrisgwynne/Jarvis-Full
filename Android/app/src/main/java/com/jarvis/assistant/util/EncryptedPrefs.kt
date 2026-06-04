package com.jarvis.assistant.util

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Small factory for AES-256 [EncryptedSharedPreferences] backed by a Keystore
 * master key — the same scheme [SettingsStore] uses. Centralised so privacy-
 * sensitive stores (location, etc.) don't each repeat the boilerplate.
 *
 * Includes a one-time migration from a legacy plaintext prefs file. The
 * encrypted store MUST use a different on-disk file name than any pre-existing
 * plaintext file (an encrypted reader can't parse a plaintext file and would
 * throw), so callers pass the new encrypted name and the old plaintext name.
 */
object EncryptedPrefs {

    private const val TAG = "EncryptedPrefs"

    fun create(context: Context, fileName: String): SharedPreferences {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            context,
            fileName,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    /**
     * Copies all entries from a legacy plaintext prefs file into [target] once,
     * then clears and deletes the legacy file. No-op if the legacy file is empty
     * (already migrated or fresh install).
     */
    fun migrateFromPlaintext(context: Context, legacyName: String, target: SharedPreferences) {
        val legacy = context.getSharedPreferences(legacyName, Context.MODE_PRIVATE)
        val all = legacy.all
        if (all.isEmpty()) return
        val editor = target.edit()
        for ((key, value) in all) {
            when (value) {
                is String  -> editor.putString(key, value)
                is Int     -> editor.putInt(key, value)
                is Long    -> editor.putLong(key, value)
                is Float   -> editor.putFloat(key, value)
                is Boolean -> editor.putBoolean(key, value)
                is Set<*>  -> @Suppress("UNCHECKED_CAST") editor.putStringSet(key, value as Set<String>)
                else       -> { /* skip unsupported types */ }
            }
        }
        editor.apply()
        legacy.edit().clear().apply()
        runCatching { context.deleteSharedPreferences(legacyName) }
            .onFailure { Log.w(TAG, "Could not delete legacy prefs $legacyName: ${it.message}") }
        Log.i(TAG, "Migrated ${all.size} entries from plaintext '$legacyName' to encrypted store")
    }
}
