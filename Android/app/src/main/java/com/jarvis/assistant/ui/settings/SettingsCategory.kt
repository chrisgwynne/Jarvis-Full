package com.jarvis.assistant.ui.settings

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.BugReport
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
 * ## Adding a new category
 *
 *   1. Add an entry here with [title], [description], [icon], [route],
 *      [section], and optionally [developerOnly].
 *   2. Add a `composable(route)` case in [SettingsScreen]'s NavHost.
 *   3. Create the screen composable in
 *      `com.jarvis.assistant.ui.settings.screens`.
 *
 * ## Developer-only categories
 *
 * Set [developerOnly] = true for any diagnostic / engineering screen, or for
 * any screen whose content has been absorbed into a unified hub screen.
 * These entries are hidden from the settings home when Developer Mode is off.
 * Their routes still exist in the NavHost so deep-links from debug tooling
 * and programmatic navigation from hub screens work regardless.
 *
 * ## Sprint 4 — Route Consolidation
 *
 * The following screens are now absorbed into unified hub screens and demoted
 * to developerOnly so normal users see only the hub:
 *
 *  - Conversation, AppControl, ActionsApps, Messaging → PhoneControl
 *  - Vision                                           → CameraVision
 *  - AmbientIntelligence                              → Proactivity
 *  - Memory, TrustAutonomy                            → Privacy
 *
 * Sub-screens navigated from hub screens (Routines, ContactAliases,
 * SavedLocations, Wearables) are also developerOnly but their routes remain
 * for direct programmatic navigation.
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

    // ── Voice & Listening ─────────────────────────────────────────────────────

    Voice(
        title       = "Voice & Wake",
        description = "Wake word, speech recognition, TTS voice, interrupt detection and audio routing",
        icon        = Icons.Filled.RecordVoiceOver,
        route       = "settings/voice",
        section     = SettingsSection.VoiceListening,
    ),
    Phrases(
        title       = "Response Phrases",
        description = "Customise exactly what Jarvis says for each response type",
        icon        = Icons.Filled.TextFields,
        route       = "settings/phrases",
        section     = SettingsSection.VoiceListening,
    ),
    Faq(
        title       = "FAQ & Commands",
        description = "What Jarvis can do and how to ask",
        icon        = Icons.AutoMirrored.Filled.HelpOutline,
        route       = "settings/faq",
        section     = SettingsSection.VoiceListening,
    ),

    // ── Notifications & Proactivity ───────────────────────────────────────────

    Proactivity(
        title       = "Proactivity",
        description = "When Jarvis speaks up on its own, routine learning and ambient intelligence",
        icon        = Icons.Filled.Bolt,
        route       = "settings/proactivity",
        section     = SettingsSection.NotificationsProactivity,
    ),
    Notifications(
        title       = "Notifications",
        description = "Alerts and status messages",
        icon        = Icons.Filled.NotificationsNone,
        route       = "settings/notifications",
        section     = SettingsSection.NotificationsProactivity,
    ),

    // ── Phone Control ─────────────────────────────────────────────────────────

    /** Hub screen — absorbs Conversation, AppControl, ActionsApps, Messaging. */
    PhoneControl(
        title       = "Phone Control",
        description = "Messaging, app control, saved contacts, locations and voice routines",
        icon        = Icons.Filled.PhoneAndroid,
        route       = "settings/phone_control",
        section     = SettingsSection.AppsActions,
    ),
    /** Hub screen — absorbs Vision; links to Wearables for SDK diagnostics. */
    CameraVision(
        title       = "Camera & Vision",
        description = "Camera, screenshots, visual memory and Meta glasses",
        icon        = Icons.Filled.CameraAlt,
        route       = "settings/camera_vision",
        section     = SettingsSection.AppsActions,
    ),

    // sub-screens navigated programmatically from PhoneControl
    AppControl(
        title         = "App Control",
        description   = "Voice commands to open, close and navigate apps",
        icon          = Icons.Filled.PhoneAndroid,
        route         = "settings/app_control",
        section       = SettingsSection.AppsActions,
        developerOnly = true,
    ),
    ActionsApps(
        title         = "Actions & Apps",
        description   = "Tools, search and connected apps",
        icon          = Icons.Filled.Shield,
        route         = "settings/actions",
        section       = SettingsSection.AppsActions,
        developerOnly = true,
    ),
    Routines(
        title         = "Routines",
        description   = "Saved sequences you can run by name",
        icon          = Icons.AutoMirrored.Filled.PlaylistPlay,
        route         = "settings/routines",
        section       = SettingsSection.AppsActions,
        developerOnly = true,
    ),
    ContactAliases(
        title         = "Contact Aliases",
        description   = "Nicknames like \"wifey\" or \"mum\" that route to a contact",
        icon          = Icons.Filled.Person,
        route         = "settings/contact_aliases",
        section       = SettingsSection.AppsActions,
        developerOnly = true,
    ),
    SavedLocations(
        title         = "Saved Locations",
        description   = "Home, work and custom addresses for navigation",
        icon          = Icons.Filled.Place,
        route         = "settings/saved_locations",
        section       = SettingsSection.AppsActions,
        developerOnly = true,
    ),
    // sub-screen navigated programmatically from CameraVision
    Wearables(
        title         = "Wearables",
        description   = "Meta AI glasses — registration, permissions and diagnostics",
        icon          = Icons.Filled.Visibility,
        route         = "settings/wearables",
        section       = SettingsSection.AppsActions,
        developerOnly = true,
    ),

    // ── Appearance ────────────────────────────────────────────────────────────

    Appearance(
        title       = "Appearance",
        description = "Theme and display density",
        icon        = Icons.Filled.Palette,
        route       = "settings/appearance",
        section     = SettingsSection.Appearance,
    ),
    Personality(
        title       = "Personality",
        description = "Sarcasm, humour, pushback and serious-mode auto-detect",
        icon        = Icons.Filled.EmojiPeople,
        route       = "settings/personality",
        section     = SettingsSection.Appearance,
    ),

    // ── Mac Integration ───────────────────────────────────────────────────────

    MacIntegration(
        title       = "Mac Integration",
        description = "Connect to Mac Jarvis for memory, context and commands",
        icon        = Icons.Filled.Psychology,
        route       = "settings/mac_integration",
        section     = SettingsSection.MacIntegration,
    ),

    // ── Connected services (navigated from MacIntegrationScreen) ─────────────
    // Hidden from root; accessible via the Mac Integration hub and in dev mode.

    HomeAssistant(
        title         = "Smart home",
        description   = "Connect Jarvis to your local Home Assistant instance",
        icon          = Icons.Filled.Home,
        route         = "settings/homeassistant",
        section       = SettingsSection.MacIntegration,
        developerOnly = true,
    ),
    Calendar(
        title         = "Calendar",
        description   = "Calendar awareness and schedule context",
        icon          = Icons.Filled.DateRange,
        route         = "settings/calendar",
        section       = SettingsSection.MacIntegration,
        developerOnly = true,
    ),
    Todoist(
        title         = "Tasks & reminders",
        description   = "Todoist sync for voice-driven task management",
        icon          = Icons.Filled.CheckCircle,
        route         = "settings/todoist",
        section       = SettingsSection.MacIntegration,
        developerOnly = true,
    ),

    // ── Privacy & Data ────────────────────────────────────────────────────────

    Privacy(
        title       = "Privacy & Data",
        description = "Permissions, accounts, memory, autonomy settings and data controls",
        icon        = Icons.Filled.Security,
        route       = "settings/privacy",
        section     = SettingsSection.PrivacyData,
    ),
    ResponsePreferences(
        title       = "Response Preferences",
        description = "Teach Jarvis how to format responses by domain",
        icon        = Icons.Filled.FilterList,
        route       = "settings/response_preferences",
        section     = SettingsSection.PrivacyData,
    ),

    // ── System & Diagnostics ──────────────────────────────────────────────────
    // All developerOnly = true.
    // Absorbed screens are preserved here so their routes remain reachable
    // via developer mode and programmatic navigation.

    Advanced(
        title         = "AI Provider",
        description   = "LLM provider, access key and remote backend",
        icon          = Icons.Filled.Tune,
        route         = "settings/advanced",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    ConnectionDiagnostics(
        title         = "Connection Diagnostics",
        description   = "Raw Gateway, Bridge and Brain connection state, counters and logs",
        icon          = Icons.Filled.BugReport,
        route         = "settings/connection_diagnostics",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    LocalDiagnostics(
        title         = "Diagnostics",
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
    ExperimentalFlags(
        title         = "Experimental Features",
        description   = "Toggle experimental Jarvis subsystems",
        icon          = Icons.Filled.Science,
        route         = "settings/experimental",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),

    // ── Legacy Mac connection screens ─────────────────────────────────────────

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

    // ── Absorbed screens (preserved routes, developer-only) ───────────────────
    // These screens have been merged into hub screens for normal users.
    // They remain navigable in developer mode and via programmatic navigation.

    /** Absorbed into PhoneControl. */
    Conversation(
        title         = "Conversation",
        description   = "How Jarvis replies and routes messages",
        icon          = Icons.Filled.ChatBubbleOutline,
        route         = "settings/conversation",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    /** Absorbed into PhoneControl. */
    Messaging(
        title         = "Messaging",
        description   = "Notification access, message context and reply settings",
        icon          = Icons.Filled.Forum,
        route         = "settings/messaging",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    /** Absorbed into CameraVision. */
    Vision(
        title         = "Vision",
        description   = "Camera, screenshots, OCR and visual memory",
        icon          = Icons.Filled.CameraAlt,
        route         = "settings/vision",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    /** Absorbed into Proactivity. */
    AmbientIntelligence(
        title         = "Ambient Intelligence",
        description   = "Local signal learning, routine nudges and context awareness",
        icon          = Icons.Filled.AutoAwesome,
        route         = "settings/ambient",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    /** Absorbed into Privacy. */
    Memory(
        title         = "Memory",
        description   = "Speaker profiles and stored history",
        icon          = Icons.Filled.Memory,
        route         = "settings/memory",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
    /** Absorbed into Privacy. */
    TrustAutonomy(
        title         = "Trust & Autonomy",
        description   = "How Jarvis decides what to do without asking",
        icon          = Icons.Filled.VerifiedUser,
        route         = "settings/trust_autonomy",
        section       = SettingsSection.SystemDiagnostics,
        developerOnly = true,
    ),
}

internal const val SETTINGS_ROOT_ROUTE = "settings/root"
