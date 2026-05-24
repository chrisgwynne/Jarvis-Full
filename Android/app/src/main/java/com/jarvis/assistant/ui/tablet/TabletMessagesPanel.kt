package com.jarvis.assistant.ui.tablet

import android.content.Intent
import android.net.Uri
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jarvis.assistant.session.context.MessageChannel
import com.jarvis.assistant.session.context.RecentMessageContext

// ── Palette ───────────────────────────────────────────────────────────────────
private val PanelBg    = Color(0xFF060B14)   // deepest navy
private val CardBg     = Color(0xFF0B1628)   // card surface
private val BorderLine = Color(0xFF1A2E4A)   // blueprint border
private val TextPri    = Color(0xFFCCE0F0)   // blue-tinted body text
private val TextMuted  = Color(0xFF7A8FAA)   // blue-grey secondary labels
private val CyanHigh   = Color(0xFF3FA7FF)   // blueprint blue
private val GreenOk    = Color(0xFF00E676)   // status green
private val AmberHint  = Color(0xFFFFAB40)   // status amber

/**
 * TabletMessagesPanel — detail pane for the Messages destination.
 *
 * Shows the most recent message context captured by Jarvis (from
 * [JarvisApp.recentMessageContextStore]) and provides quick-action buttons to
 * open the corresponding messaging app.  Voice command hints are shown so
 * the user knows what to say.
 */
@Composable
internal fun TabletMessagesPanel(vm: TabletViewModel) {
    val context      = LocalContext.current
    val msgContext  by vm.messageContext.collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(PanelBg)
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // ── Header ─────────────────────────────────────────────────────────────
        PanelHeader(label = "MESSAGES", icon = Icons.Filled.Message)

        // ── Recent message card ────────────────────────────────────────────────
        if (msgContext != null && !msgContext!!.isExpired()) {
            RecentMessageCard(ctx = msgContext!!, context = context)
        } else {
            EmptyCard("No recent message context captured yet.")
        }

        // ── Quick actions ──────────────────────────────────────────────────────
        Text(
            "QUICK OPEN",
            color        = TextMuted,
            fontSize     = 9.sp,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 2.sp,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ActionChip(
                label = "Messages",
                icon  = Icons.Filled.Sms,
                color = GreenOk,
                onClick = {
                    context.startActivity(
                        Intent(Intent.ACTION_MAIN)
                            .addCategory(Intent.CATEGORY_APP_MESSAGING)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                },
            )
            ActionChip(
                label = "WhatsApp",
                icon  = Icons.Filled.Chat,
                color = GreenOk,
                onClick = {
                    context.startActivity(
                        context.packageManager
                            .getLaunchIntentForPackage("com.whatsapp")
                            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            ?: Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me"))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                },
            )
        }

        // ── Voice hints ────────────────────────────────────────────────────────
        VoiceHints(
            hints = listOf(
                "\"Jarvis, read my messages\"",
                "\"Jarvis, reply yes\"",
                "\"Jarvis, text [name] I'm on my way\"",
                "\"Jarvis, call [name]\"",
            )
        )
    }
}

@Composable
private fun RecentMessageCard(
    ctx     : RecentMessageContext,
    context : android.content.Context,
) {
    val channelLabel = when (ctx.channel) {
        MessageChannel.SMS          -> "SMS"
        MessageChannel.WHATSAPP     -> "WhatsApp"
        MessageChannel.EMAIL        -> "Email"
        MessageChannel.NOTIFICATION -> "Notification"
    }
    val channelColor = when (ctx.channel) {
        MessageChannel.WHATSAPP -> GreenOk
        MessageChannel.EMAIL    -> AmberHint
        else                    -> CyanHigh
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(CardBg)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Channel badge + sender
        Row(
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Badge(containerColor = channelColor.copy(alpha = 0.2f)) {
                Text(
                    channelLabel,
                    color      = channelColor,
                    fontSize   = 9.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
            Text(
                ctx.sender,
                color      = TextPri,
                fontSize   = 15.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
            )
        }
        // Message body
        Text(
            ctx.body,
            color      = TextPri.copy(alpha = 0.85f),
            fontSize   = 13.sp,
            fontFamily = FontFamily.Monospace,
        )
        // Call button if a number is known
        if (ctx.senderNumber != null) {
            TextButton(
                onClick = {
                    context.startActivity(
                        Intent(Intent.ACTION_CALL, Uri.parse("tel:${ctx.senderNumber}"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                },
                colors = ButtonDefaults.textButtonColors(contentColor = CyanHigh),
            ) {
                Icon(
                    Icons.Filled.Call,
                    contentDescription = "Call",
                    modifier           = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(4.dp))
                Text("Call ${ctx.sender}", fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
        }
    }
}

// ── Shared panel utilities ────────────────────────────────────────────────────

@Composable
internal fun PanelHeader(
    label    : String,
    icon     : androidx.compose.ui.graphics.vector.ImageVector,
    tint     : Color = CyanHigh,
) {
    Row(
        verticalAlignment     = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(20.dp))
        Text(
            label,
            color        = tint,
            fontSize     = 11.sp,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 3.sp,
            fontWeight   = FontWeight.Bold,
        )
    }
}

@Composable
internal fun EmptyCard(message: String) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(CardBg)
            .padding(20.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            message,
            color      = TextMuted,
            fontSize   = 12.sp,
            fontFamily = FontFamily.Monospace,
        )
    }
}

@Composable
internal fun ActionChip(
    label   : String,
    icon    : androidx.compose.ui.graphics.vector.ImageVector,
    color   : Color,
    onClick : () -> Unit,
) {
    OutlinedButton(
        onClick = onClick,
        shape   = RoundedCornerShape(8.dp),
        colors  = ButtonDefaults.outlinedButtonColors(contentColor = color),
        border  = androidx.compose.foundation.BorderStroke(1.dp, color.copy(alpha = 0.4f)),
    ) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(label, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
    }
}

@Composable
internal fun VoiceHints(hints: List<String>) {
    Column(
        modifier            = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(PanelBg)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            "VOICE COMMANDS",
            color        = TextMuted,
            fontSize     = 8.sp,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 2.sp,
        )
        hints.forEach { hint ->
            Text(
                hint,
                color      = CyanHigh.copy(alpha = 0.7f),
                fontSize   = 11.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}
