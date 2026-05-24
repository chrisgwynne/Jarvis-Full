package com.jarvis.assistant.ui.settings.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsPrimaryButton
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTextFieldRow
import com.jarvis.assistant.ui.settings.SettingsTheme
import com.jarvis.assistant.ui.settings.SettingsToggleRow
import com.jarvis.assistant.ui.settings.SettingsValueRow

@Composable
internal fun MacBrainSettingsScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
    onOpenDiagnostics: (() -> Unit)? = null,
) {
    val enabled          by vm.macBrainEnabled.collectAsStateWithLifecycle()
    val baseUrl          by vm.macBrainBaseUrl.collectAsStateWithLifecycle()
    val wifiOnly         by vm.macBrainWifiOnly.collectAsStateWithLifecycle()
    val allowMemory      by vm.macBrainAllowMemory.collectAsStateWithLifecycle()
    val allowProject     by vm.macBrainAllowProject.collectAsStateWithLifecycle()
    val allowPreferences by vm.macBrainAllowPreferences.collectAsStateWithLifecycle()
    val testStatus       by vm.macBrainTestStatus.collectAsStateWithLifecycle()
    val urlError         by vm.macBrainUrlError.collectAsStateWithLifecycle()
    val diag             by vm.brainDiagnostics.collectAsStateWithLifecycle()

    SettingsScaffold(title = "Mac Brain", onBack = onBack, onClose = onClose) {

        // ── Status card ───────────────────────────────────────────────────────
        val (statusTitle, statusBody) = when {
            !enabled ->
                "Disabled" to "Mac Brain is off. Enable below to allow context enrichment."
            baseUrl.isBlank() ->
                "Not configured" to "Set the server address to connect."
            diag.lastHealthOk == true ->
                "Connected" to "Last health check passed at ${diag.lastHealthLatencyMs}ms."
            diag.lastHealthOk == false ->
                "Unreachable" to "Last health check failed. Verify the server address."
            else ->
                "Configured" to "Test the connection to verify reachability."
        }
        val (accent, bg) = when {
            !enabled || baseUrl.isBlank() ->
                SettingsTheme.TextMuted to SettingsTheme.InfoBg
            diag.lastHealthOk == true ->
                SettingsTheme.Success to SettingsTheme.SuccessBg
            diag.lastHealthOk == false ->
                SettingsTheme.Destructive to SettingsTheme.InfoBg
            else ->
                SettingsTheme.Cyan to SettingsTheme.InfoBg
        }
        SettingsInfoCard(title = statusTitle, body = statusBody, accent = accent, background = bg)
        Spacer(Modifier.height(8.dp))

        // ── Master enable toggle ──────────────────────────────────────────────
        SettingsGroup {
            SettingsToggleRow(
                title           = "Enable Mac Brain",
                description     = "Allow Jarvis to fetch long-term context for memory, project and " +
                                  "preference queries. Off by default.",
                checked         = enabled,
                onCheckedChange = vm::setMacBrainEnabled,
            )
        }

        if (enabled) {
            Spacer(Modifier.height(8.dp))

            // ── Connection ────────────────────────────────────────────────────
            SettingsGroup(
                title  = "Connection",
                footer = "Server address of your Mac Brain service, e.g. http://192.168.1.100:7474",
            ) {
                SettingsTextFieldRow(
                    title         = "Server address",
                    value         = baseUrl,
                    onValueChange = vm::setMacBrainBaseUrl,
                    placeholder   = "http://192.168.1.100:7474",
                )
                if (!urlError.isNullOrBlank()) {
                    Text(
                        urlError ?: "",
                        color    = SettingsTheme.Destructive,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
                    )
                }
            }
            Spacer(Modifier.height(4.dp))

            // ── Test connection ────────────────────────────────────────────────
            SettingsGroup {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(
                        modifier             = Modifier.fillMaxWidth(),
                        verticalAlignment    = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            "Connection status",
                            color      = SettingsTheme.TextPrimary,
                            fontSize   = 14.sp,
                            fontWeight = FontWeight.Medium,
                        )
                        val statusText  = testStatus ?: "Not tested"
                        val statusColor = when {
                            statusText.startsWith("Connected")  -> SettingsTheme.Success
                            statusText == "Testing…"            -> SettingsTheme.Cyan
                            statusText == "Not tested"          -> SettingsTheme.TextMuted
                            else                                -> SettingsTheme.Destructive
                        }
                        Text(statusText, color = statusColor, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                    SettingsPrimaryButton(
                        label   = if (testStatus == "Testing…") "Testing…" else "Test connection",
                        enabled = testStatus != "Testing…",
                        onClick = vm::testBrainConnection,
                    )
                }
            }
            Spacer(Modifier.height(8.dp))

            // ── Network ────────────────────────────────────────────────────────
            SettingsGroup(
                title  = "Network",
                footer = "When enabled, Brain fetches are skipped on mobile data.",
            ) {
                SettingsToggleRow(
                    title           = "Wi-Fi only",
                    description     = "Only fetch context when connected to Wi-Fi",
                    checked         = wifiOnly,
                    onCheckedChange = vm::setMacBrainWifiOnly,
                )
            }
            Spacer(Modifier.height(8.dp))

            // ── Context permissions ────────────────────────────────────────────
            SettingsGroup(
                title  = "Context permissions",
                footer = "Controls which intent types trigger a Brain fetch. " +
                         "Disabling a category keeps those queries fully local.",
            ) {
                SettingsToggleRow(
                    title           = "Memory & history",
                    description     = "Recall, \"do you remember\", past-conversation references",
                    checked         = allowMemory,
                    onCheckedChange = vm::setMacBrainAllowMemory,
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    title           = "Project & GitHub",
                    description     = "Codebase status, open PRs, known issues, what we're building",
                    checked         = allowProject,
                    onCheckedChange = vm::setMacBrainAllowProject,
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    title           = "Preferences",
                    description     = "Stored preferences and personalisation context",
                    checked         = allowPreferences,
                    onCheckedChange = vm::setMacBrainAllowPreferences,
                )
            }
        }

        if (onOpenDiagnostics != null) {
            Spacer(Modifier.height(8.dp))
            SettingsGroup {
                SettingsActionRow(
                    title       = "Connection diagnostics",
                    description = "Cache stats, circuit health, request counters and sync queue",
                    actionLabel = "View",
                    onAction    = onOpenDiagnostics,
                )
            }
        }

        Spacer(Modifier.height(24.dp))
    }
}
