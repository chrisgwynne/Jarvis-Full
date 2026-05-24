package com.jarvis.assistant.ui.settings.screens

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTheme
import com.jarvis.assistant.ui.settings.SettingsValueRow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
internal fun MacBrainDiagnosticsScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val diag    by vm.brainDiagnostics.collectAsStateWithLifecycle()
    val timeFmt = SimpleDateFormat("HH:mm:ss", Locale.getDefault())

    fun fmt(epochMs: Long) = if (epochMs > 0L) timeFmt.format(Date(epochMs)) else "—"

    val (accent, bg) = when {
        !diag.enabled                  -> SettingsTheme.TextMuted  to SettingsTheme.InfoBg
        diag.lastHealthOk == true      -> SettingsTheme.Success     to SettingsTheme.SuccessBg
        diag.lastHealthOk == false     -> SettingsTheme.Destructive to SettingsTheme.InfoBg
        diag.circuitState == "OPEN"    -> SettingsTheme.Destructive  to SettingsTheme.InfoBg
        else                           -> SettingsTheme.Cyan        to SettingsTheme.InfoBg
    }
    val infoTitle = when {
        !diag.enabled               -> "Disabled"
        diag.circuitState == "OPEN" -> "Connection paused"
        diag.lastHealthOk == true   -> "Connected"
        diag.lastHealthOk == false  -> "Unreachable"
        else                        -> "Configured"
    }
    val infoBody = when {
        !diag.enabled               -> "Mac Brain is off. No context fetches will occur."
        diag.circuitState == "OPEN" -> "Connection health tripped after repeated failures. " +
                                       "Brain fetches are paused. Reset below once the service is reachable."
        diag.lastHealthOk == true   -> "Last health check passed at ${diag.lastHealthLatencyMs}ms. " +
                                       "${diag.totalSuccesses} successful fetches."
        diag.lastHealthOk == false  -> "Last health check failed. Verify the server address and access key in Mac Brain settings."
        else                        -> "Brain is enabled but no health check has run yet. Test via Mac Brain settings."
    }

    SettingsScaffold(title = "Mac Brain Diagnostics", onBack = onBack, onClose = onClose) {

        SettingsInfoCard(title = infoTitle, body = infoBody, accent = accent, background = bg)
        Spacer(Modifier.height(8.dp))

        // ── Status ────────────────────────────────────────────────────────────
        SettingsGroup(title = "Status") {
            SettingsValueRow(
                title = "Enabled",
                value = if (diag.enabled) "Yes" else "No",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title       = "Connection health",
                value       = when (diag.circuitState) {
                    "CLOSED"    -> "Connected"
                    "OPEN"      -> "Paused"
                    "HALF_OPEN" -> "Recovering"
                    else        -> diag.circuitState
                },
                description = when (diag.circuitState) {
                    "CLOSED"    -> "Normal operation — requests flow through."
                    "OPEN"      -> "Paused — Brain fetches are suppressed until the recovery window expires."
                    "HALF_OPEN" -> "Recovering — one request will be allowed to test reachability."
                    else        -> null
                },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title       = "In-flight requests",
                value       = diag.inFlightCount.toString(),
                description = "Requests currently awaiting a Brain response.",
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Health ────────────────────────────────────────────────────────────
        SettingsGroup(title = "Health check") {
            SettingsValueRow(
                title = "Last result",
                value = when (diag.lastHealthOk) {
                    true  -> "Passed"
                    false -> "Failed"
                    null  -> "Never checked"
                },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last latency",
                value = if (diag.lastHealthLatencyMs >= 0L) "${diag.lastHealthLatencyMs} ms" else "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last checked at",
                value = fmt(diag.lastHealthCheckedAt),
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Last request ──────────────────────────────────────────────────────
        SettingsGroup(title = "Last request") {
            SettingsValueRow(
                title = "Intent",
                value = diag.lastRequestIntent,
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Result",
                value = diag.lastRequestResult,
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Failure reason",
                value = diag.lastFailureReason,
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last succeeded at",
                value = fmt(diag.lastSucceededAt),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last cache hit at",
                value = fmt(diag.lastCacheHitAt),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last timeout at",
                value = fmt(diag.lastTimeoutAt),
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Counters ──────────────────────────────────────────────────────────
        SettingsGroup(title = "Request counters") {
            SettingsValueRow(title = "Total requests",  value = diag.totalRequests.toString())
            SettingsRowDivider()
            SettingsValueRow(title = "Succeeded",       value = diag.totalSuccesses.toString())
            SettingsRowDivider()
            SettingsValueRow(title = "Cache hits",      value = diag.totalCacheHits.toString())
            SettingsRowDivider()
            SettingsValueRow(title = "Timeouts",        value = diag.totalTimeouts.toString())
            SettingsRowDivider()
            SettingsValueRow(title = "Failures",        value = diag.totalFailures.toString())
            SettingsRowDivider()
            SettingsValueRow(
                title       = "Skipped",
                value       = diag.totalSkipped.toString(),
                description = "Requests skipped by connection health, interrupt detection, or permission gate.",
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Memory cache ──────────────────────────────────────────────────────
        SettingsGroup(title = "Memory cache") {
            SettingsValueRow(
                title       = "Cached entries",
                value       = diag.cacheSize.toString(),
                description = "In-memory cache, max 64 entries, 5-min TTL.",
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Clear cache",
                description = "Removes all cached Brain responses. Safe at any time.",
                actionLabel = "Clear",
                onAction    = vm::clearBrainCache,
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Connection health ─────────────────────────────────────────────────
        SettingsGroup(title = "Connection health") {
            SettingsValueRow(
                title       = "Status",
                value       = when (diag.circuitState) {
                    "CLOSED"    -> "Connected"
                    "OPEN"      -> "Paused"
                    "HALF_OPEN" -> "Recovering"
                    else        -> diag.circuitState
                },
                description = "Pauses after 5 failures in 2 min. Auto-recovers after 5 min.",
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Reset connection health",
                description = "Forces the connection back to active. Use if the Brain " +
                              "is reachable again after a failure window.",
                actionLabel = "Reset",
                onAction    = vm::resetBrainCircuit,
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Pending sync items ────────────────────────────────────────────────
        SettingsGroup(title = "Pending sync items") {
            SettingsValueRow(
                title       = "Pending events",
                value       = diag.pendingSyncCount.toString(),
                description = "Interaction outcomes queued for delivery to Mac Brain.",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title       = "Failed retries",
                value       = diag.failedRetryCount.toString(),
                description = "Events that have failed at least once and are awaiting retry.",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Oldest queued at",
                value = fmt(diag.oldestQueuedAt),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last sync attempt",
                value = fmt(diag.lastSyncAttemptAt),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last sync success",
                value = fmt(diag.lastSyncSuccessAt),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last sync failure",
                value = fmt(diag.lastSyncFailureAt),
            )
        }

        Spacer(Modifier.height(24.dp))
    }
}
