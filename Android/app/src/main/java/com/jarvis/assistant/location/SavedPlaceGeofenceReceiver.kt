package com.jarvis.assistant.location

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent

/**
 * SavedPlaceGeofenceReceiver — handles ENTER / EXIT transitions for geofences
 * registered by [SavedPlaceGeofencer] and writes them to
 * [SavedPlaceTransitionStore] for the proactive engine to read.
 *
 * Manifest declaration:
 *   <receiver
 *       android:name=".location.SavedPlaceGeofenceReceiver"
 *       android:exported="false"/>
 */
class SavedPlaceGeofenceReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "SavedPlaceGeofenceRx"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) {
            Log.w(TAG, "[GEOFENCE_EVENT_ERROR] code=${event.errorCode}")
            return
        }
        val triggers = event.triggeringGeofences ?: return
        val kind = when (event.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> SavedPlaceTransitionStore.Kind.ENTER
            Geofence.GEOFENCE_TRANSITION_EXIT  -> SavedPlaceTransitionStore.Kind.EXIT
            else                               -> return
        }
        val centre = event.triggeringLocation
        val store  = SavedPlaceTransitionStore(context)
        triggers.forEach { fence ->
            val label = fence.requestId.removePrefix(SavedPlaceGeofencer.ID_PREFIX)
            store.record(
                label = label,
                kind  = kind,
                lat   = centre?.latitude ?: 0.0,
                lon   = centre?.longitude ?: 0.0,
            )
            Log.d(TAG, "[GEOFENCE_EVENT] label=$label kind=$kind")
        }
    }
}
