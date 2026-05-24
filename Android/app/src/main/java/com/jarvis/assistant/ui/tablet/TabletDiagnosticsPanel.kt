package com.jarvis.assistant.ui.tablet

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jarvis.assistant.diagnostics.LocalRouteDiagnostics
import com.jarvis.assistant.reliability.ListenerDiagnostics
import com.jarvis.assistant.ui.settings.PermissionUtils
import java.text.DateFormat
import java.util.Date

// ── Palette ───────────────────────────────────────────────────────────────────
private val PanelBg   = Color(0xFF060B14)   // deepest navy
private val CardBg    = Color(0xFF0B1628)   // card surface
private val TextPri   = Color(0xFFCCE0F0)   // blue-tinted body text
private val TextMuted = Color(0xFF7A8FAA)   // blue-grey secondary labels
private val CyanHigh  = Color(0xFF3FA7FF)   // blueprint blue
private val GreenOk   = Color(0xFF00E676)   // status green
private val RedBad    = Color(0xFFFF5252)   // status red
private val AmberWarn = Color(0xFFFFAB40)   // status amber
private val BorderC   = Color(0xFF0E1C33)   // divider

/**
 * TabletDiagnosticsPanel — detail pane for the Diagnostics destination.
 *
 * Mirrors the content of [LocalDiagnosticsScreen] but inline (no scaffold
 * wrapper) so it fits naturally inside the tablet detail pane.
 *
 * Shows:
 *  - System status metrics (STT / recognizer counts / watchdog / A11y)
 *  - Device state from [DeviceStateStore]
 *  - Recent execution audit from [LocalRouteDiagnostics]
 */
@Composable
internal fun TabletDiagnosticsPanel(vm: TabletViewModel) {
    val context       = LocalContext.current
    val entries       by LocalRouteDiagnostics.stateFlow.collectAsState()
    val deviceState   by vm.deviceState.collectAsState()
    val sttCount       = ListenerDiagnostics.activeSpeechRecognizerCount.get()
    val wakeCount      = ListenerDiagnostics.activeWakeDetectorCount.get()
    val currentMode    = ListenerDiagnostics.currentListeningState
    val watchdogMs     = ListenerDiagnostics.lastWatchdogRestartMs
    val a11yOk         = PermissionUtils.isAccessibilityServiceEnabled(context)

    LazyColumn(
        modifier       = Modifier
            .fillMaxSize()
            .background(PanelBg),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            PanelHeader(label = "DIAGNOSTICS", icon = Icons.Filled.BugReport, tint = RedBad)
        }

        // ── System status ──────────────────────────────────────────────────────
        item {
            DiagSection(title = "System Status") {
                MetricRow("STT Mode",         currentMode)
                MetricDivider()
                MetricRow("Active Recognizers","$sttCount  (wake: $wakeCount)")
                MetricDivider()
                MetricRow("A11y Service", if (a11yOk) "Connected" else "Disconnected",
                    if (a11yOk) GreenOk else RedBad)
                MetricDivider()
                MetricRow("Watchdog", if (watchdogMs > 0) "Restarted" else "Healthy",
                    if (watchdogMs > 0) AmberWarn else GreenOk)
                MetricDivider()
                MetricRow("Mic available", if (deviceState.micAvailable) "Yes" else "No",
                    if (deviceState.micAvailable) GreenOk else RedBad)
                MetricDivider()
                MetricRow("Network",       if (deviceState.isOnline) "Online" else "Offline",
                    if (deviceState.isOnline) GreenOk else RedBad)
                MetricDivider()
                MetricRow("Battery",
                    if (deviceState.batteryPercent >= 0)
                        "${deviceState.batteryPercent}%${if (deviceState.isCharging) " ⚡" else ""}"
                    else "Unknown"
                )
            }
        }

        // ── Route audit controls ───────────────────────────────────────────────
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment     = Alignment.CenterVertically,
            ) {
                Text(
                    "EXECUTION AUDIT  (${entries.size} entries)",
                    color        = TextMuted,
                    fontSize     = 9.sp,
                    fontFamily   = FontFamily.Monospace,
                    letterSpacing = 2.sp,
                )
                TextButton(
                    onClick = { LocalRouteDiagnostics.clear() },
                    colors  = ButtonDefaults.textButtonColors(contentColor = RedBad),
                ) {
                    Icon(Icons.Filled.Delete, contentDescription = "Clear", modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Clear", fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                }
            }
        }

        // ── Route entries ──────────────────────────────────────────────────────
        if (entries.isEmpty()) {
            item {
                EmptyCard("No local routes recorded yet.")
            }
        } else {
            items(entries, key = { it.timestampMs }) { entry ->
                RouteEntryCard(entry)
            }
        }
    }
}

// ── Sub-composables ───────────────────────────────────────────────────────────

@Composable
private fun DiagSection(
    title   : String,
    content : @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(CardBg),
    ) {
        Text(
            title,
            color        = TextMuted,
            fontSize     = 9.sp,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 2.sp,
            modifier     = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
        )
        HorizontalDivider(color = BorderC)
        content()
    }
}

@Composable
private fun MetricRow(
    label      : String,
    value      : String,
    valueColor : Color = TextPri,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 11.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment     = Alignment.CenterVertically,
    ) {
        Text(label, color = TextPri.copy(alpha = 0.8f), fontSize = 13.sp, fontFamily = FontFamily.Monospace)
        Text(value, color = valueColor, fontSize = 13.sp, fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun MetricDivider() = HorizontalDivider(
    color    = BorderC,
    modifier = Modifier.padding(horizontal = 12.dp),
)

@Composable
private fun RouteEntryCard(e: LocalRouteDiagnostics.Entry) {
    val routeColor = if (e.remoteTouched) RedBad else TextMuted
    val timeStr    = DateFormat.getTimeInstance(DateFormat.MEDIUM).format(Date(e.timestampMs))

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(CardBg)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier              = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                "Intent: ${e.intent}",
                color      = TextPri,
                fontSize   = 12.sp,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
            )
            Text(
                "${e.latencyMs} ms",
                color    = if (e.latencyMs <= 1000) GreenOk else AmberWarn,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
        Text(
            "Tool: ${e.tool}",
            color      = TextMuted,
            fontSize   = 11.sp,
            fontFamily = FontFamily.Monospace,
        )
        Text(
            "\"${e.transcript}\"",
            color      = CyanHigh.copy(alpha = 0.8f),
            fontSize   = 11.sp,
            fontFamily = FontFamily.Monospace,
        )
        if (e.normalisedTranscript != e.transcript && e.normalisedTranscript.isNotBlank()) {
            Text(
                "Corrected: \"${e.normalisedTranscript}\"",
                color      = GreenOk.copy(alpha = 0.8f),
                fontSize   = 10.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
        Row(
            modifier              = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                "$timeStr · ${e.result}",
                color      = routeColor,
                fontSize   = 10.sp,
                fontFamily = FontFamily.Monospace,
            )
            if (e.remoteTouched) {
                Text(
                    "REMOTE FALLBACK",
                    color      = RedBad,
                    fontSize   = 9.sp,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}
