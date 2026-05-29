package com.jarvis.assistant.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import com.jarvis.assistant.ui.theme.JarvisTokens
import com.jarvis.assistant.ui.theme.jarvisExtras

/**
 * Premium, theme-aware settings primitives for the redesigned Settings + the
 * Troubleshooting screen.  These are distinct from the older internal
 * `SettingsGroup`/`SettingsToggleRow` in `ui.settings` (which are hard-coded
 * dark); these read from the light-first [MaterialTheme] so they look right on
 * the bright design.
 *
 *  - [JarvisSettingsGroup]  rounded white card that hosts rows
 *  - [JarvisSettingsRow]    icon · title · subtitle · trailing/chevron
 *  - [JarvisToggleRow]      a row with a trailing Material3 Switch
 *  - [JarvisRowDivider]     hairline between rows
 */

@Composable
fun JarvisSettingsGroup(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val extras = MaterialTheme.jarvisExtras
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(JarvisTokens.Shape.card)
            .background(extras.surfaceRaised)
            .border(1.dp, extras.divider, JarvisTokens.Shape.card),
        content = content,
    )
}

@Composable
fun JarvisRowDivider() {
    HorizontalDivider(
        color = MaterialTheme.jarvisExtras.divider,
        thickness = 1.dp,
        modifier = Modifier.padding(start = 64.dp, end = JarvisTokens.Space.lg),
    )
}

/**
 * Tappable settings row.
 *
 * @param accent      tint of the rounded icon tile (defaults to primary).
 * @param trailing    optional trailing content; when null and [onClick] is
 *                    set, a chevron is shown.
 * @param badge       optional status badge shown after the title.
 */
@Composable
fun JarvisSettingsRow(
    icon: ImageVector,
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    accent: Color = MaterialTheme.colorScheme.primary,
    onClick: (() -> Unit)? = null,
    badge: @Composable (() -> Unit)? = null,
    trailing: @Composable (() -> Unit)? = null,
) {
    val scheme = MaterialTheme.colorScheme
    val extras = MaterialTheme.jarvisExtras
    val base = modifier
        .fillMaxWidth()
        .heightIn(min = 64.dp)
    val rowMod = if (onClick != null) base.clickable(onClick = onClick) else base
    Row(
        modifier = rowMod.padding(horizontal = JarvisTokens.Space.lg, vertical = JarvisTokens.Space.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(JarvisTokens.Radius.md))
                .background(accent.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = accent, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(JarvisTokens.Space.md))
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(JarvisTokens.Space.sm)) {
                Text(
                    text = title,
                    color = scheme.onSurface,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Medium,
                )
                badge?.invoke()
            }
            if (!subtitle.isNullOrBlank()) {
                Text(
                    text = subtitle,
                    color = scheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        if (trailing != null) {
            Spacer(Modifier.width(JarvisTokens.Space.sm))
            trailing()
        } else if (onClick != null) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = extras.textFaint,
            )
        }
    }
}

@Composable
fun JarvisToggleRow(
    icon: ImageVector,
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    enabled: Boolean = true,
    accent: Color = MaterialTheme.colorScheme.primary,
) {
    JarvisSettingsRow(
        icon = icon,
        title = title,
        subtitle = subtitle,
        accent = accent,
        modifier = modifier,
        onClick = if (enabled) ({ onCheckedChange(!checked) }) else null,
        trailing = {
            Switch(
                checked = checked,
                onCheckedChange = onCheckedChange,
                enabled = enabled,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = Color.White,
                    checkedTrackColor = MaterialTheme.colorScheme.primary,
                    uncheckedThumbColor = Color.White,
                    uncheckedTrackColor = MaterialTheme.jarvisExtras.border,
                    uncheckedBorderColor = MaterialTheme.jarvisExtras.border,
                ),
            )
        },
    )
}
