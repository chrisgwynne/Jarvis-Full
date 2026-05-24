package com.jarvis.assistant.remote.macbridge

/**
 * Controls what role the Android Jarvis instance plays when connected to Mac Jarvis.
 *
 * AUTO           — recommended default: Android hands off to Mac when Mac is active and
 *                  automatically resumes when Mac goes away. [RoleArbitrator] decides the
 *                  effective role; no manual switching required.
 * FULL_ASSISTANT — Android always listens and speaks, regardless of Mac state.
 * BRIDGE_ONLY    — Android is always a silent executor; voice pipeline permanently off.
 * DISABLED       — nothing starts: no bridge, no voice, no executors.
 */
enum class AndroidRole(val displayName: String, val description: String) {
    AUTO(
        displayName = "Automatic",
        description = "Android hands off to Mac when Mac is active and resumes when Mac is unavailable",
    ),
    FULL_ASSISTANT(
        displayName = "Full assistant",
        description = "Jarvis always listens and speaks on this device",
    ),
    BRIDGE_ONLY(
        displayName = "Bridge only",
        description = "Android silently executes Mac commands — no local listening or speaking",
    ),
    DISABLED(
        displayName = "Off",
        description = "Bridge and voice both disabled",
    ),
}
