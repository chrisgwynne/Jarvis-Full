package com.jarvis.assistant.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import com.jarvis.assistant.ui.SettingsViewModel

/**
 * Settings home screen — the new premium entry point for all settings.
 *
 * ## Layout
 *
 *  - Search bar — filters across all categories instantly.
 *  - 5 user-visible sections (Voice & Listening → Privacy & Data) shown as grouped cards.
 *  - System & Diagnostics section shown only when Developer Mode is on.
 *  - Developer Mode toggle at the bottom — tap 3 × to unlock is avoided;
 *    it's a plain toggle but lives below the fold so normal users don't see it.
 *
 * ## Status badges
 *
 *  Key connection categories show a coloured badge ("Connected" / "Not set")
 *  so the user can immediately see which services need attention.
 *
 * ## Migration
 *
 * Replaces the previous flat 33-item [SettingsCategory] list.  All routes
 * are preserved; no existing screen was removed.  Categories were grouped
 * into [SettingsSection]s — see [SettingsCategory.section].
 */
@Composable
internal fun SettingsRootScreen(
    onOpenCategory: (SettingsCategory) -> Unit,
    onClose: () -> Unit,
    vm: SettingsViewModel = viewModel(),
) {
    val context        = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val devMode        by vm.developerModeEnabled.collectAsState()
    val llmProvider    by vm.llmProvider.collectAsState()
    var searchQuery    by remember { mutableStateOf("") }

    // Runtime permission checks for the SystemHealthCard — re-evaluated on resume
    // so the dots update after the user grants/revokes in system settings.
    var accessibilityOk by remember { mutableStateOf(PermissionUtils.isAccessibilityServiceEnabled(context)) }
    var overlayOk       by remember { mutableStateOf(PermissionUtils.canDrawOverlays(context)) }
    var micOk           by remember { mutableStateOf(PermissionUtils.isMicrophoneGranted(context)) }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                accessibilityOk = PermissionUtils.isAccessibilityServiceEnabled(context)
                overlayOk       = PermissionUtils.canDrawOverlays(context)
                micOk           = PermissionUtils.isMicrophoneGranted(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val systemHealth = remember(accessibilityOk, overlayOk, micOk, llmProvider) {
        buildSystemHealth(
            micOk            = micOk,
            accessibilityOk  = accessibilityOk,
            overlayOk        = overlayOk,
            macIntegrationOk = vm.macBrainConfigured,
            haOk             = vm.haConfigured,
            proactiveOn      = vm.proactivityEnabled,
        )
    }

    // Build the visible category list based on dev mode.
    //
    // Normal mode: only the 10 user-facing categories (developerOnly = false).
    // Dev mode:    those 10 plus the consolidated DeveloperDiagnostics entry.
    //              Per-topic diagnostic screens and legacy raw-config screens
    //              are reached from inside DeveloperDiagnostics, NOT from the
    //              home — surfacing them all here is the cluttered behaviour
    //              the Settings cleanup explicitly removed.
    val visibleCategories = remember(devMode) {
        SettingsCategory.entries.filter { cat ->
            !cat.developerOnly || (devMode && cat == SettingsCategory.DeveloperDiagnostics)
        }
    }

    // Search: flat filtered list when a query is active
    val filteredCategories = remember(searchQuery, visibleCategories) {
        if (searchQuery.isBlank()) emptyList()
        else {
            val q = searchQuery.trim().lowercase()
            visibleCategories.filter {
                it.title.lowercase().contains(q) ||
                    it.description.lowercase().contains(q) ||
                    it.section.title.lowercase().contains(q)
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(SettingsTheme.BgDark)
            .statusBarsPadding(),
    ) {
        // ── Top bar ────────────────────────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Spacer(Modifier.weight(1f))
            Text(
                text = "Settings",
                color = SettingsTheme.TextPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onClose) {
                Icon(Icons.Filled.Close, contentDescription = "Close settings", tint = SettingsTheme.TextMuted)
            }
        }

        HorizontalDivider(color = SettingsTheme.Divider, thickness = 1.dp)

        // ── Scrollable body ────────────────────────────────────────────────
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // Search bar
            SettingsSearchBar(query = searchQuery, onQueryChange = { searchQuery = it })

            // System Health card — only on the home view, hidden during search
            if (searchQuery.isBlank()) {
                SystemHealthCard(items = systemHealth)
            }

            if (searchQuery.isBlank()) {
                // ── Sectioned home view ────────────────────────────────────
                SettingsSection.entries.forEach { section ->
                    if (section == SettingsSection.SystemDiagnostics && !devMode) return@forEach

                    val items = visibleCategories.filter { it.section == section }
                    if (items.isEmpty()) return@forEach

                    // Visual separator before Developer & Diagnostics
                    if (section == SettingsSection.SystemDiagnostics) {
                        HorizontalDivider(
                            color     = SettingsTheme.Border,
                            thickness = 1.dp,
                        )
                        Spacer(Modifier.height(4.dp))
                    }

                    // Header and its group are coupled tightly (8 dp) —
                    // the outer spacedBy(20.dp) creates the inter-section gap.
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SettingsSectionHeader(icon = section.icon, title = section.title)

                        SettingsGroup {
                            items.forEachIndexed { index, category ->
                                val badge = statusBadgeFor(
                                    category    = category,
                                    vm          = vm,
                                    llmProvider = llmProvider,
                                )
                                SettingsCategoryRowWithBadge(
                                    icon        = category.icon,
                                    title       = category.title,
                                    description = category.description,
                                    badge       = badge,
                                    onClick     = { onOpenCategory(category) },
                                )
                                if (index < items.lastIndex) SettingsRowDivider()
                            }
                        }
                    }
                }

                // ── Developer mode toggle ──────────────────────────────────
                Spacer(Modifier.height(8.dp))
                DeveloperModeToggle(enabled = devMode, onToggle = { vm.setDeveloperMode(it) })

            } else {
                // ── Search results ─────────────────────────────────────────
                if (filteredCategories.isEmpty()) {
                    SettingsInfoCard(body = "No settings match \"$searchQuery\".")
                } else {
                    SettingsGroup {
                        filteredCategories.forEachIndexed { index, category ->
                            SettingsCategoryRowWithBadge(
                                icon        = category.icon,
                                title       = category.title,
                                description = "${category.section.title} · ${category.description}",
                                onClick     = { onOpenCategory(category) },
                            )
                            if (index < filteredCategories.lastIndex) SettingsRowDivider()
                        }
                    }
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Returns a (label, level) badge pair for categories that have connection state. */
@Composable
private fun statusBadgeFor(
    category: SettingsCategory,
    vm: SettingsViewModel,
    llmProvider: String,
): Pair<String, SettingsStatusLevel>? = when (category) {
    SettingsCategory.Advanced -> Pair(llmProvider.ifBlank { "Not set" }, SettingsStatusLevel.OK)
    SettingsCategory.MacIntegration -> if (vm.macBrainConfigured)
        Pair("Configured", SettingsStatusLevel.OK)
    else
        Pair("Not set", SettingsStatusLevel.NONE)
    SettingsCategory.HomeAssistant -> if (vm.haConfigured)
        Pair("Configured", SettingsStatusLevel.OK)
    else
        Pair("Not set", SettingsStatusLevel.NONE)
    else -> null
}

/** Builds the [SystemHealthItem] list from current runtime + stored state. */
private fun buildSystemHealth(
    micOk: Boolean,
    accessibilityOk: Boolean,
    overlayOk: Boolean,
    macIntegrationOk: Boolean,
    haOk: Boolean,
    proactiveOn: Boolean,
): List<SystemHealthItem> {
    fun item(label: String, ok: Boolean, okLabel: String, nokLabel: String, required: Boolean): SystemHealthItem {
        val status = when {
            ok       -> SystemHealthStatus.OK
            required -> SystemHealthStatus.WARN
            else     -> SystemHealthStatus.INACTIVE
        }
        return SystemHealthItem(label = label, status = status, statusLabel = if (ok) okLabel else nokLabel)
    }
    return listOf(
        item("Voice",            ok = micOk,             okLabel = "Ready",       nokLabel = "Mic denied",   required = true),
        item("Accessibility",    ok = accessibilityOk,   okLabel = "Enabled",     nokLabel = "Not enabled",  required = true),
        item("Overlay",          ok = overlayOk,         okLabel = "Granted",     nokLabel = "Not granted",  required = true),
        item("Mac Integration",  ok = macIntegrationOk,  okLabel = "Configured",  nokLabel = "Not set",      required = false),
        item("Home Assistant",   ok = haOk,              okLabel = "Configured",  nokLabel = "Not set",      required = false),
        item("Proactivity",      ok = proactiveOn,       okLabel = "On",          nokLabel = "Off",          required = false),
    )
}

/** Dev mode toggle — shown at the very bottom of the home screen. */
@Composable
private fun DeveloperModeToggle(enabled: Boolean, onToggle: (Boolean) -> Unit) {
    SettingsGroup(
        title  = "Advanced",
        footer = if (enabled)
            "Developer mode on — diagnostics and experimental controls are visible."
        else
            "Enable to access diagnostic tools and experimental features.",
    ) {
        SettingsToggleRow(
            title       = "Developer Mode",
            description = "Show diagnostics, routing traces and experimental flags",
            checked     = enabled,
            onCheckedChange = onToggle,
        )
    }
}
