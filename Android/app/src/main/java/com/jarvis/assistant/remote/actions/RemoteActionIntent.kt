package com.jarvis.assistant.remote.actions

import org.json.JSONObject

/**
 * Detects voice commands targeting Mac actions.
 *
 * Rules:
 * - Explicit Mac phrases ("on the Mac", "on my Mac") → MAC
 * - App names that are Mac-only (News, Notes, Safari, Finder, Calendar) → MAC preferred
 * - Ambiguous Android+Mac apps → AMBIGUOUS (caller asks user)
 * - Everything else → LOCAL (handle on Android)
 *
 * Does NOT steal local Android commands that happen to mention generic words.
 */
object RemoteActionIntent {

    enum class Routing { MAC, LOCAL, AMBIGUOUS }

    data class DetectionResult(
        val routing: Routing,
        val action: String,               // "open_app" | "create_note" | "show_camera" | "open_jarvis"
        val parameters: Map<String, String>,
        val userVisibleText: String,      // spoken confirmation to Android user
        val ambiguousPrompt: String? = null  // prompt if AMBIGUOUS
    )

    // Apps that exist ONLY on Mac (never on Android)
    private val macOnlyApps = setOf(
        "news", "safari", "finder", "calendar", "mail", "xcode",
        "preview", "pages", "keynote", "numbers", "facetime",
        "system settings", "system preferences"
    )

    // Apps that exist on BOTH platforms (ambiguous)
    private val ambiguousApps = setOf(
        "notes", "music", "spotify", "chrome", "firefox", "maps"
    )

    // Explicit Mac target phrases
    private val macPhrases = listOf(
        "on the mac", "on my mac", "on the computer", "on my computer",
        "on the laptop", "on my laptop", "to the mac"
    )

    fun detect(transcript: String): DetectionResult? {
        val lower = transcript.lowercase().trim()

        val hasMacPhrase = macPhrases.any { lower.contains(it) }

        // "put this on the mac" / "send this to the mac" → file transfer
        if (hasMacPhrase && (lower.contains("put this") || lower.contains("send this") ||
                             lower.contains("open this"))) {
            return DetectionResult(
                routing = Routing.MAC,
                action = "file_transfer",  // handled separately
                parameters = emptyMap(),
                userVisibleText = "Sending to the Mac."
            )
        }

        // "show mac camera" / "show me the mac camera"
        if (lower.contains("mac camera") || lower.contains("camera on the mac")) {
            return DetectionResult(
                routing = Routing.MAC,
                action = "show_camera",
                parameters = emptyMap(),
                userVisibleText = "Showing Mac camera."
            )
        }

        // "open jarvis on the mac" / "open jarvis on my mac"
        if (lower.contains("open jarvis") && hasMacPhrase) {
            return DetectionResult(
                routing = Routing.MAC,
                action = "open_jarvis",
                parameters = emptyMap(),
                userVisibleText = "Opening Jarvis on the Mac."
            )
        }

        // "create a note [called X] [on the mac]"
        val notePattern = Regex("""create (?:a )?note(?: called (.+))?(?:on (?:the|my) mac)?""")
        val noteMatch = notePattern.find(lower)
        if (noteMatch != null && (hasMacPhrase || !lower.contains("on (?:android|my phone|phone)".toRegex()))) {
            val rawTitle = noteMatch.groupValues.getOrNull(1)?.trim()?.ifBlank { null }
            // Strip trailing "on the mac" from title
            val title = rawTitle?.let { t ->
                macPhrases.fold(t) { acc, phrase -> acc.removeSuffix(phrase).trim() }
            }?.ifBlank { null }
            return DetectionResult(
                routing = if (hasMacPhrase) Routing.MAC else Routing.AMBIGUOUS,
                action = "create_note",
                parameters = buildMap { title?.let { put("title", it) } },
                userVisibleText = if (title != null) "Creating a note called $title on the Mac."
                                  else "Creating a note on the Mac.",
                ambiguousPrompt = if (!hasMacPhrase) "Do you want that note on Android or on the Mac?" else null
            )
        }

        // "open X [on the mac]"
        val openPattern = Regex("""open (.+?)(?:\s+on (?:the|my) (?:mac|computer|laptop))?$""")
        val openMatch = openPattern.find(lower)
        if (openMatch != null) {
            var appName = openMatch.groupValues[1].trim()
            // Strip trailing mac phrases from app name
            appName = macPhrases.fold(appName) { acc, phrase -> acc.removeSuffix(phrase).trim() }
            appName = appName.trim()

            // Capitalize app name for display
            val displayName = appName.split(" ").joinToString(" ") { it.replaceFirstChar { c -> c.uppercase() } }

            return when {
                hasMacPhrase -> DetectionResult(
                    routing = Routing.MAC,
                    action = "open_app",
                    parameters = mapOf("appName" to displayName),
                    userVisibleText = "Opening $displayName on the Mac."
                )
                macOnlyApps.contains(appName.lowercase()) -> DetectionResult(
                    routing = Routing.MAC,
                    action = "open_app",
                    parameters = mapOf("appName" to displayName),
                    userVisibleText = "Opening $displayName on the Mac."
                )
                ambiguousApps.contains(appName.lowercase()) -> DetectionResult(
                    routing = Routing.AMBIGUOUS,
                    action = "open_app",
                    parameters = mapOf("appName" to displayName),
                    userVisibleText = "Opening $displayName.",
                    ambiguousPrompt = "Do you want $displayName on Android or on the Mac?"
                )
                else -> null  // local Android command
            }
        }

        return null
    }

    fun buildRequestPayload(
        result: DetectionResult,
        requestId: String = java.util.UUID.randomUUID().toString(),
        routeId: String = java.util.UUID.randomUUID().toString(),
        sourceDeviceId: String = "android"
    ): JSONObject = JSONObject().apply {
        put("type", "remote.action.request")
        put("requestId", requestId)
        put("routeId", routeId)
        put("sourceDeviceId", sourceDeviceId)
        put("targetPlatform", "mac")
        put("action", result.action)
        put("parameters", JSONObject(result.parameters))
        put("userVisibleText", result.userVisibleText)
        put("requiresConfirmation", false)
        put("timestamp", System.currentTimeMillis())
    }
}
