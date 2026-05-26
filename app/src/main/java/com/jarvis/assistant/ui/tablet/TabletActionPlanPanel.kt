package com.jarvis.assistant.ui.tablet

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.jarvis.assistant.diagnostics.LocalRouteDiagnostics
import java.text.DateFormat
import java.util.Date

// ── Palette ───────────────────────────────────────────────────────────────────
private val PlanBg     = Color(0xFF060B14)   // deepest navy
private val CardBg     = Color(0xFF0B1628)   // card surface
private val CyanHigh   = Color(0xFF3FA7FF)   // blueprint blue
private val GreenOk    = Color(0xFF00E676)   // status green
private val RedBad     = Color(0xFFFF5252)   // status red
private val AmberWarn  = Color(0xFFFFAB40)   // status amber
private val PurpleHi   = Color(0xFFCE93D8)   // AI / speaking highlight
private val TextPri    = Color(0xFFCCE0F0)   // blue-tinted body text
private val TextMuted  = Color(0xFF7A8FAA)   // blue-grey secondary labels
private val BorderC    = Color(0xFF0E1C33)   // divider

/**
 * TabletActionPlanPanel — visualises what Jarvis is doing (or last did).
 *
 * Shows:
 *  - A step-by-step timeline of the current/last execution
 *  - A recent routes history list
 *
 * Data flows entirely from [TabletActionPlannerViewModel]; no new execution.
 */
@Composable
internal fun TabletActionPlanPanel(
    vm: TabletActionPlannerViewModel = viewModel(),
) {
    val plan by vm.planState.collectAsState()

    LaunchedEffect(Unit) { vm.loadMostRecentPlan() }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(PlanBg)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // ── Header ─────────────────────────────────────────────────────────────
        Row(
            modifier              = Modifier.fillMaxWidth(),
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(
                verticalAlignment     = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Filled.AccountTree,
                    contentDescription = "Action Plan",
                    tint               = CyanHigh,
                    modifier           = Modifier.size(16.dp),
                )
                Text(
                    "ACTION PLAN",
                    color        = CyanHigh,
                    fontSize     = 10.sp,
                    fontFamily   = FontFamily.Monospace,
                    fontWeight   = FontWeight.Bold,
                    letterSpacing = 2.sp,
                )
            }

            AnimatedVisibility(visible = plan.status != ActionPlanStatus.IDLE) {
                StatusPill(plan.status, plan.summary)
            }
        }

        // ── Timeline ───────────────────────────────────────────────────────────
        AnimatedVisibility(
            visible = plan.steps.isNotEmpty(),
            enter   = expandVertically() + fadeIn(),
            exit    = shrinkVertically() + fadeOut(),
        ) {
            Column(
                modifier            = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(CardBg)
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(0.dp),
            ) {
                if (plan.userIntent.isNotBlank()) {
                    Row(
                        verticalAlignment     = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier              = Modifier.padding(bottom = 8.dp),
                    ) {
                        Icon(
                            Icons.Filled.RecordVoiceOver,
                            contentDescription = null,
                            tint     = CyanHigh.copy(alpha = 0.6f),
                            modifier = Modifier.size(13.dp),
                        )
                        Text(
                            "\"${plan.userIntent.take(70)}\"",
                            color      = CyanHigh.copy(alpha = 0.8f),
                            fontSize   = 11.sp,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                    HorizontalDivider(color = BorderC)
                    Spacer(Modifier.height(8.dp))
                }

                plan.steps.forEachIndexed { idx, step ->
                    StepRow(step)
                    if (idx < plan.steps.lastIndex) {
                        ConnectorLine(step.status)
                    }
                }
            }
        }

        // ── Idle state ─────────────────────────────────────────────────────────
        AnimatedVisibility(
            visible = plan.steps.isEmpty() && plan.status == ActionPlanStatus.IDLE,
        ) {
            Text(
                "No active plan — say \"Jarvis\" to start.",
                color      = TextMuted,
                fontSize   = 11.sp,
                fontFamily = FontFamily.Monospace,
                modifier   = Modifier.padding(horizontal = 4.dp),
            )
        }

        // ── Recent routes ──────────────────────────────────────────────────────
        if (plan.recentRoutes.isNotEmpty()) {
            HorizontalDivider(color = BorderC)
            Text(
                "RECENT ROUTES",
                color        = TextMuted,
                fontSize     = 8.sp,
                fontFamily   = FontFamily.Monospace,
                letterSpacing = 2.sp,
            )
            plan.recentRoutes.take(5).forEach { route ->
                RecentRouteRow(route)
            }
        }
    }
}

// ── Sub-composables ───────────────────────────────────────────────────────────

@Composable
private fun StatusPill(status: ActionPlanStatus, summary: String) {
    val (bg, fg) = when (status) {
        ActionPlanStatus.IDLE           -> BorderC to TextMuted
        ActionPlanStatus.THINKING       -> PurpleHi.copy(alpha = 0.15f) to PurpleHi
        ActionPlanStatus.EXECUTING      -> AmberWarn.copy(alpha = 0.15f) to AmberWarn
        ActionPlanStatus.COMPLETE       -> GreenOk.copy(alpha = 0.12f) to GreenOk
        ActionPlanStatus.FAILED         -> RedBad.copy(alpha = 0.12f) to RedBad
        ActionPlanStatus.WAITING_CONFIRM-> CyanHigh.copy(alpha = 0.12f) to CyanHigh
    }
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(bg)
            .padding(horizontal = 8.dp, vertical = 3.dp),
    ) {
        Text(
            summary.ifBlank { status.name },
            color      = fg,
            fontSize   = 9.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun StepRow(step: ActionStepEntry) {
    val (dotColor, icon) = when (step.status) {
        ActionStepStatus.PENDING       -> TextMuted to Icons.Filled.RadioButtonUnchecked
        ActionStepStatus.ACTIVE        -> AmberWarn to Icons.Filled.Pending
        ActionStepStatus.COMPLETE      -> GreenOk   to Icons.Filled.CheckCircle
        ActionStepStatus.FAILED        -> RedBad    to Icons.Filled.Cancel
        ActionStepStatus.SKIPPED       -> TextMuted to Icons.Filled.RemoveCircle
        ActionStepStatus.WAITING_INPUT -> CyanHigh  to Icons.Filled.HelpCenter
    }

    Row(
        modifier              = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment     = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint     = dotColor,
            modifier = Modifier.size(16.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                step.description,
                color      = if (step.status == ActionStepStatus.PENDING) TextMuted else TextPri,
                fontSize   = 12.sp,
                fontFamily = FontFamily.Monospace,
                fontWeight = if (step.status == ActionStepStatus.ACTIVE) FontWeight.SemiBold
                             else FontWeight.Normal,
            )
            if (!step.detail.isNullOrBlank()) {
                Text(
                    step.detail,
                    color      = dotColor.copy(alpha = 0.7f),
                    fontSize   = 10.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
        if (step.durationMs > 0) {
            Text(
                "${step.durationMs} ms",
                color      = TextMuted,
                fontSize   = 9.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

@Composable
private fun ConnectorLine(statusAbove: ActionStepStatus) {
    val color = when (statusAbove) {
        ActionStepStatus.COMPLETE  -> GreenOk.copy(alpha = 0.3f)
        ActionStepStatus.FAILED    -> RedBad.copy(alpha = 0.3f)
        ActionStepStatus.ACTIVE    -> AmberWarn.copy(alpha = 0.3f)
        else                       -> BorderC
    }
    Box(
        modifier = Modifier
            .padding(start = 7.dp)
            .width(2.dp)
            .height(8.dp)
            .background(color),
    )
}

@Composable
private fun RecentRouteRow(entry: LocalRouteDiagnostics.Entry) {
    val routeColor = if (entry.remoteTouched) RedBad else TextMuted
    val timeStr    = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(entry.timestampMs))

    Row(
        modifier              = Modifier
            .fillMaxWidth()
            .padding(vertical = 3.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment     = Alignment.CenterVertically,
    ) {
        Row(
            modifier              = Modifier.weight(1f),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment     = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(5.dp)
                    .clip(CircleShape)
                    .background(if (entry.result.startsWith("success")) GreenOk else RedBad),
            )
            Text(
                "${entry.intent} → ${entry.tool}",
                color      = routeColor,
                fontSize   = 10.sp,
                fontFamily = FontFamily.Monospace,
                maxLines   = 1,
            )
        }
        Text(
            "$timeStr  ${entry.latencyMs}ms",
            color      = TextMuted,
            fontSize   = 9.sp,
            fontFamily = FontFamily.Monospace,
        )
    }
}
