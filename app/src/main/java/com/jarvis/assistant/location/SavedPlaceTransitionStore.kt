package com.jarvis.assistant.location

import android.content.Context
import android.content.SharedPreferences
import android.util.Log

/**
 * SavedPlaceTransitionStore — single-slot record of the most recent
 * geofence ENTER / EXIT transition, written by [SavedPlaceGeofenceReceiver]
 * and read by the proactive context source.
 *
 * Single-slot by design: the proactive pipeline only ever consumes the
 * latest unacknowledged transition; previous transitions are stale and
 * would just create noisy duplicate suggestions.
 */
class SavedPlaceTransitionStore(context: Context) {

    companion object {
        private const val TAG          = "SavedPlaceTransition"
        private const val PREFS_NAME   = "jarvis_saved_place_transitions"
        private const val KEY_LABEL    = "last_label"
        private const val KEY_KIND     = "last_kind"     // "enter" / "exit"
        private const val KEY_AT       = "last_at"
        private const val KEY_LAT      = "last_lat"
        private const val KEY_LON      = "last_lon"
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** Record the most recent transition.  Overwrites any prior record. */
    fun record(label: String, kind: Kind, lat: Double, lon: Double, atMs: Long = System.currentTimeMillis()) {
        prefs.edit()
            .putString(KEY_LABEL, label)
            .putString(KEY_KIND, kind.name)
            .putLong(KEY_AT, atMs)
            .putFloat(KEY_LAT, lat.toFloat())
            .putFloat(KEY_LON, lon.toFloat())
            .apply()
        Log.d(TAG, "[SAVED_PLACE_TRANSITION_RECORDED] label=$label kind=$kind")
    }

    /** Read and clear in one call — proactive engine consumes once. */
    fun consume(): Record? {
        val label = prefs.getString(KEY_LABEL, null) ?: return null
        val kind  = prefs.getString(KEY_KIND, null)?.let { runCatching { Kind.valueOf(it) }.getOrNull() }
            ?: return null
        val atMs  = prefs.getLong(KEY_AT, 0L)
        val lat   = prefs.getFloat(KEY_LAT, 0f).toDouble()
        val lon   = prefs.getFloat(KEY_LON, 0f).toDouble()
        prefs.edit()
            .remove(KEY_LABEL).remove(KEY_KIND).remove(KEY_AT)
            .remove(KEY_LAT).remove(KEY_LON)
            .apply()
        return Record(label, kind, lat, lon, atMs)
    }

    /** Peek without consuming. */
    fun peek(): Record? {
        val label = prefs.getString(KEY_LABEL, null) ?: return null
        val kind  = prefs.getString(KEY_KIND, null)?.let { runCatching { Kind.valueOf(it) }.getOrNull() }
            ?: return null
        return Record(
            label = label,
            kind  = kind,
            lat   = prefs.getFloat(KEY_LAT, 0f).toDouble(),
            lon   = prefs.getFloat(KEY_LON, 0f).toDouble(),
            atMs  = prefs.getLong(KEY_AT, 0L),
        )
    }

    enum class Kind { ENTER, EXIT }

    data class Record(
        val label: String,
        val kind:  Kind,
        val lat:   Double,
        val lon:   Double,
        val atMs:  Long,
    )
}
