package com.jarvis.assistant.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.jarvis.assistant.ui.theme.JarvisTokens
import com.jarvis.assistant.ui.theme.jarvisExtras

/**
 * The set of assistant + connection states the UI surfaces as a badge.
 *
 * Deliberately a flat, presentation-only enum — the screen maps its runtime
 * state (orb visual state, Mac-brain status, mic permission) onto one of
 * these so the badge styling lives in one place.
 */
enum class JarvisStatus {
    // Assistant states
    Idle,
    Listening,
    Thinking,
    Speaking,
    RunningAction,
    Paused,
    // Connection / availability states
    Connected,
    Offline,
    Reconnecting,
    MicBlocked,
}

/** Human-readable label for [JarvisStatus]. */
fun JarvisStatus.label(): String = when (this) {
    JarvisStatus.Idle          -> "Ready"
    JarvisStatus.Listening     -> "Listening"
    JarvisStatus.Thinking      -> "Thinking"
    JarvisStatus.Speaking      -> "Speaking"
    JarvisStatus.RunningAction -> "Working on it"
    JarvisStatus.Paused        -> "Paused"
    JarvisStatus.Connected     -> "Connected"
    JarvisStatus.Offline       -> "Offline"
    JarvisStatus.Reconnecting  -> "Reconnecting"
    JarvisStatus.MicBlocked    -> "Microphone blocked"
}

/** Resolves the accent colour for a status from the active theme. */
@Composable
fun JarvisStatus.color(): Color {
    val scheme = MaterialTheme.colorScheme
    val extras = MaterialTheme.jarvisExtras
    return when (this) {
        JarvisStatus.Idle          -> scheme.primary
        JarvisStatus.Listening     -> extras.accentCyan
        JarvisStatus.Thinking      -> extras.statusAmber
        JarvisStatus.RunningAction -> extras.statusAmber
        JarvisStatus.Speaking      -> extras.accentPurple
        JarvisStatus.Paused        -> extras.statusRed
        JarvisStatus.Connected     -> extras.statusGreen
        JarvisStatus.Offline       -> extras.textMuted
        JarvisStatus.Reconnecting  -> extras.statusAmber
        JarvisStatus.MicBlocked    -> extras.statusRed
    }
}

/** Whether this status should pulse its dot to read as "live / active". */
private fun JarvisStatus.isLive(): Boolean = when (this) {
    JarvisStatus.Listening,
    JarvisStatus.Thinking,
    JarvisStatus.Speaking,
    JarvisStatus.RunningAction,
    JarvisStatus.Reconnecting -> true
    else -> false
}

/**
 * A polished status pill: an animated state dot + label, tinted by the
 * status accent over a soft 10% fill.  The dot gently pulses for live states
 * (listening / thinking / speaking / reconnecting) and holds steady otherwise
 * — calm, non-flashing motion.
 */
@Composable
fun StateBadge(
    status: JarvisStatus,
    modifier: Modifier = Modifier,
    label: String = status.label(),
) {
    val target = status.color()
    val accent by animateColorAsState(target, tween(JarvisTokens.Motion.medium), label = "badgeAccent")

    val pulse by rememberInfiniteTransition(label = "badgePulse").animateFloat(
        initialValue = if (status.isLive()) 0.35f else 1f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(900),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "badgePulseAlpha",
    )

    Surface(
        modifier = modifier,
        shape = JarvisTokens.Shape.pill,
        color = accent.copy(alpha = 0.10f),
    ) {
        Row(
            modifier = Modifier.padding(
                horizontal = JarvisTokens.Space.md,
                vertical = JarvisTokens.Space.sm,
            ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(JarvisTokens.Space.sm),
        ) {
            // Animated dot with a soft halo.
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .drawBehind {
                        val a = if (status.isLive()) pulse else 1f
                        // Halo
                        drawCircle(color = accent.copy(alpha = 0.25f * a), radius = size.minDimension / 2f)
                        // Core
                        drawCircle(color = accent.copy(alpha = a), radius = size.minDimension / 3.2f)
                    },
            )
            Text(
                text = label,
                color = accent,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}
