package com.jarvis.assistant.location

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingClient
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices

/**
 * SavedPlaceGeofencer — registers Android geofences for every entry in
 * [SavedLocationsStore] that has a coordinate fix.
 *
 * Fires both ENTER and EXIT events so [SavedPlaceGeofenceReceiver] can
 * record arrived/left transitions into [SavedPlaceTransitionStore]; the
 * proactive [com.jarvis.assistant.core.decisions.triggers.LocationTransitionTrigger]
 * picks them up on the next agent context snapshot.
 *
 * Lifecycle:
 *   - Call [refresh] once at service start AND whenever a saved place is
 *     added / removed / updated.
 *   - Call [clearAll] in service onDestroy or "factory reset".
 *
 * Manifest requirements (see also LocationReminderManager):
 *   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
 *   <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
 *
 * Receiver declaration needed in AndroidManifest.xml:
 *   <receiver android:name=".location.SavedPlaceGeofenceReceiver"
 *             android:exported="false"/>
 *
 * Gradle dependency: com.google.android.gms:play-services-location:21.x
 * (already pulled in by [LocationReminderManager]).
 */
class SavedPlaceGeofencer(private val context: Context) {

    companion object {
        private const val TAG          = "SavedPlaceGeofencer"
        private const val PI_REQUEST   = 7100
        /** 150 m default radius — tight enough for a single building, loose
         *  enough to absorb GPS jitter without false enter/exit cycles. */
        const val DEFAULT_RADIUS_M     = 150f
        /** All saved-place geofence IDs use this prefix so we can disambiguate
         *  from LocationReminderManager's geofences when cancelling.        */
        const val ID_PREFIX            = "saved-place:"
    }

    private val client: GeofencingClient = LocationServices.getGeofencingClient(context)

    /**
     * Re-register geofences for every saved place that has a coord fix.
     * Idempotent: removes prior registrations under [ID_PREFIX] first so a
     * removed place stops firing.
     */
    @SuppressLint("MissingPermission") // checked via hasPermission below
    fun refresh(store: SavedLocationsStore) {
        if (!hasFinePermission() || !hasBackgroundPermission()) {
            Log.w(TAG, "[GEOFENCE_REFRESH_SKIPPED] missing location permission(s)")
            return
        }

        // Build the geofence list from saved places with coords.
        val geofences = store.allLabels().mapNotNull { label ->
            val place = store.get(label) ?: return@mapNotNull null
            val lat = place.lat ?: return@mapNotNull null
            val lon = place.lon ?: return@mapNotNull null
            Geofence.Builder()
                .setRequestId(ID_PREFIX + label.lowercase())
                .setCircularRegion(lat, lon, DEFAULT_RADIUS_M)
                .setExpirationDuration(Geofence.NEVER_EXPIRE)
                .setTransitionTypes(
                    Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT
                )
                .setLoiteringDelay(30_000)
                .build()
        }

        // Cancel everything we previously registered, then add the fresh set.
        // GeofencingClient supports removeGeofences(List<String>) but we don't
        // track which IDs we last wrote; removing by PendingIntent removes ALL
        // geofences registered under that intent, which is exactly the scope.
        val pendingIntent = pendingIntent()
        client.removeGeofences(pendingIntent)
            .addOnCompleteListener {
                if (geofences.isEmpty()) {
                    Log.d(TAG, "[GEOFENCE_REFRESH_DONE] count=0")
                    return@addOnCompleteListener
                }
                val request = GeofencingRequest.Builder()
                    .setInitialTrigger(0)   // don't fire on registration for already-inside places
                    .addGeofences(geofences)
                    .build()
                client.addGeofences(request, pendingIntent)
                    .addOnSuccessListener {
                        Log.d(TAG, "[GEOFENCE_REFRESH_DONE] count=${geofences.size}")
                    }
                    .addOnFailureListener { e ->
                        Log.w(TAG, "[GEOFENCE_REFRESH_FAILED] ${e.message}")
                    }
            }
    }

    fun clearAll() {
        client.removeGeofences(pendingIntent())
            .addOnCompleteListener {
                Log.d(TAG, "[GEOFENCE_CLEARED_ALL]")
            }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private fun pendingIntent(): PendingIntent {
        val intent = Intent(context, SavedPlaceGeofenceReceiver::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                PendingIntent.FLAG_MUTABLE else 0)
        return PendingIntent.getBroadcast(context, PI_REQUEST, intent, flags)
    }

    private fun hasFinePermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasBackgroundPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_BACKGROUND_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        else true
}
