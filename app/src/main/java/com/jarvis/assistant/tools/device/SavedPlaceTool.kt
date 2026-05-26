package com.jarvis.assistant.tools.device

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.jarvis.assistant.location.CurrentLocationProvider
import com.jarvis.assistant.location.SavedLocationsStore
import com.jarvis.assistant.maps.DirectionsCoordinator
import com.jarvis.assistant.maps.MapsIntentHandler
import com.jarvis.assistant.maps.PlaceMatch
import com.jarvis.assistant.maps.TravelMode
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * SavedPlaceTool — handles user-defined named places beyond home.
 *
 * Three intent shapes:
 *
 *   SAVE     — "save this place as gym" / "remember this as the gym" /
 *              "save my location as mum's house"
 *              → captures current GPS + reverse-geocoded address.
 *
 *   NAVIGATE — "navigate to gym" / "drive to the gym" / "walk to mum's"
 *              → opens Maps using the saved address/coords for that label.
 *
 *   ETA      — "how long until I'm at the gym" / "how long to the gym" /
 *              "how far is the gym"
 *              → opens Maps route preview (Distance Matrix wiring planned).
 *
 *   FORGET   — "forget the gym" / "delete my gym address" /
 *              "remove the gym location"
 *
 * Home is intentionally NOT handled here — [HomeTool] owns "home" because the
 * user phrases that intent very differently ("drive home", "navigate home").
 * Work IS handled here so the user can say "navigate to work".
 *
 * Disambiguation contract: NAVIGATE / ETA / FORGET match only when the
 * extracted label name corresponds to an existing saved label.  Any other
 * "navigate to X" falls through to [NavigateTool] which forwards X to Maps
 * for geocoding.  That means adding a new saved place is a one-utterance
 * action and never accidentally shadows fresh place lookups.
 *
 * Registered AFTER [HomeTool] and BEFORE [NavigateTool] / [DirectionsTool] /
 * [NearestPlaceTool].
 */
class SavedPlaceTool(
    private val context: Context,
    private val savedLocations: SavedLocationsStore,
    private val locationProvider: CurrentLocationProvider,
    private val directions: DirectionsCoordinator? = null,
) : Tool {

    override val name            = "saved_place"
    override val description     = "Save, navigate to, or check ETA for a user-named place"
    override val requiresNetwork = false
    override val isLocalFallback = true
    override val requiredPermissions: List<String> = emptyList()

    companion object {
        private const val TAG = "SavedPlaceTool"

        // "save this as the gym", "remember this as gym", "save my location as mum's house"
        private val SAVE_RE = Regex(
            """(?:save|remember|store|set)\s+""" +
            """(?:this(?:\s+(?:place|location|address|spot))?|my\s+(?:current\s+)?location|here)""" +
            """\s+as\s+(?:the\s+|my\s+|a\s+)?(.+?)\s*[.!?]?\s*$""",
            RegexOption.IGNORE_CASE
        )

        // "navigate to gym", "drive to the gym", "take me to mum's", "walk to gym"
        private val NAVIGATE_RE = Regex(
            """(?:navigate|drive|take\s+me|head|go)\s+to\s+(?:the\s+|my\s+)?(.+?)\s*[.!?]?\s*$""",
            RegexOption.IGNORE_CASE
        )

        private val WALK_RE = Regex(
            """walk(?:ing)?\s+to\s+(?:the\s+|my\s+)?(.+?)\s*[.!?]?\s*$""",
            RegexOption.IGNORE_CASE
        )

        // "directions to gym", "how do I get to the gym"
        private val DIRECTIONS_RE = Regex(
            """(?:directions?\s+(?:to\s+)?|route\s+to\s+|how\s+do\s+i\s+get\s+to\s+)(?:the\s+|my\s+)?(.+?)\s*[.!?]?\s*$""",
            RegexOption.IGNORE_CASE
        )

        // "how long until I'm at the gym", "how long to the gym", "how far is the gym"
        private val ETA_RE = Regex(
            """how\s+long\s+(?:until|till|to\s+get|before|to)\s+(?:i(?:'m|\s+am)\s+(?:at\s+|back\s+at\s+)?)?(?:the\s+|my\s+)?(.+?)\s*[.!?]?\s*$""" +
            """|how\s+far\s+(?:am\s+i\s+from\s+|is\s+(?:it\s+to\s+)?)(?:the\s+|my\s+)?(.+?)\s*[.!?]?\s*$""",
            RegexOption.IGNORE_CASE
        )

        // "forget the gym", "delete my gym address", "remove the gym location"
        private val FORGET_RE = Regex(
            """(?:forget|delete|remove|clear)\s+(?:the\s+|my\s+)?(.+?)(?:\s+(?:address|location|place|spot))?\s*[.!?]?\s*$""",
            RegexOption.IGNORE_CASE
        )

        /** Words that are never valid place labels — they're system / chat tokens. */
        private val BLACKLIST_LABELS = setOf(
            "home",      // handled by HomeTool
            "it", "that", "this", "everything", "this conversation",
            "all", "the conversation", "my memory", "the history",
            "the timer", "the alarm", "the reminder", "the task", "the todo",
        )

        /** Normalise a captured label for matching: lowercase, strip articles. */
        private fun canonicalise(raw: String): String =
            raw.lowercase()
                .trim()
                .removePrefix("the ").removePrefix("my ").removePrefix("a ")
                .trimEnd('.', '?', '!', ',')
                .trim()
    }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Manage user-defined named places: save, navigate to, ETA, forget.",
        parameters  = mapOf(
            "type" to "object",
            "properties" to mapOf(
                "action" to mapOf(
                    "type"        to "string",
                    "description" to "SAVE, NAVIGATE, WALK, DIRECTIONS, ETA, FORGET",
                    "enum"        to listOf("SAVE", "NAVIGATE", "WALK", "DIRECTIONS", "ETA", "FORGET"),
                ),
                "label"  to mapOf("type" to "string", "description" to "Place label, e.g. 'gym'"),
            ),
            "required" to listOf("action", "label"),
        )
    )

    override fun matches(transcript: String): ToolInput? {
        val t = transcript.trim()

        // SAVE always wins regardless of whether the label already exists — the
        // user is overwriting / creating, no need to gate on store membership.
        SAVE_RE.find(t)?.let { m ->
            val label = canonicalise(m.groupValues[1])
            if (label.isBlank() || label in BLACKLIST_LABELS) return@let
            return ToolInput(t, mapOf("action" to "SAVE", "label" to label))
        }

        FORGET_RE.find(t)?.let { m ->
            val label = canonicalise(m.groupValues[1])
            if (label !in savedLabels()) return@let
            return ToolInput(t, mapOf("action" to "FORGET", "label" to label))
        }

        // For nav / directions / ETA we ONLY match when the label exists in the
        // store.  Otherwise return null and let NavigateTool / DirectionsTool
        // handle the free-text place name via Maps geocoding.
        WALK_RE.find(t)?.let { m ->
            val label = canonicalise(m.groupValues[1])
            if (label !in savedLabels()) return@let
            return ToolInput(t, mapOf("action" to "WALK", "label" to label))
        }
        NAVIGATE_RE.find(t)?.let { m ->
            val label = canonicalise(m.groupValues[1])
            if (label !in savedLabels()) return@let
            return ToolInput(t, mapOf("action" to "NAVIGATE", "label" to label))
        }
        DIRECTIONS_RE.find(t)?.let { m ->
            val label = canonicalise(m.groupValues[1])
            if (label !in savedLabels()) return@let
            return ToolInput(t, mapOf("action" to "DIRECTIONS", "label" to label))
        }
        ETA_RE.find(t)?.let { m ->
            val label = canonicalise(m.groupValues[1].ifBlank { m.groupValues[2] })
            if (label !in savedLabels()) return@let
            return ToolInput(t, mapOf("action" to "ETA", "label" to label))
        }
        return null
    }

    override suspend fun execute(input: ToolInput): ToolResult {
        val action = input.param("action")
        val label  = input.param("label").lowercase().trim()
        Log.d(TAG, "[SAVED_PLACE_ACTION] action=$action label=\"$label\"")

        return when (action) {
            "SAVE"       -> handleSave(label)
            "FORGET"     -> handleForget(label)
            "NAVIGATE"   -> openMaps(label, walking = false, directionsOnly = false)
            "WALK"       -> openMaps(label, walking = true,  directionsOnly = false)
            "DIRECTIONS" -> openMaps(label, walking = false, directionsOnly = true)
            "ETA"        -> handleEta(label)
            else         -> ToolResult.Failure("Unknown saved-place action.")
        }
    }

    private suspend fun handleEta(label: String): ToolResult {
        val place = savedLocations.get(label)
            ?: return ToolResult.Failure("I don't have $label saved.")
        val spoken = trySpokenEta(place.address, place.lat, place.lon, label)
        if (spoken != null) {
            Log.d(TAG, "[ETA_SPOKEN] label=$label \"$spoken\"")
            return ToolResult.Success(spoken)
        }
        return openMaps(label, walking = false, directionsOnly = true,
                        spokenSuffix = " — Maps will show your ETA.")
    }

    private suspend fun trySpokenEta(
        destAddress: String,
        destLat: Double?,
        destLon: Double?,
        label: String,
    ): String? {
        val coordinator = directions ?: return null
        try { locationProvider.refresh(highAccuracy = false) } catch (_: Exception) {}
        val origin = locationProvider.lastResult ?: return null
        val summary = try {
            coordinator.summarise(
                destinationText  = if (destLat == null || destLon == null) destAddress else null,
                destinationPlace = if (destLat != null && destLon != null)
                    PlaceMatch(
                        name           = label,
                        address        = destAddress,
                        latitude       = destLat,
                        longitude      = destLon,
                        distanceMeters = null,
                    ) else null,
                originLat = origin.latitude,
                originLng = origin.longitude,
                mode      = TravelMode.DRIVING,
            )
        } catch (e: Exception) {
            Log.w(TAG, "[ETA_FETCH_FAILED] label=$label ${e.message}")
            return null
        }
        val duration = summary.durationText ?: return null
        return "You're $duration from $label."
    }

    // ── Handlers ────────────────────────────────────────────────────────────

    private suspend fun handleSave(label: String): ToolResult {
        if (label in BLACKLIST_LABELS) {
            return ToolResult.Failure("That's not a place name I can save.")
        }
        // Refresh — covers the cold-start case where lastResult is still null.
        try { locationProvider.refresh(highAccuracy = true) } catch (_: Exception) {}
        val fix = locationProvider.lastResult
            ?: return ToolResult.Failure(
                "I couldn't get a location fix to save. Turn location on and try again."
            )
        val address = fix.displayLabel ?: "Saved location"
        savedLocations.save(label, address, lat = fix.latitude, lon = fix.longitude)
        Log.d(TAG, "[SAVED_PLACE_SAVED] label=\"$label\" address=\"$address\" " +
            "lat=${fix.latitude} lon=${fix.longitude}")
        return ToolResult.Success("Saved $label.")
    }

    private fun handleForget(label: String): ToolResult {
        savedLocations.remove(label)
        Log.d(TAG, "[SAVED_PLACE_FORGOTTEN] label=\"$label\"")
        return ToolResult.Success("Forgot $label.")
    }

    private fun openMaps(
        label: String,
        walking: Boolean,
        directionsOnly: Boolean,
        spokenSuffix: String = ".",
    ): ToolResult {
        val place = savedLocations.get(label)
            ?: return ToolResult.Failure("I don't have $label saved.")

        val handler = MapsIntentHandler(context)
        val uri = if (directionsOnly) {
            handler.directionsUri(
                destination = place.address,
                mode        = if (walking) com.jarvis.assistant.maps.TravelMode.WALKING
                              else com.jarvis.assistant.maps.TravelMode.DRIVING,
                originLat   = place.lat,
                originLng   = place.lon,
            )
        } else {
            if (place.lat != null && place.lon != null) {
                Uri.parse("google.navigation:q=${place.lat},${place.lon}" +
                    if (walking) "&mode=w" else "")
            } else {
                Uri.parse("google.navigation:q=" + Uri.encode(place.address) +
                    if (walking) "&mode=w" else "")
            }
        }
        Log.d(TAG, "[MAPS_ROUTE_REQUESTED] label=$label walking=$walking " +
            "directionsOnly=$directionsOnly uri=$uri")

        try {
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                setPackage(MapsIntentHandler.MAPS_PACKAGE)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (!MapsIntentHandler.isGoogleMapsInstalled(context)) intent.setPackage(null)
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to dispatch Maps intent: ${e.message}")
            return ToolResult.Failure("Couldn't open Maps for $label.")
        }

        val verb = when {
            directionsOnly -> "Opening route to $label"
            walking        -> "Walking to $label"
            else           -> "Navigating to $label"
        }
        return ToolResult.Success(verb + spokenSuffix)
    }

    // ── Internal ────────────────────────────────────────────────────────────

    /** Lowercased set of every saved label except `home` (HomeTool owns it). */
    private fun savedLabels(): Set<String> =
        savedLocations.allLabels()
            .map { it.lowercase() }
            .filter { it != SavedLocationsStore.LABEL_HOME }
            .toSet()
}
