package com.jarvis.assistant.ui.settings

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.BuildCircle
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.EmojiPeople
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.ManageSearch
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.NotificationsNone
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PhoneIphone
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Every settings destination in the app.
 *
 * ## Visibility
 *
 * The settings home (`SettingsRootScreen`) shows ONLY entries with
 * `developerOnly = false`.  That set is the 10 user-facing categories
 * plus one consolidated `DeveloperDiagnostics` row that itself is
 * `developerOnly = true` — visible only when Developer Mode is on.
 *
 * Every other entry exists for one of three reasons:
 *  1. It's a developer-only diagnostic screen (`*Diagnostics`) — reached
 *     from inside `DeveloperDiagnostics`.
 *  2. It's a legacy raw-config screen (`BrainGateway`, `MacBridge`,
 *     `MacBrain`) — kept for direct deep-link use only.
 *  3. It's an internal sub-screen of `MacIntegration` (`HomeAssistant`,
 *     `Calendar`, `Todoist`) or a tool sub-screen — reached
 *     programmatically.
 *
 * ## Adding a new top-level category
 *
 *   1. Add an entry here with `developerOnly = false` and a section.
 *   2. Add a `composable(route)` case in [SettingsScreen]'s NavHost.
 *   3. Create the screen composable in
 *      `com.jarvis.assistant.ui.settings.screens`.
 *   4. If it represents new functionality, update the UI test in
 *      `SettingsCategoryVisibilityTest` so the visible-row contract is
 *      enforced.
 */
internal enum class SettingsCategory(
    val title: String,
    val description: String,
    val icon: ImageVector,
    val route: String,
    val section: SettingsSection,
    /** When true this entry is hidden unless Developer Mode is enabled. */
    val developerOnly: Boolean = false,
) {

    // ────────────────────────────────────────────────────────────────────────
    // USER-FACING TOP-LEVEL (10)
    // ────────────────────────────────────────────────────────────────────────

    // Mac connection sits first — it's the core of an Android connector client.
    MacIntegration(
        title       = "Mac connection",
        description = "Pair with your Mac and check the connection",
        icon        = Icons.Filled.Psychology,
        route       = "settings/mac_integration",
        section     = SettingsSection.MacIntegration,
    ),

    Voice(
        title       = "Microphone & voice",
        description = "Wake word, microphone and Jarvis's spoken voice",
        icon        = Icons.Filled.RecordVoiceOver,
        route       = "settings/voice",
        section     = SettingsSection.VoiceListening,
    ),

    Permissions(
        title       = "Permissions",
        description = "What Jarvis can access on this phone",
        icon        = Icons.Filled.Shield,
        route       = "settings/permissions",
        section     = SettingsSection.Permissions,
    ),

    Notifications(
        title       = "Notifications",
        description = "Alerts and status messages",
        icon        = Icons.Filled.NotificationsNone,
        route       = "settings/notifications",
        section     = SettingsSection.Notifications,
    ),

    Troubleshooting(
        title       = "Troubleshooting",
        description = "Fix connection, microphone, permission and command issues",
        icon        = Icons.Filled.BuildCircle,
        route       = "settings/troubleshooting",
        section     = SettingsSection.Troubleshooting,
    ),

    AboutHelp(
        title       = "About & Help",
        description = "App version, what Jarvis can do and how to ask",
        icon        = Icons.AutoMirrored.Filled.HelpOutline,
        route       = "settings/about_help",
        section     = SettingsSection.About,
    ),

    // ────────────────────────────────────────────────────────────────────────
    // BRAIN-OWNED — hidden from the visible root (developer-only).  Routes are
    // preserved so deep links / Developer Mode still reach the screens, but per
    // docs/SIMPLIFY_ANDROID_UX.md these no longer appear in normal navigation
    // (the Mac brain owns model / persona / memory / conversation behaviour).
    // ────────────────────────────────────────────────────────────────────────

    Conversation(
        title       = "Conversation",
        description = "How Jarvis replies, follow-ups and turn-taking",
        icon        = Icons.Filled.ChatBubbleOutline,
        route       = "settings/conversation",
        section     = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    Messaging(
        title       = "Messaging",
        description = "Notification access, message context and reply settings",
        icon        = Icons.Filled.Forum,
        route       = "settings/messaging",
        section     = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    Advanced(
        title       = "AI Provider",
        description = "Choose the language model that powers responses",
        icon        = Icons.Filled.Tune,
        route       = "settings/advanced",
        section     = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    AmbientIntelligence(
        title       = "Ambient Intelligence",
        description = "When Jarvis notices things on its own and what it does about them",
        icon        = Icons.Filled.AutoAwesome,
        route       = "settings/ambient",
        section     = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    Memory(
        title       = "Memory",
        description = "What Jarvis remembers about you and how long it keeps it",
        icon        = Icons.Filled.Memory,
        route       = "settings/memory",
        section     = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    TrustAutonomy(
        title       = "Trust & Autonomy",
        description = "How much Jarvis can do without asking first",
        icon        = Icons.Filled.VerifiedUser,
        route       = "settings/trust_autonomy",
        section     = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    Vision(
        title       = "Vision",
        description = "Camera, screenshots, OCR and visual memory",
        icon        = Icons.Filled.CameraAlt,
        route       = "settings/vision",
        section     = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),

    // ────────────────────────────────────────────────────────────────────────
    // DEVELOPER ROW (1, only visible in Developer Mode)
    // ────────────────────────────────────────────────────────────────────────

    DeveloperDiagnostics(
        title         = "Developer Diagnostics",
        description   = "Connection, voice, vision, routing, session and latency tools",
        icon          = Icons.Filled.BugReport,
        route         = "settings/developer_diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),

    // ────────────────────────────────────────────────────────────────────────
    // INTERNAL — reached from inside Permissions screen
    // ────────────────────────────────────────────────────────────────────────

    BackgroundLocationDisclosure(
        title         = "Background Location",
        description   = "Why Jarvis needs location access when not in use",
        icon          = Icons.Filled.Place,
        route         = "settings/background_location_disclosure",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),

    // ────────────────────────────────────────────────────────────────────────
    // INTERNAL — reached from inside MacIntegration, not from root
    // ────────────────────────────────────────────────────────────────────────

    HomeAssistant(
        title         = "Smart home",
        description   = "Connect Jarvis to your local Home Assistant instance",
        icon          = Icons.Filled.Home,
        route         = "settings/homeassistant",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    Calendar(
        title         = "Calendar",
        description   = "Calendar awareness and schedule context",
        icon          = Icons.Filled.DateRange,
        route         = "settings/calendar",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    Todoist(
        title         = "Tasks & reminders",
        description   = "Todoist sync for voice-driven task management",
        icon          = Icons.Filled.CheckCircle,
        route         = "settings/todoist",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),

    // ────────────────────────────────────────────────────────────────────────
    // INTERNAL — Voice sub-screens (reached from inside Voice)
    // ────────────────────────────────────────────────────────────────────────

    Phrases(
        title         = "Response Phrases",
        description   = "Customise exactly what Jarvis says for each response type",
        icon          = Icons.Filled.TextFields,
        route         = "settings/phrases",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),

    // ────────────────────────────────────────────────────────────────────────
    // INTERNAL — Vision / Tool sub-screens (reached programmatically)
    // ────────────────────────────────────────────────────────────────────────

    Wearables(
        title         = "Wearables",
        description   = "Meta AI glasses — registration, permissions and diagnostics",
        icon          = Icons.Filled.Visibility,
        route         = "settings/wearables",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    AppControl(
        title         = "App Control",
        description   = "Voice commands to open, close and navigate apps",
        icon          = Icons.Filled.PhoneAndroid,
        route         = "settings/app_control",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    ActionsApps(
        title         = "Actions & Apps",
        description   = "Tools, search and connected apps",
        icon          = Icons.Filled.Shield,
        route         = "settings/actions",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    Routines(
        title         = "Routines",
        description   = "Saved sequences you can run by name",
        icon          = Icons.AutoMirrored.Filled.PlaylistPlay,
        route         = "settings/routines",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    ContactAliases(
        title         = "Contact Aliases",
        description   = "Nicknames like \"wifey\" or \"mum\" that route to a contact",
        icon          = Icons.Filled.Person,
        route         = "settings/contact_aliases",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    SavedLocations(
        title         = "Saved Locations",
        description   = "Home, work and custom addresses for navigation",
        icon          = Icons.Filled.Place,
        route         = "settings/saved_locations",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),

    // ────────────────────────────────────────────────────────────────────────
    // INTERNAL — historical user-facing screens kept reachable in dev mode
    // (Appearance, Personality, Notifications, FAQ, Proactivity hub,
    //  ResponsePreferences).  Their content is reachable from elsewhere or
    //  no longer surfaced; routes preserved to avoid breaking deep links.
    // ────────────────────────────────────────────────────────────────────────

    Appearance(
        title         = "Appearance",
        description   = "Theme and display density",
        icon          = Icons.Filled.Palette,
        route         = "settings/appearance",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    Personality(
        title         = "Personality",
        description   = "Sarcasm, humour, pushback and serious-mode auto-detect",
        icon          = Icons.Filled.EmojiPeople,
        route         = "settings/personality",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    Faq(
        title         = "FAQ & Commands",
        description   = "What Jarvis can do and how to ask",
        icon          = Icons.AutoMirrored.Filled.HelpOutline,
        route         = "settings/faq",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    Proactivity(
        title         = "Proactivity (legacy)",
        description   = "Old proactive coordinator screen — use Ambient Intelligence instead",
        icon          = Icons.Filled.Bolt,
        route         = "settings/proactivity",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    ResponsePreferences(
        title         = "Response Preferences",
        description   = "Teach Jarvis how to format responses by domain",
        icon          = Icons.Filled.FilterList,
        route         = "settings/response_preferences",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),

    // ────────────────────────────────────────────────────────────────────────
    // INTERNAL — per-topic diagnostic screens (reached from inside
    //            DeveloperDiagnostics, never from root).
    // ────────────────────────────────────────────────────────────────────────

    ConnectionDiagnostics(
        title         = "Connection Diagnostics",
        description   = "Raw Gateway, Bridge and Brain connection state, counters and logs",
        icon          = Icons.Filled.BugReport,
        route         = "settings/connection_diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    LocalDiagnostics(
        title         = "Local Diagnostics",
        description   = "Recent local routes and remote-touched audit",
        icon          = Icons.Filled.Bolt,
        route         = "settings/diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    VoiceDiagnostics(
        title         = "Voice Diagnostics",
        description   = "Piper neural voice status and tools",
        icon          = Icons.Filled.GraphicEq,
        route         = "settings/voice_diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    VisionDiagnostics(
        title         = "Vision Diagnostics",
        description   = "Test camera capture, OCR and screenshot analysis",
        icon          = Icons.Filled.BugReport,
        route         = "settings/vision_diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    AppControlDiagnostics(
        title         = "App Control Diagnostics",
        description   = "Recent app context, Maps navigation state, accessibility status",
        icon          = Icons.Filled.BugReport,
        route         = "settings/app_control_diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    SessionDiagnostics(
        title         = "Session Diagnostics",
        description   = "Live session state, active goals, pending slots and context stores",
        icon          = Icons.Filled.BugReport,
        route         = "settings/session_diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    TrustDiagnostics(
        title         = "Trust Diagnostics",
        description   = "Live trust score, autonomy decisions and learned patterns",
        icon          = Icons.Filled.ManageSearch,
        route         = "settings/trust_diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    MacBridgeDiagnostics(
        title         = "Mac Bridge Diagnostics",
        description   = "Live bridge status, last event, reconnect count and permissions",
        icon          = Icons.Filled.BugReport,
        route         = "settings/mac_bridge_diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    MacBrainDiagnostics(
        title         = "Mac Brain Diagnostics",
        description   = "Connection health, memory cache, request counters",
        icon          = Icons.Filled.BugReport,
        route         = "settings/mac_brain_diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    SpeechLatency(
        title         = "Speech Latency",
        description   = "Per-turn pipeline timings — last 20 turns, p50/p95, stage breakdown",
        icon          = Icons.Filled.GraphicEq,
        route         = "settings/speech_latency",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    ExperimentalFlags(
        title         = "Experimental Features",
        description   = "Toggle experimental Jarvis subsystems",
        icon          = Icons.Filled.Science,
        route         = "settings/experimental",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),

    // ────────────────────────────────────────────────────────────────────────
    // INTERNAL — legacy raw-config screens.  Always developer-only.  Routes
    //            preserved so they can still be deep-linked from
    //            DeveloperDiagnostics if a build engineer needs them.
    // ────────────────────────────────────────────────────────────────────────

    BrainGateway(
        title         = "Gateway (Legacy)",
        description   = "Raw Brain Gateway pairing config — use Mac Integration instead",
        icon          = Icons.Filled.Psychology,
        route         = "settings/brain_gateway",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    MacBridge(
        title         = "Mac Bridge (Legacy)",
        description   = "Raw Mac Bridge config — use Mac Integration instead",
        icon          = Icons.Filled.PhoneIphone,
        route         = "settings/mac_bridge",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    MacBrain(
        title         = "Mac Brain (Legacy)",
        description   = "Raw Mac Brain config — use Mac Integration instead",
        icon          = Icons.Filled.Psychology,
        route         = "settings/mac_brain",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
}

internal const val SETTINGS_ROOT_ROUTE = "settings/root"
