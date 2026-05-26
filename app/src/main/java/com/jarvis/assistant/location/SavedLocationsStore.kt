package com.jarvis.assistant.location

import android.content.Context
import android.content.SharedPreferences
import android.util.Log

/**
 * SavedLocationsStore — user-defined named places persisted to SharedPreferences.
 *
 * Complements [PlaceLearner] (which infers places from dwell patterns) with
 * explicit user intent: "set this as home", "my work address is 10 Downing St".
 *
 * Supports three well-known labels (HOME, WORK, CUSTOM_n) plus a free-text
 * address string and optional lat/lon for GPS-exact routing.
 *
 * Coordinates are optional: when absent, Google Maps accepts the address string
 * directly in a geo: URI or navigation intent.
 */
class SavedLocationsStore(context: Context) {

    companion object {
        private const val TAG         = "SavedLocationsStore"
        private const val PREFS_NAME  = "jarvis_saved_locations"

        // Well-known label constants — match these in [HomeTool] and settings UI.
        const val LABEL_HOME = "home"
        const val LABEL_WORK = "work"

        private fun keyAddress(label: String) = "addr_$label"
        private fun keyLat(label: String)     = "lat_$label"
        private fun keyLon(label: String)     = "lon_$label"
        private fun keySetAt(label: String)   = "set_at_$label"
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // ── Generic save / get ────────────────────────────────────────────────────

    /**
     * Save a named place.  [address] is the human-readable string used in Maps
     * URIs.  [lat]/[lon] are optional; when provided they are used for distance
     * calculation without a geocoding round-trip.
     */
    fun save(
        label: String,
        address: String,
        lat: Double? = null,
        lon: Double? = null,
    ) {
        prefs.edit()
            .putString(keyAddress(label.lowercase()), address)
            .apply {
                if (lat != null) putFloat(keyLat(label.lowercase()), lat.toFloat())
                else remove(keyLat(label.lowercase()))
            }
            .apply {
                if (lon != null) putFloat(keyLon(label.lowercase()), lon.toFloat())
                else remove(keyLon(label.lowercase()))
            }
            .putLong(keySetAt(label.lowercase()), System.currentTimeMillis())
            .apply()
        Log.d(TAG, "[SAVED_PLACE_SAVED] label=$label address=\"$address\" hasCoords=${lat != null}")
    }

    /** Retrieve a saved place by label, or null if not set. */
    fun get(label: String): SavedPlace? {
        val key     = label.lowercase()
        val address = prefs.getString(keyAddress(key), null) ?: return null
        val lat     = if (prefs.contains(keyLat(key)))
            prefs.getFloat(keyLat(key), 0f).toDouble() else null
        val lon     = if (prefs.contains(keyLon(key)))
            prefs.getFloat(keyLon(key), 0f).toDouble() else null
        val setAt   = prefs.getLong(keySetAt(key), 0L)
        return SavedPlace(
            label   = label.lowercase(),
            address = address,
            lat     = lat,
            lon     = lon,
            setAtMs = setAt,
        )
    }

    /** Remove a saved place. */
    fun remove(label: String) {
        val key = label.lowercase()
        prefs.edit()
            .remove(keyAddress(key))
            .remove(keyLat(key))
            .remove(keyLon(key))
            .remove(keySetAt(key))
            .apply()
        Log.d(TAG, "[SAVED_PLACE_REMOVED] label=$label")
    }

    // ── Convenience wrappers ──────────────────────────────────────────────────

    fun setHome(address: String, lat: Double? = null, lon: Double? = null) =
        save(LABEL_HOME, address, lat, lon)

    fun getHome(): SavedPlace? = get(LABEL_HOME)

    fun setWork(address: String, lat: Double? = null, lon: Double? = null) =
        save(LABEL_WORK, address, lat, lon)

    fun getWork(): SavedPlace? = get(LABEL_WORK)

    /** All labels that have a saved address. */
    fun allLabels(): List<String> = prefs.all.keys
        .filter { it.startsWith("addr_") }
        .map { it.removePrefix("addr_") }
}

/** A user-defined named place. */
data class SavedPlace(
    val label:   String,
    val address: String,
    val lat:     Double?,
    val lon:     Double?,
    val setAtMs: Long,
)
