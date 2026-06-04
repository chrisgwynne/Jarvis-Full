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
    val context = androidx.compose.ui.platform.LocalContext.current

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
                // #74: no diagnostics link from the Mac connection screen — the
                // Developer Diagnostics hub is gone from the graph; users fix
                // problems via Troubleshooting instead.
                onOpenDiagnostics   = null,
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

        // ── Permissions — one consolidated status screen ──────────────────
        composable(SettingsCategory.Permissions.route) {
            com.jarvis.assistant.ui.settings.screens.PermissionsScreen(
                onBack = popToRoot, onClose = onBack
            )
        }

        // ── Troubleshooting — single calm screen replacing diagnostics ────
        composable(SettingsCategory.Troubleshooting.route) {
            com.jarvis.assistant.ui.settings.screens.TroubleshootingScreen(
                onBack              = popToRoot,
                onClose             = onBack,
                onOpenPermissions   = { settingsNav.navigate(SettingsCategory.Permissions.route) },
                onOpenMacConnection = { settingsNav.navigate(SettingsCategory.MacIntegration.route) },
                onExportBundle      = { shareDiagnosticBundle(context) },   // #71
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

        // #74: per-topic diagnostics, the Developer Diagnostics hub, and the
        // Experimental Flags screen are intentionally NOT registered in the nav
        // graph. They are unreachable from normal navigation and Developer Mode.
        // The instrumentation classes (ListenerDiagnostics, LocalRouteDiagnostics,
        // MacBrainDiagnosticsSnapshot, …) remain compiled and emitting; the
        // Troubleshooting screen surfaces what users actually need.

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

/**
 * #71: build the sanitised diagnostic bundle and hand it to a share sheet via
 * the existing FileProvider. No content/PII — see [DiagnosticBundleBuilder].
 */
private fun shareDiagnosticBundle(context: android.content.Context) {
    runCatching {
        val file = com.jarvis.assistant.diagnostics.DiagnosticBundleBuilder.writeToCache(context)
        val uri = androidx.core.content.FileProvider.getUriForFile(
            context, "${context.packageName}.fileprovider", file
        )
        val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(android.content.Intent.EXTRA_STREAM, uri)
            putExtra(android.content.Intent.EXTRA_SUBJECT, "Jarvis diagnostic bundle")
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(
            android.content.Intent.createChooser(send, "Share diagnostics")
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }.onFailure {
        android.util.Log.w("SettingsScreen", "diagnostic bundle export failed: ${it.message}")
    }
}
