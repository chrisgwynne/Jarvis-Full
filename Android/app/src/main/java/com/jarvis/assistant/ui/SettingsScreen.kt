package com.jarvis.assistant.ui

import androidx.compose.runtime.Composable
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.jarvis.assistant.ui.settings.SETTINGS_ROOT_ROUTE
import com.jarvis.assistant.ui.settings.SettingsCategory
import com.jarvis.assistant.ui.settings.SettingsRootScreen
import com.jarvis.assistant.ui.settings.screens.ActionsAppsSettingsScreen
import com.jarvis.assistant.ui.settings.screens.AdvancedSettingsScreen
import com.jarvis.assistant.ui.settings.screens.AppearanceSettingsScreen
import com.jarvis.assistant.ui.settings.screens.ConversationSettingsScreen
import com.jarvis.assistant.ui.settings.screens.FaqSettingsScreen
import com.jarvis.assistant.ui.settings.screens.HomeAssistantSettingsScreen
import com.jarvis.assistant.ui.settings.screens.MemorySettingsScreen
import com.jarvis.assistant.ui.settings.screens.NotificationsSettingsScreen
import com.jarvis.assistant.ui.settings.screens.PersonalitySettingsScreen
import com.jarvis.assistant.ui.settings.screens.ProactivitySettingsScreen
import com.jarvis.assistant.ui.settings.screens.VoiceSettingsScreen
import com.jarvis.assistant.ui.settings.screens.WearablesSettingsScreen

/**
 * Settings entry point.
 *
 * Hosts a nested NavController so the settings flow (root → category) is
 * self-contained:
 *  - Back from a sub-screen pops inside the settings NavHost and returns to
 *    the root category list.
 *  - Close (X) from any screen calls [onBack], which exits the whole
 *    settings flow by popping the outer app-level NavController.
 *
 * The NavHost contains every registered [SettingsCategory] route.  Whether
 * a route is reachable from the home screen is controlled separately by
 * [SettingsCategory.developerOnly]; routes for hidden categories remain
 * declared here so deep links and programmatic navigation continue to work.
 *
 * The hub screens that previously absorbed Conversation / Messaging
 * (PhoneControl), Vision (CameraVision), Memory & Trust (Privacy) and
 * Ambient Intelligence (Proactivity) have been removed in favour of
 * surfacing those categories directly at the root.
 */
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    vm: SettingsViewModel = viewModel(),
) {
    val settingsNav = rememberNavController()
    val popToRoot: () -> Unit = { settingsNav.popBackStack() }

    NavHost(
        navController = settingsNav,
        startDestination = SETTINGS_ROOT_ROUTE,
    ) {
        composable(SETTINGS_ROOT_ROUTE) {
            SettingsRootScreen(
                onOpenCategory = { category -> settingsNav.navigate(category.route) },
                onClose        = onBack,
                vm             = vm,
            )
        }

        // ── User-facing top-level destinations ────────────────────────────
        composable(SettingsCategory.Voice.route) {
            VoiceSettingsScreen(vm = vm, onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.Conversation.route) {
            ConversationSettingsScreen(vm = vm, onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.Messaging.route) {
            com.jarvis.assistant.ui.settings.screens.MessagingDiagnosticsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.Advanced.route) {
            AdvancedSettingsScreen(vm = vm, onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.AmbientIntelligence.route) {
            com.jarvis.assistant.ui.settings.screens.AmbientIntelligenceSettingsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.Memory.route) {
            MemorySettingsScreen(vm = vm, onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.TrustAutonomy.route) {
            com.jarvis.assistant.ui.settings.screens.TrustAutonomySettingsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.Vision.route) {
            com.jarvis.assistant.ui.settings.screens.VisionSettingsScreen(
                vm = vm, onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.MacIntegration.route) {
            com.jarvis.assistant.ui.settings.screens.MacIntegrationScreen(
                vm                  = vm,
                onBack              = popToRoot,
                onClose             = onBack,
                onOpenDiagnostics   = { settingsNav.navigate(SettingsCategory.DeveloperDiagnostics.route) },
                onOpenHomeAssistant = { settingsNav.navigate(SettingsCategory.HomeAssistant.route) },
                onOpenCalendar      = { settingsNav.navigate(SettingsCategory.Calendar.route) },
                onOpenTodoist       = { settingsNav.navigate(SettingsCategory.Todoist.route) },
            )
        }
        composable(SettingsCategory.AboutHelp.route) {
            com.jarvis.assistant.ui.settings.screens.AboutHelpSettingsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }

        // ── Developer Diagnostics (consolidated, dev-only entry point) ────
        composable(SettingsCategory.DeveloperDiagnostics.route) {
            com.jarvis.assistant.ui.settings.screens.DeveloperDiagnosticsScreen(
                onBack          = popToRoot,
                onClose         = onBack,
                onOpenCategory  = { settingsNav.navigate(it.route) },
            )
        }

        // ── Mac Integration sub-screens ───────────────────────────────────
        composable(SettingsCategory.HomeAssistant.route) {
            HomeAssistantSettingsScreen(vm = vm, onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.Calendar.route) {
            com.jarvis.assistant.ui.settings.screens.CalendarSettingsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.Todoist.route) {
            com.jarvis.assistant.ui.settings.screens.TodoistSettingsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }

        // ── Tool / sub-screens reachable via deep link or sub-navigation ──
        composable(SettingsCategory.Wearables.route) {
            WearablesSettingsScreen(onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.AppControl.route) {
            com.jarvis.assistant.ui.settings.screens.AppControlSettingsScreen(
                vm = vm, onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.ActionsApps.route) {
            ActionsAppsSettingsScreen(vm = vm, onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.SavedLocations.route) {
            com.jarvis.assistant.ui.settings.screens.SavedLocationsSettingsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.ContactAliases.route) {
            com.jarvis.assistant.ui.settings.screens.ContactAliasesSettingsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.Routines.route) {
            com.jarvis.assistant.ui.settings.screens.RoutinesSettingsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }

        // ── Historical user-facing screens, now developer-only ────────────
        composable(SettingsCategory.Appearance.route) {
            AppearanceSettingsScreen(vm = vm, onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.Personality.route) {
            PersonalitySettingsScreen(onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.Notifications.route) {
            NotificationsSettingsScreen(onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.Faq.route) {
            FaqSettingsScreen(onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.Proactivity.route) {
            ProactivitySettingsScreen(onBack = popToRoot, onClose = onBack)
        }
        composable(SettingsCategory.ResponsePreferences.route) {
            com.jarvis.assistant.ui.settings.screens.ResponsePreferencesSettingsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.Phrases.route) {
            com.jarvis.assistant.phrases.ui.PhrasesSettingsScreen(
                onBack = popToRoot,
            )
        }

        // ── Per-topic diagnostic screens (reached from
        //    DeveloperDiagnostics, never from the root) ────────────────────
        composable(SettingsCategory.ConnectionDiagnostics.route) {
            com.jarvis.assistant.ui.settings.screens.ConnectionDiagnosticsScreen(
                vm = vm, onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.LocalDiagnostics.route) {
            com.jarvis.assistant.ui.settings.screens.LocalDiagnosticsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.VoiceDiagnostics.route) {
            com.jarvis.assistant.ui.settings.screens.VoiceDiagnosticsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.VisionDiagnostics.route) {
            com.jarvis.assistant.ui.settings.screens.VisionDiagnosticsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.AppControlDiagnostics.route) {
            com.jarvis.assistant.ui.settings.screens.AppControlDiagnosticsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.SessionDiagnostics.route) {
            com.jarvis.assistant.ui.settings.screens.SessionDiagnosticsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.TrustDiagnostics.route) {
            com.jarvis.assistant.ui.settings.screens.TrustDiagnosticsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.MacBrainDiagnostics.route) {
            com.jarvis.assistant.ui.settings.screens.MacBrainDiagnosticsScreen(
                vm = vm, onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.SpeechLatency.route) {
            com.jarvis.assistant.ui.settings.screens.SpeechLatencyScreen(
                onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.ExperimentalFlags.route) {
            com.jarvis.assistant.ui.settings.screens.ExperimentalFlagsSettingsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }

        // ── Legacy raw-config screens (removed — route stubs kept for deep-link compat) ─────────
        composable(SettingsCategory.BrainGateway.route) {
            // Removed — redirects to Mac Integration
            com.jarvis.assistant.ui.settings.screens.MacIntegrationScreen(
                vm = vm, onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.MacBridge.route) {
            // Removed — redirects to Mac Integration
            com.jarvis.assistant.ui.settings.screens.MacIntegrationScreen(
                vm = vm, onBack = popToRoot, onClose = onBack
            )
        }
        composable(SettingsCategory.MacBrain.route) {
            // Removed — redirects to Mac Integration
            com.jarvis.assistant.ui.settings.screens.MacIntegrationScreen(
                vm = vm, onBack = popToRoot, onClose = onBack
            )
        }
    }
}
