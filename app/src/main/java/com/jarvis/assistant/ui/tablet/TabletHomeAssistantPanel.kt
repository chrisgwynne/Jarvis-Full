package com.jarvis.assistant.ui.tablet

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jarvis.assistant.session.context.RecentHomeAssistantContext

// ── Palette ───────────────────────────────────────────────────────────────────
private val PanelBg   = Color(0xFF060B14)   // deepest navy
private val CardBg    = Color(0xFF0B1628)   // card surface
private val TileBg    = Color(0xFF11203A)   // elevated tile surface
private val TextPri   = Color(0xFFCCE0F0)   // blue-tinted body text
private val TextMuted = Color(0xFF7A8FAA)   // blue-grey secondary labels
private val CyanHigh  = Color(0xFF3FA7FF)   // blueprint blue
private val GreenOk   = Color(0xFF00E676)   // status green
private val AmberHint = Color(0xFFFFAB40)   // status amber
private val BorderC   = Color(0xFF0E1C33)   // divider

// ── Quick HA command ──────────────────────────────────────────────────────────
private data class HaQuickCommand(
    val label   : String,
    val voice   : String,
    val icon    : ImageVector,
    val tint    : Color,
)

private val HA_QUICK_COMMANDS = listOf(
    HaQuickCommand("All Lights On",  "turn on all lights",   Icons.Filled.LightMode,   AmberHint),
    HaQuickCommand("All Lights Off", "turn off all lights",  Icons.Filled.DarkMode,    TextMuted),
    HaQuickCommand("Heating On",     "turn on the heating",  Icons.Filled.Thermostat,  Color(0xFFFF7043)),
    HaQuickCommand("Heating Off",    "turn off the heating", Icons.Filled.AcUnit,      CyanHigh),
    HaQuickCommand("TV On",          "turn on the TV",       Icons.Filled.Tv,          GreenOk),
    HaQuickCommand("TV Off",         "turn off the TV",      Icons.Filled.TvOff,       TextMuted),
)

/**
 * TabletHomeAssistantPanel — detail pane for the Home destination.
 *
 * Shows:
 *  - The most recently controlled HA entity (from [TabletViewModel.haContext])
 *  - A grid of quick-command tiles that trigger JarvisService via voice hint
 *  - Voice command hints
 */
@Composable
internal fun TabletHomeAssistantPanel(vm: TabletViewModel) {
    val haCtx by vm.haContext.collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(PanelBg)
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        PanelHeader(label = "HOME ASSISTANT", icon = Icons.Filled.Home, tint = AmberHint)

        // ── Recent entity card ─────────────────────────────────────────────────
        if (haCtx != null && !haCtx!!.isExpired()) {
            RecentHaCard(ctx = haCtx!!)
        } else {
            EmptyCard("No recent HA context — say \"Jarvis, turn on the lights\"")
        }

        HorizontalDivider(color = BorderC)

        // ── Quick command grid ─────────────────────────────────────────────────
        Text(
            "QUICK COMMANDS",
            color        = TextMuted,
            fontSize     = 9.sp,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 2.sp,
        )
        Text(
            "Tap to copy the voice command to the Jarvis prompt.",
            color      = TextMuted,
            fontSize   = 10.sp,
            fontFamily = FontFamily.Monospace,
        )

        // Two-column grid using a Column + Row pattern (avoids nested LazyColumn)
        val chunked = HA_QUICK_COMMANDS.chunked(2)
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            chunked.forEach { row ->
                Row(
                    modifier              = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    row.forEach { cmd ->
                        HaCommandTile(
                            cmd      = cmd,
                            onClick  = { vm.triggerListen() },
                            modifier = Modifier.weight(1f),
                        )
                    }
                    // If the last row has only one item, fill the gap
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }

        Spacer(Modifier.weight(1f))

        // ── Voice hints ────────────────────────────────────────────────────────
        VoiceHints(
            hints = listOf(
                "\"Jarvis, turn on the [room] lights\"",
                "\"Jarvis, set the thermostat to 21\"",
                "\"Jarvis, what's the temperature in the living room?\"",
                "\"Jarvis, turn it off\" (after a recent command)",
            )
        )
    }
}

@Composable
private fun RecentHaCard(ctx: RecentHomeAssistantContext) {
    val actionColor = when (ctx.lastAction) {
        "on"     -> GreenOk
        "off"    -> TextMuted
        "toggle" -> AmberHint
        else     -> CyanHigh
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(CardBg)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            "LAST ENTITY",
            color        = TextMuted,
            fontSize     = 8.sp,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 2.sp,
        )
        Row(
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                imageVector        = iconForDomain(ctx.domain),
                contentDescription = null,
                tint               = actionColor,
                modifier           = Modifier.size(24.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    ctx.friendlyName,
                    color      = TextPri,
                    fontSize   = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                )
                Text(
                    ctx.entityId,
                    color      = TextMuted,
                    fontSize   = 10.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(4.dp))
                    .background(actionColor.copy(alpha = 0.15f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            ) {
                Text(
                    ctx.lastAction.uppercase(),
                    color      = actionColor,
                    fontSize   = 10.sp,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}

@Composable
private fun HaCommandTile(
    cmd      : HaQuickCommand,
    onClick  : () -> Unit,
    modifier : Modifier = Modifier,
) {
    OutlinedButton(
        onClick  = onClick,
        modifier = modifier.height(52.dp),
        shape    = RoundedCornerShape(8.dp),
        colors   = ButtonDefaults.outlinedButtonColors(contentColor = cmd.tint),
        border   = androidx.compose.foundation.BorderStroke(1.dp, cmd.tint.copy(alpha = 0.3f)),
    ) {
        Icon(cmd.icon, contentDescription = cmd.label, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(cmd.label, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
    }
}

private fun iconForDomain(domain: String): ImageVector = when (domain) {
    "light"         -> Icons.Filled.LightMode
    "switch"        -> Icons.Filled.ToggleOn
    "climate"       -> Icons.Filled.Thermostat
    "media_player"  -> Icons.Filled.Tv
    "sensor"        -> Icons.Filled.Sensors
    "binary_sensor" -> Icons.Filled.Sensors
    "cover"         -> Icons.Filled.Blinds
    "fan"           -> Icons.Filled.Air
    "lock"          -> Icons.Filled.Lock
    else            -> Icons.Filled.Home
}
