package com.jarvis.assistant.tools.device

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.jarvis.assistant.BuildConfig
import com.jarvis.assistant.location.CurrentLocationProvider
import com.jarvis.assistant.location.SavedLocationsStore
import com.jarvis.assistant.maps.DirectionsCoordinator
import com.jarvis.assistant.maps.MapsIntentHandler
import com.jarvis.assistant.maps.TravelMode
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * HomeTool — handles "how long until I'm home", "directions home",
 * "navigate home", "drive home", "walk home".
 *
 * Reads the user's saved Home address from [SavedLocationsStore].
 * If no Home is saved, prompts the user to set one in Settings.
 *
 * Three intent shapes:
 *   NAVIGATE — "navigate home", "drive home", "take me home"
 *            → opens Google Maps turn-by-turn to saved Home address.
 *   DIRECTIONS — "directions home", "how do I get home"
 *              → opens Maps directions screen (not turn-by-turn).
 *   ETA — "how long until I'm home", "how long to get home"
 *        → opens Maps route preview (best achievable without routing API).
 *
 * Registered BEFORE NavigateTool / DirectionsTool in ToolRegistry so that
 * explicit "home" intents are captured here and the saved address is used
 * rather than forwarding the literal word "home" to the Maps geocoder.
 */
class HomeTool(
    private val context: Context,
    private val savedLocations: SavedLocationsStore,
    private val locationProvider: CurrentLocationProvider? = null,
    private val directions: DirectionsCoordinator? = null,
) : Tool {

    override val name            = "home_navigation"
    override val description     = "Navigate home, get directions home, or estimate travel time home"
    override val requiresNetwork = false
    override val isLocalFallback = true
    override val requiredPermissions: List<String> = emptyList()

    companion object {
        private const val TAG = "HomeTool"

        private val NAVIGATE_HOME_RE = Regex(
            """(?:navigate|drive|take\s+me|go|head|travel(?:ling)?)\s+home\b""" +
            """|(?:start|open|begin)\s+(?:navigation|directions)\s+home\b""" +
            """|(?:take\s+me\s+home)\b""",
            RegexOption.IGNORE_CASE
        )

        private val WALK_HOME_RE = Regex(
            """\bwalk(?:ing)?\s+home\b""",
            RegexOption.IGNORE_CASE
        )

        private val DIRECTIONS_HOME_RE = Regex(
            """\b(?:directions?\s+(?:to\s+)?home|how\s+do\s+i\s+get\s+home|route\s+home)\b""",
            RegexOption.IGNORE_CASE
        )

        // "how long until/till/before I'm [back] home", "how long to get [back] home",
        // "how far is it to home", "what's the ETA to home".
        // The optional "I'm"/"I am" and optional "back" sit between the connector
        // and "home" so all natural orderings parse: "how long until home",
        // "how long until I'm home", "how long until I'm back home", etc.
        private val ETA_HOME_RE = Regex(
            """\bhow\s+long\s+(?:until|till|before|to\s+get)""" +
            """(?:\s+i(?:'m|\s+am))?""" +
            """(?:\s+back)?""" +
            """(?:\s+to)?\s+home\b""" +
            """|\bhow\s+far\s+(?:am\s+i\s+from|is\s+it\s+to)\s+home\b""" +
            """|\bwhat(?:'s|\s+is)\s+the\s+(?:eta|travel\s+time|journey\s+time|drive\s+time)\s+(?:to\s+)?home\b""",
            RegexOption.IGNORE_CASE
        )
    }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Navigate home, get directions, or check ETA. Requires Home address saved in settings.",
        parameters  = mapOf(
            "type"       to "object",
            "properties" to mapOf(
                "mode" to mapOf(
                    "type"        to "string",
                    "description" to "NAVIGATE, WALK, DIRECTIONS, or ETA",
                    "enum"        to listOf("NAVIGATE", "WALK", "DIRECTIONS", "ETA")
                )
            ),
            "required" to listOf("mode")
        )
    )

    override fun matches(transcript: String): ToolInput? {
        val t = transcript.trim()
        return when {
            WALK_HOME_RE.containsMatchIn(t)       -> ToolInput(t, mapOf("mode" to "WALK"))
            NAVIGATE_HOME_RE.containsMatchIn(t)   -> ToolInput(t, mapOf("mode" to "NAVIGATE"))
            DIRECTIONS_HOME_RE.containsMatchIn(t) -> ToolInput(t, mapOf("mode" to "DIRECTIONS"))
            ETA_HOME_RE.containsMatchIn(t)        -> ToolInput(t, mapOf("mode" to "ETA"))
            else                                  -> null
        }
    }

    override suspend fun execute(input: ToolInput): ToolResult {
        val mode = input.param("mode")
        Log.d(TAG, "[SAVED_PLACE_LOOKUP] label=home mode=$mode")

        val home = savedLocations.getHome()
        if (home == null) {
            Log.d(TAG, "[HOME_LOCATION_MISSING] no home address saved")
            return ToolResult.Failure(
                "I don't have a home address saved yet. " +
                "Open Jarvis Settings → Saved Locations and set your home address."
            )
        }

        if (BuildConfig.DEBUG) {
            Log.d(TAG, "[HOME_LOCATION_FOUND] address=\"${home.address}\" hasCoords=${home.lat != null}")
        } else {
            Log.d(TAG, "[HOME_LOCATION_FOUND] address=[address redacted] hasCoords=${home.lat != null}")
        }

        val mapsHandler = MapsIntentHandler(context)
        val travelMode  = if (mode == "WALK") TravelMode.WALKING else TravelMode.DRIVING

        return when (mode) {
            "NAVIGATE", "WALK" -> {
                val uri = buildNavigationUri(home.address, home.lat, home.lon)
                Log.d(TAG, "[MAPS_ROUTE_REQUESTED] mode=$mode uri=$uri")
                dispatchIntent(uri)
                val verb = if (mode == "WALK") "Walking" else "Navigating"
                ToolResult.Success("$verb home.")
            }
            "DIRECTIONS" -> {
                val uri = mapsHandler.directionsUri(
                    destination = home.address,
                    mode        = travelMode,
                    originLat   = home.lat,
                    originLng   = home.lon,
                )
                Log.d(TAG, "[MAPS_ROUTE_REQUESTED] mode=DIRECTIONS uri=$uri")
                dispatchIntent(uri)
                ToolResult.Success("Directions home opened.")
            }
            "ETA" -> {
                // Live ETA via Distance Matrix.  Speaks "You're 18 minutes from
                // home" without launching Maps.  Falls back to opening the route
                // preview only when the API call fails or no key is configured.
                val spoken = trySpokenEta(home.address, home.lat, home.lon, travelMode)
                if (spoken != null) {
                    Log.d(TAG, "[ETA_SPOKEN] \"$spoken\"")
                    ToolResult.Success(spoken)
                } else {
                    val uri = mapsHandler.directionsUri(
                        destination = home.address,
                        mode        = travelMode,
                        originLat   = home.lat,
                        originLng   = home.lon,
                    )
                    Log.d(TAG, "[ETA_FALLBACK_MAPS] uri=$uri")
                    dispatchIntent(uri)
                    ToolResult.Success("Opening route home — Maps will show your ETA.")
                }
            }
            else -> {
                Log.w(TAG, "[HOME_LOCATION_MISSING] unknown mode=$mode")
                ToolResult.Failure("Unexpected mode: $mode")
            }
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private fun buildNavigationUri(address: String, lat: Double?, lon: Double?): Uri {
        // Prefer coord-based URI when available — avoids geocoding on Maps side
        // and resolves ambiguous place names (e.g. "High Street").
        return if (lat != null && lon != null) {
            Uri.parse("google.navigation:q=$lat,$lon")
        } else {
            Uri.parse("google.navigation:q=" + Uri.encode(address.trim()))
        }
    }

    /**
     * Returns a natural ETA sentence ("You're 18 minutes from home") if the
     * Distance Matrix call succeeds, or null on any failure path so the caller
     * can fall back to opening the Maps route preview.
     */
    private suspend fun trySpokenEta(
        destAddress: String,
        destLat: Double?,
        destLon: Double?,
        mode: TravelMode,
    ): String? {
        val provider    = locationProvider ?: return null
        val coordinator = directions       ?: return null

        try { provider.refresh(highAccuracy = false) } catch (_: Exception) {}
        val origin = provider.lastResult ?: return null

        val summary = try {
            coordinator.summarise(
                destinationText  = if (destLat == null || destLon == null) destAddress else null,
                destinationPlace = if (destLat != null && destLon != null)
                    com.jarvis.assistant.maps.PlaceMatch(
                        name           = "home",
                        address        = destAddress,
                        latitude       = destLat,
                        longitude      = destLon,
                        distanceMeters = null,
                    ) else null,
                originLat = origin.latitude,
                originLng = origin.longitude,
                mode      = mode,
            )
        } catch (e: Exception) {
            Log.w(TAG, "[ETA_FETCH_FAILED] ${e.message}")
            return null
        }

        val duration = summary.durationText ?: return null
        val verb = if (mode == TravelMode.WALKING) "walk" else "from"
        return if (mode == TravelMode.WALKING)
            "You're a $duration walk from home."
        else
            "You're $duration from home."
    }

    private fun dispatchIntent(uri: Uri) {
        try {
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                setPackage(MapsIntentHandler.MAPS_PACKAGE)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            // If Google Maps isn't installed, fall back to any maps handler.
            if (!MapsIntentHandler.isGoogleMapsInstalled(context)) {
                intent.setPackage(null)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to dispatch Maps intent: ${e.message}")
        }
    }
}
