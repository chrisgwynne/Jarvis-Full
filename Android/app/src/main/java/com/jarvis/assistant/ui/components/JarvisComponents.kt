package com.jarvis.assistant.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.jarvis.assistant.ui.theme.JarvisGradients
import com.jarvis.assistant.ui.theme.JarvisTokens
import com.jarvis.assistant.ui.theme.jarvisExtras

/**
 * Jarvis design-system components — the reusable, theme-aware building blocks
 * the redesigned screens are assembled from.
 *
 * Everything here reads from [MaterialTheme.colorScheme] + [jarvisExtras] so
 * it tracks the (light-first) theme automatically.  Nothing hard-codes a hex
 * value, so dark/AMOLED still work if the user opts in.
 *
 * Components:
 *  - [JarvisButton]   primary / secondary / tertiary actions
 *  - [JarvisCard]     resting soft-shadow card
 *  - [GlassCard]      translucent layered "glass" panel
 *  - [SectionHeader]  small-caps grouping label with optional trailing slot
 *  - [PillTag]        compact rounded tag / chip
 */

// ── Buttons ─────────────────────────────────────────────────────────────────

enum class JarvisButtonStyle { Primary, Secondary, Tertiary }

/**
 * The single button used across the redesign.
 *
 *  - Primary   — filled electric-blue→purple gradient, white label.  The one
 *                strong CTA per screen.
 *  - Secondary — tonal surface with a hairline; quiet but tappable.
 *  - Tertiary  — text-only; lowest emphasis.
 *
 * Always ≥ [JarvisTokens.Touch.minTarget] tall for accessibility.
 */
@Composable
fun JarvisButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    style: JarvisButtonStyle = JarvisButtonStyle.Primary,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    fillWidth: Boolean = false,
) {
    val scheme = MaterialTheme.colorScheme
    val extras = MaterialTheme.jarvisExtras
    val shape = JarvisTokens.Shape.button

    val widthMod = if (fillWidth) Modifier.fillMaxWidth() else Modifier

    val container: Modifier = when (style) {
        JarvisButtonStyle.Primary ->
            Modifier
                .then(
                    if (enabled) Modifier.shadow(JarvisTokens.Shadow.card, shape, clip = false)
                    else Modifier
                )
                .clip(shape)
                .background(
                    if (enabled) Brush.linearGradient(JarvisGradients.primaryButton)
                    else Brush.linearGradient(listOf(extras.border, extras.border))
                )

        JarvisButtonStyle.Secondary ->
            Modifier
                .clip(shape)
                .background(scheme.surfaceVariant)
                .border(1.dp, extras.border, shape)

        JarvisButtonStyle.Tertiary ->
            Modifier.clip(shape)
    }

    val labelColor = when (style) {
        JarvisButtonStyle.Primary   -> if (enabled) Color.White else extras.textFaint
        JarvisButtonStyle.Secondary -> if (enabled) scheme.onSurface else extras.textFaint
        JarvisButtonStyle.Tertiary  -> if (enabled) scheme.primary else extras.textFaint
    }

    Box(
        modifier = modifier
            .then(widthMod)
            .heightIn(min = JarvisTokens.Touch.minTarget)
            .then(container)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = JarvisTokens.Space.xl, vertical = JarvisTokens.Space.md),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(JarvisTokens.Space.sm),
        ) {
            if (icon != null) {
                Icon(icon, contentDescription = null, tint = labelColor, modifier = Modifier.size(20.dp))
            }
            Text(
                text = text,
                color = labelColor,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

// ── Cards ─────────────────────────────────────────────────────────────────

/**
 * Resting card — white surface, soft diffuse shadow, large rounded corners.
 * The default container for grouped content on the light theme.
 */
@Composable
fun JarvisCard(
    modifier: Modifier = Modifier,
    shape: Shape = JarvisTokens.Shape.cardLarge,
    shadow: Dp = JarvisTokens.Shadow.card,
    contentPadding: PaddingValues = PaddingValues(JarvisTokens.Space.lg),
    content: @Composable ColumnScope.() -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val extras = MaterialTheme.jarvisExtras
    Column(
        modifier = modifier
            .shadow(shadow, shape, clip = false, ambientColor = ShadowInk, spotColor = ShadowInk)
            .clip(shape)
            .background(extras.surfaceRaised)
            .border(1.dp, extras.divider, shape)
            .padding(contentPadding),
        content = content,
    )
}

/**
 * Glass panel — a translucent layered surface with a subtle diagonal sheen and
 * hairline border.  Used for the status strip / overlays where the backdrop
 * should read through faintly.
 */
@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    shape: Shape = JarvisTokens.Shape.card,
    contentPadding: PaddingValues = PaddingValues(JarvisTokens.Space.lg),
    content: @Composable ColumnScope.() -> Unit,
) {
    val extras = MaterialTheme.jarvisExtras
    Column(
        modifier = modifier
            .shadow(JarvisTokens.Shadow.card, shape, clip = false, ambientColor = ShadowInk, spotColor = ShadowInk)
            .clip(shape)
            .background(extras.glassFill)
            .background(Brush.linearGradient(JarvisGradients.glassSheen))
            .border(1.dp, extras.glassBorder, shape)
            .padding(contentPadding),
        content = content,
    )
}

/** Shared low-alpha ink used for soft shadows on the light theme. */
private val ShadowInk = Color(0xFF1B2A4A)

// ── Section header ───────────────────────────────────────────────────────────

/**
 * Small-caps grouping label with strong letter-spacing and an optional
 * leading icon / trailing slot.  Used above settings groups and content
 * sections.
 */
@Composable
fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    trailing: @Composable (() -> Unit)? = null,
) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = JarvisTokens.Space.xs, vertical = JarvisTokens.Space.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = scheme.primary, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(JarvisTokens.Space.sm))
        }
        Text(
            text = title.uppercase(),
            style = MaterialTheme.typography.labelMedium,
            color = scheme.onSurfaceVariant,
            fontWeight = FontWeight.Bold,
        )
        if (trailing != null) {
            Spacer(Modifier.weight(1f))
            trailing()
        }
    }
}

// ── Pill tag ─────────────────────────────────────────────────────────────────

/**
 * Compact rounded tag.  [color] tints both the text and a soft 12%-alpha
 * background fill, so a single accent drives the whole chip.
 */
@Composable
fun PillTag(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.primary,
    leading: ImageVector? = null,
) {
    Surface(
        modifier = modifier,
        shape = JarvisTokens.Shape.pill,
        color = color.copy(alpha = 0.12f),
    ) {
        Row(
            modifier = Modifier.padding(
                horizontal = JarvisTokens.Space.md,
                vertical = JarvisTokens.Space.xs,
            ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(JarvisTokens.Space.xs),
        ) {
            if (leading != null) {
                Icon(leading, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
            }
            Text(
                text = text,
                color = color,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}
