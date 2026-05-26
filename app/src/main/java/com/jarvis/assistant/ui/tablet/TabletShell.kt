package com.jarvis.assistant.ui.tablet

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.jarvis.assistant.ui.SettingsScreen
import kotlinx.coroutines.launch

// ── Palette ───────────────────────────────────────────────────────────────────

private val ShellBg   = Color(0xFF060B14)   // deepest navy
private val RailBg    = Color(0xFF08111F)   // nav rail surface
private val DivColor  = Color(0xFF0E1C33)   // barely-visible divider
private val CyanSel   = Color(0xFF3FA7FF)   // blueprint blue — selected item
private val GrayUnsel = Color(0xFF4A6080)   // blueprint faint — unselected item

// ── Rail item descriptor ──────────────────────────────────────────────────────

private data class RailItem(
    val dest  : TabletDestination,
    val icon  : ImageVector,
)

private val RAIL_ITEMS = listOf(
    RailItem(TabletDestination.Assistant,   Icons.Filled.Mic),
    RailItem(TabletDestination.Files,       Icons.Filled.Folder),
    RailItem(TabletDestination.Messages,    Icons.Filled.Message),
    RailItem(TabletDestination.Email,       Icons.Filled.Email),
    RailItem(TabletDestination.Apps,        Icons.Filled.Apps),
    RailItem(TabletDestination.Home,        Icons.Filled.Home),
    RailItem(TabletDestination.Calendar,    Icons.Filled.CalendarToday),
    RailItem(TabletDestination.Settings,    Icons.Filled.Settings),
    RailItem(TabletDestination.Diagnostics, Icons.Filled.BugReport),
)

// ── Entry point ───────────────────────────────────────────────────────────────

/**
 * TabletNavHost — tablet entry point, symmetric to the phone's AppNavHost.
 *
 * Layout (left → right):
 *   [NavigationRail ~80dp] | [AssistantSidebar 35%] | [DetailPane 65%]
 *
 * The AssistantSidebar is always visible regardless of which destination is
 * active; the DetailPane swaps content based on navigation rail selection.
 * All existing Jarvis services are consumed through [TabletViewModel] without
 * any new business logic.
 */
@Composable
fun TabletNavHost(vm: TabletViewModel = viewModel()) {
    val dest by vm.destination.collectAsState()

    // ── Bridge lifecycle ──────────────────────────────────────────────────────
    // Attach TabletContextBridge when the tablet shell enters the Composition
    // so it begins observing DeviceStateStore + LocalRouteDiagnostics.
    // Detached in onDispose to cancel coroutines and clear the dispatch listener.
    DisposableEffect(Unit) {
        TabletContextBridge.attach()
        onDispose { TabletContextBridge.detach() }
    }

    // ── Voice navigation side-effects ─────────────────────────────────────────
    // When a voice tool posts a TabletEmailVoiceIntent with navigateTo set,
    // navigate to that destination (e.g. open Email panel after "email this file").
    LaunchedEffect(Unit) {
        TabletEmailCommandStore.commands.collect { intent ->
            intent.navigateTo?.let { dest -> vm.navigate(dest) }
        }
    }

    Row(
        modifier = Modifier
            .fillMaxSize()
            .background(ShellBg),
    ) {
        // ── Navigation rail ──────────────────────────────────────────────────
        NavigationRail(
            modifier       = Modifier.fillMaxHeight(),
            containerColor = RailBg,
        ) {
            Spacer(Modifier.weight(0.3f))
            RAIL_ITEMS.forEach { item ->
                NavigationRailItem(
                    selected = dest == item.dest,
                    onClick  = { vm.navigate(item.dest) },
                    icon     = {
                        Icon(
                            imageVector        = item.icon,
                            contentDescription = item.dest.label,
                        )
                    },
                    label  = {
                        Text(
                            text  = item.dest.label,
                            style = MaterialTheme.typography.labelSmall,
                        )
                    },
                    colors = NavigationRailItemDefaults.colors(
                        selectedIconColor   = CyanSel,
                        selectedTextColor   = CyanSel,
                        indicatorColor      = CyanSel.copy(alpha = 0.14f),
                        unselectedIconColor = GrayUnsel,
                        unselectedTextColor = GrayUnsel,
                    ),
                )
            }
            Spacer(Modifier.weight(0.7f))
        }

        // ── Rail → sidebar divider ────────────────────────────────────────────
        VerticalDivLine()

        // ── Assistant sidebar — always visible ───────────────────────────────
        Box(
            modifier = Modifier
                .fillMaxHeight()
                .weight(0.35f),
        ) {
            TabletAssistantPanel(vm = vm)
        }

        // ── Sidebar → detail divider ──────────────────────────────────────────
        VerticalDivLine()

        // ── Detail pane — changes with rail selection ─────────────────────────
        Box(
            modifier = Modifier
                .fillMaxHeight()
                .weight(0.65f),
        ) {
            when (dest) {
                TabletDestination.Assistant ->
                    TabletAssistantDetailPanel(vm = vm)

                TabletDestination.Files ->
                    TabletFileTrayPanel(vm = vm)

                TabletDestination.Messages ->
                    TabletMessagesPanel(vm = vm)

                TabletDestination.Email ->
                    TabletEmailPanel(vm = vm)

                TabletDestination.Apps ->
                    TabletAppControlPanel(vm = vm)

                TabletDestination.Home ->
                    TabletHomeAssistantPanel(vm = vm)

                TabletDestination.Calendar ->
                    TabletCalendarPanel(vm = vm)

                TabletDestination.Settings ->
                    SettingsScreen(
                        onBack = { vm.navigate(TabletDestination.Assistant) },
                    )

                TabletDestination.Diagnostics ->
                    TabletDiagnosticsPanel(vm = vm)
            }
        }
    }
}

// ── Helper ────────────────────────────────────────────────────────────────────

@Composable
private fun VerticalDivLine() {
    Box(
        modifier = Modifier
            .fillMaxHeight()
            .width(1.dp)
            .background(DivColor),
    )
}
