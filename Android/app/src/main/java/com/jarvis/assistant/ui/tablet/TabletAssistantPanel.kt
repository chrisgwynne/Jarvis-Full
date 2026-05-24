package com.jarvis.assistant.ui.tablet

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.jarvis.assistant.core.state.JarvisState
import com.jarvis.assistant.memory.db.entity.ConversationTurn
import com.jarvis.assistant.ui.orb.OrbViewModel
import com.jarvis.assistant.ui.settings.PermissionUtils
import com.jarvis.assistant.ui.waveform.JarvisWaveform

// ── Palette ───────────────────────────────────────────────────────────────────
private val SidebarBg    = Color(0xFF060B14)   // deepest navy
private val CardBg       = Color(0xFF0B1628)   // card / group surface
private val BorderLine   = Color(0xFF1A2E4A)   // blueprint border
private val TextPrimary  = Color(0xFFCCE0F0)   // blue-tinted body text
private val TextMuted    = Color(0xFF7A8FAA)   // blue-grey secondary labels
private val CyanAccent   = Color(0xFF3FA7FF)   // blueprint blue
private val GreenOk      = Color(0xFF00E676)   // status green
private val RedBad       = Color(0xFFFF5252)   // status red
private val AmberWarn    = Color(0xFFFFAB40)   // status amber

/**
 * TabletAssistantPanel — the always-visible 35% left sidebar.
 *
 * Shows:
 *  - Live waveform and state badge
 *  - Last spoken utterance and assistant response
 *  - Service start / stop / trigger controls
 *  - Permission health mini-summary
 */
@Composable
internal fun TabletAssistantPanel(
    vm    : TabletViewModel = viewModel(),
    orbVm : OrbViewModel    = viewModel(),
) {
    val deviceState by vm.deviceState.collectAsState()
    val turns       by vm.turns.collectAsState()
    val visualState by orbVm.visualState.collectAsState()
    val amplitude   by orbVm.amplitude.collectAsState()
    val context      = LocalContext.current

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(SidebarBg)
            .padding(vertical = 12.dp),
    ) {
        // ── Header ────────────────────────────────────────────────────────────
        Text(
            "JARVIS",
            color        = CyanAccent,
            fontSize     = 11.sp,
            fontWeight   = FontWeight.Bold,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 4.sp,
            modifier     = Modifier.padding(horizontal = 16.dp),
        )

        Spacer(Modifier.height(4.dp))

        StateBadge(state = deviceState.runtimeState)

        Spacer(Modifier.height(12.dp))

        // ── Waveform ──────────────────────────────────────────────────────────
        JarvisWaveform(
            visualState = visualState,
            amplitude   = amplitude,
            modifier    = Modifier
                .fillMaxWidth()
                .height(80.dp),
        )

        Spacer(Modifier.height(12.dp))

        HorizontalDivider(color = BorderLine)

        // ── Last interaction ──────────────────────────────────────────────────
        Column(
            modifier = Modifier
                .padding(horizontal = 14.dp, vertical = 10.dp)
                .fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (deviceState.lastUserUtterance.isNotBlank()) {
                InteractionLine(
                    label  = "YOU",
                    text   = deviceState.lastUserUtterance,
                    color  = CyanAccent,
                )
            }
            if (deviceState.lastAssistantResponse.isNotBlank()) {
                InteractionLine(
                    label  = "JARVIS",
                    text   = deviceState.lastAssistantResponse,
                    color  = Color(0xFFCE93D8),
                )
            }
            if (deviceState.currentToolName != null) {
                InteractionLine(
                    label  = "TOOL",
                    text   = deviceState.currentToolName ?: "",
                    color  = AmberWarn,
                )
            }
        }

        HorizontalDivider(color = BorderLine)

        // ── Service controls ──────────────────────────────────────────────────
        ServiceControls(vm = vm)

        HorizontalDivider(color = BorderLine)

        // ── Permission health ─────────────────────────────────────────────────
        PermissionHealthMini(context = context)

        HorizontalDivider(color = BorderLine)

        // ── Recent turns (scrollable, fills remaining space) ──────────────────
        Spacer(Modifier.height(4.dp))
        Text(
            "RECENT",
            color        = TextMuted,
            fontSize     = 9.sp,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 2.sp,
            modifier     = Modifier.padding(horizontal = 16.dp),
        )
        Spacer(Modifier.height(4.dp))
        RecentTurnsMini(
            turns    = turns,
            modifier = Modifier.weight(1f),
        )
    }
}

// ── Sub-composables ───────────────────────────────────────────────────────────

@Composable
private fun StateBadge(state: JarvisState) {
    val (label, color) = when (state) {
        is JarvisState.IdleWake         -> "IDLE WAKE"     to TextMuted
        is JarvisState.WakeDetected     -> "WAKE"          to AmberWarn
        is JarvisState.Listening        -> "LISTENING"     to CyanAccent
        is JarvisState.Thinking         -> "THINKING"      to Color(0xFFCE93D8)
        is JarvisState.ToolRunning      -> "TOOL: ${state.toolName.take(12)}" to AmberWarn
        is JarvisState.Speaking         -> "SPEAKING"      to GreenOk
        is JarvisState.Interrupted      -> "INTERRUPTED"   to AmberWarn
        is JarvisState.Silenced         -> "SILENCED"      to TextMuted
        is JarvisState.OfflineFallback  -> "OFFLINE"       to RedBad
        is JarvisState.MicUnavailable   -> "MIC BUSY"      to RedBad
        is JarvisState.ServiceStopped   -> "STOPPED"       to RedBad
        else                            -> "…"             to TextMuted
    }

    Row(
        modifier = Modifier
            .padding(horizontal = 16.dp)
            .clip(RoundedCornerShape(4.dp))
            .background(color.copy(alpha = 0.12f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(RoundedCornerShape(50))
                .background(color),
        )
        Text(
            label,
            color        = color,
            fontSize     = 10.sp,
            fontFamily   = FontFamily.Monospace,
            fontWeight   = FontWeight.Bold,
            letterSpacing = 1.sp,
        )
    }
}

@Composable
private fun InteractionLine(label: String, text: String, color: Color) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            label,
            color        = color.copy(alpha = 0.6f),
            fontSize     = 8.sp,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 2.sp,
        )
        Text(
            text,
            color        = TextPrimary,
            fontSize     = 11.sp,
            fontFamily   = FontFamily.Monospace,
            maxLines     = 2,
            overflow     = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ServiceControls(vm: TabletViewModel) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Start / Stop toggle
        if (vm.isServiceRunning()) {
            ServiceChip(
                label   = "Stop",
                icon    = Icons.Filled.Stop,
                color   = RedBad,
                onClick = vm::stopService,
                modifier = Modifier.weight(1f),
            )
        } else {
            ServiceChip(
                label   = "Start",
                icon    = Icons.Filled.PlayArrow,
                color   = GreenOk,
                onClick = vm::startService,
                modifier = Modifier.weight(1f),
            )
        }

        // Manual trigger
        ServiceChip(
            label   = "Listen",
            icon    = Icons.Filled.Mic,
            color   = CyanAccent,
            onClick = vm::triggerListen,
            modifier = Modifier.weight(1f),
        )

        // Silence
        ServiceChip(
            label   = "Silence",
            icon    = Icons.Filled.VolumeOff,
            color   = AmberWarn,
            onClick = vm::silenceService,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun ServiceChip(
    label    : String,
    icon     : androidx.compose.ui.graphics.vector.ImageVector,
    color    : Color,
    onClick  : () -> Unit,
    modifier : Modifier = Modifier,
) {
    OutlinedButton(
        onClick    = onClick,
        modifier   = modifier.height(36.dp),
        shape      = RoundedCornerShape(6.dp),
        contentPadding = PaddingValues(horizontal = 4.dp),
        colors     = ButtonDefaults.outlinedButtonColors(contentColor = color),
        border     = androidx.compose.foundation.BorderStroke(1.dp, color.copy(alpha = 0.4f)),
    ) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(3.dp))
        Text(label, fontSize = 9.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun PermissionHealthMini(context: Context) {
    val checks = listOf(
        Triple("MIC",   PermissionUtils.isMicrophoneGranted(context),          CyanAccent),
        Triple("A11Y",  PermissionUtils.isAccessibilityServiceEnabled(context), GreenOk),
        Triple("NOTIF", PermissionUtils.isNotificationListenerEnabled(context), Color(0xFFCE93D8)),
        Triple("OVR",   PermissionUtils.canDrawOverlays(context),              AmberWarn),
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        checks.forEach { (label, granted, color) ->
            val effectiveColor = if (granted) color else RedBad
            Column(
                modifier              = Modifier.weight(1f),
                horizontalAlignment   = Alignment.CenterHorizontally,
                verticalArrangement   = Arrangement.spacedBy(2.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(RoundedCornerShape(50))
                        .background(effectiveColor),
                )
                Text(
                    label,
                    color        = effectiveColor.copy(alpha = 0.8f),
                    fontSize     = 7.sp,
                    fontFamily   = FontFamily.Monospace,
                    letterSpacing = 0.5.sp,
                )
            }
        }
    }
}

@Composable
private fun RecentTurnsMini(
    turns    : List<ConversationTurn>,
    modifier : Modifier = Modifier,
) {
    val listState = rememberLazyListState()
    val count     = turns.size

    LaunchedEffect(count) {
        if (count > 0) listState.animateScrollToItem(count - 1)
    }

    if (turns.isEmpty()) {
        Box(
            modifier         = modifier.fillMaxWidth().padding(16.dp),
            contentAlignment = Alignment.TopStart,
        ) {
            Text(
                "No conversation yet.",
                color      = TextMuted,
                fontSize   = 11.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    } else {
        LazyColumn(
            state   = listState,
            modifier = modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
            contentPadding      = PaddingValues(bottom = 8.dp),
        ) {
            items(turns, key = { it.id }) { turn ->
                MiniTurnRow(turn)
            }
        }
    }
}

@Composable
private fun MiniTurnRow(turn: ConversationTurn) {
    val isUser = turn.role == "user"
    val color  = if (isUser) CyanAccent else Color(0xFFCE93D8)
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 200.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(color.copy(alpha = 0.08f))
                .padding(horizontal = 8.dp, vertical = 4.dp),
        ) {
            Text(
                if (isUser) "YOU" else "JARVIS",
                color        = color.copy(alpha = 0.6f),
                fontSize     = 7.sp,
                fontFamily   = FontFamily.Monospace,
                letterSpacing = 1.sp,
            )
            Text(
                turn.content,
                color      = TextPrimary,
                fontSize   = 10.sp,
                fontFamily = FontFamily.Monospace,
                maxLines   = 3,
                overflow   = TextOverflow.Ellipsis,
            )
        }
    }
}
