package com.jarvis.assistant.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import com.jarvis.assistant.ui.theme.JarvisGradients
import com.jarvis.assistant.ui.theme.JarvisTokens
import com.jarvis.assistant.ui.theme.jarvisExtras

/**
 * Premium, theme-aware (light-first) screen scaffold for new settings screens.
 *
 * Distinct from the older dark `ui.settings.SettingsScaffold` so the redesigned
 * screens (Permissions, Troubleshooting) get the bright look without disturbing
 * the ~37 existing screens that still consume the dark scaffold.
 *
 *  - Soft gradient background + system-bar padding.
 *  - A round back button (when [onBack] is non-null) and a round close button.
 *  - A large headline title in the scroll area.
 */
@Composable
fun JarvisScreenScaffold(
    title: String,
    onBack: (() -> Unit)?,
    onClose: () -> Unit,
    subtitle: String? = null,
    contentPadding: PaddingValues = PaddingValues(
        horizontal = JarvisTokens.Space.lg,
        vertical = JarvisTokens.Space.sm,
    ),
    content: @Composable ColumnScope.() -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val extras = MaterialTheme.jarvisExtras

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(JarvisGradients.lightBackdrop))
            .statusBarsPadding(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = JarvisTokens.Space.lg, vertical = JarvisTokens.Space.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (onBack != null) {
                RoundIcon(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = scheme.onSurfaceVariant)
                }
            } else {
                Spacer(Modifier.size(JarvisTokens.Touch.minTarget))
            }
            Spacer(Modifier.weight(1f))
            RoundIcon(onClick = onClose) {
                Icon(Icons.Filled.Close, contentDescription = "Close settings", tint = scheme.onSurfaceVariant)
            }
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(contentPadding),
            verticalArrangement = Arrangement.spacedBy(JarvisTokens.Space.lg),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(JarvisTokens.Space.xs)) {
                Text(
                    text = title,
                    color = scheme.onBackground,
                    style = MaterialTheme.typography.displayMedium,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = JarvisTokens.Space.xs),
                )
                if (subtitle != null) {
                    Text(
                        text = subtitle,
                        color = scheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(horizontal = JarvisTokens.Space.xs),
                    )
                }
            }

            content()

            Spacer(Modifier.height(JarvisTokens.Space.xxl))
        }
    }
}

@Composable
private fun RoundIcon(onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(
        modifier = Modifier
            .size(JarvisTokens.Touch.minTarget)
            .clip(CircleShape)
            .background(MaterialTheme.jarvisExtras.surfaceRaised),
        contentAlignment = Alignment.Center,
    ) {
        IconButton(onClick = onClick) { content() }
    }
}
