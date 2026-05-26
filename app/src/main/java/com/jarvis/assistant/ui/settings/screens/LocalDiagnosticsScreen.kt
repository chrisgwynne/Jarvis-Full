package com.jarvis.assistant.ui.settings.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jarvis.assistant.diagnostics.LocalRouteDiagnostics
import com.jarvis.assistant.reliability.ListenerDiagnostics
import com.jarvis.assistant.ui.settings.*
import java.text.DateFormat
import java.util.Date

@Composable
internal fun LocalDiagnosticsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val entries by LocalRouteDiagnostics.stateFlow.collectAsState()
    val context = LocalContext.current
    
    val sttCount = ListenerDiagnostics.activeSpeechRecognizerCount.get()
    val wakeCount = ListenerDiagnostics.activeWakeDetectorCount.get()
    val currentMode = ListenerDiagnostics.currentListeningState
    val watchdogRestart = ListenerDiagnostics.lastWatchdogRestartMs
    val a11yOk = PermissionUtils.isAccessibilityServiceEnabled(context)

    SettingsScaffold(title = "Diagnostics Dashboard", onBack = onBack, onClose = onClose) {

        SettingsGroup(title = "System Status") {
            SettingsMetricRow("STT Status", currentMode)
            SettingsRowDivider()
            SettingsMetricRow("Active Recognizers", "$sttCount (Wake: $wakeCount)")
            SettingsRowDivider()
            SettingsMetricRow("WhatsApp A11y", if (a11yOk) "Connected" else "Disconnected", if (a11yOk) SettingsTheme.Success else SettingsTheme.Destructive)
            SettingsRowDivider()
            SettingsMetricRow("Watchdog Status", if (watchdogRestart > 0) "Restarted" else "Healthy", if (watchdogRestart > 0) SettingsTheme.Destructive else SettingsTheme.Success)
        }

        SettingsGroup(
            title       = "Recent Execution Audit",
            description = "Detailed routing log for local tool execution.",
        ) {
            SettingsActionRow(
                title       = "Clear log",
                description = "Discard the in-memory buffer.",
                actionLabel = "Clear",
                destructive = true,
                confirm     = true,
                onAction    = { LocalRouteDiagnostics.clear() },
            )
            SettingsRowDivider()
            if (entries.isEmpty()) {
                Text(
                    "No local routes recorded yet.",
                    color    = SettingsTheme.TextMuted,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(16.dp),
                )
            } else {
                Column(modifier = Modifier.fillMaxWidth()) {
                    entries.forEachIndexed { idx, e ->
                        RouteRow(e)
                        if (idx != entries.lastIndex) SettingsRowDivider()
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsMetricRow(label: String, value: String, valueColor: androidx.compose.ui.graphics.Color = SettingsTheme.TextPrimary) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, color = SettingsTheme.TextPrimary, fontSize = 14.sp)
        Text(value, color = valueColor, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun RouteRow(e: LocalRouteDiagnostics.Entry) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                "Intent: ${e.intent}",
                fontWeight = FontWeight.Bold,
                fontSize   = 13.sp,
                color = SettingsTheme.TextPrimary
            )
            Text(
                "${e.latencyMs} ms",
                fontSize = 12.sp,
                color    = if (e.latencyMs <= 1000) SettingsTheme.Success else SettingsTheme.TextMuted,
            )
        }
        Text("Tool: ${e.tool}", fontSize = 12.sp, color = SettingsTheme.TextMuted)
        
        Spacer(Modifier.height(4.dp))
        Text(
            "Heard: “${e.transcript}”",
            fontSize = 12.sp,
            color    = SettingsTheme.Cyan,
        )
        if (e.normalisedTranscript != e.transcript && e.normalisedTranscript.isNotBlank()) {
            Text(
                "Corrected: “${e.normalisedTranscript}”",
                fontSize = 12.sp,
                color    = SettingsTheme.Success,
            )
        }
        
        val time = DateFormat.getTimeInstance(DateFormat.MEDIUM).format(Date(e.timestampMs))
        val routeColor = if (e.remoteTouched) SettingsTheme.Destructive else SettingsTheme.TextMuted
        
        Spacer(Modifier.height(4.dp))
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("$time · ${e.result}", fontSize = 11.sp, color = routeColor)
            if (e.remoteTouched) {
                Text("REMOTE FALLBACK", fontSize = 10.sp, color = SettingsTheme.Destructive, fontWeight = FontWeight.Bold)
            }
        }
    }
}
