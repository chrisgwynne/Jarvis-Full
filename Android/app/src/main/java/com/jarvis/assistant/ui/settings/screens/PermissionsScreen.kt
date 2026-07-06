package com.jarvis.assistant.ui.settings.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.jarvis.assistant.ui.components.JarvisCard
import com.jarvis.assistant.ui.components.JarvisRowDivider
import com.jarvis.assistant.ui.components.JarvisScreenScaffold
import com.jarvis.assistant.ui.components.JarvisSettingsGroup
import com.jarvis.assistant.ui.components.PillTag
import com.jarvis.assistant.ui.components.SectionHeader
import com.jarvis.assistant.ui.settings.PermissionHealth
import com.jarvis.assistant.ui.settings.PermissionUtils
import com.jarvis.assistant.ui.theme.JarvisTheme
import com.jarvis.assistant.ui.theme.JarvisTokens
import com.jarvis.assistant.ui.theme.jarvisExtras

/**
 * Permissions — one calm screen for every Android permission Jarvis uses.
 *
 * Reuses [PermissionUtils] for live state + deep-link intents.  Required
 * permissions that are missing are surfaced first via a clear status header;
 * tapping a not-granted row opens the correct system settings page.
 */
@Composable
internal fun PermissionsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
    onOpenBackgroundLocationDisclosure: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    var permissions by remember { mutableStateOf(PermissionUtils.buildPermissionList(context)) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                permissions = PermissionUtils.buildPermissionList(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val required = permissions.filter { it.required }
    val optional = permissions.filter { !it.required }
    val missingRequired = required.count { !it.granted }

    JarvisScreenScaffold(
        title = "Permissions",
        subtitle = "What Jarvis can access on this phone. Tap anything that needs " +
            "attention to open Android settings.",
        onBack = onBack,
        onClose = onClose,
    ) {
        PermissionsStatusHeader(missingRequired = missingRequired)

        Column(verticalArrangement = Arrangement.spacedBy(JarvisTokens.Space.sm)) {
            SectionHeader(title = "Required")
            JarvisSettingsGroup {
                required.forEachIndexed { i, perm ->
                    PermissionRow(perm) { PermissionUtils.openPermissionSettings(context, perm) }
                    if (i < required.lastIndex) JarvisRowDivider()
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(JarvisTokens.Space.sm)) {
            SectionHeader(title = "Optional")
            JarvisSettingsGroup {
                optional.forEachIndexed { i, perm ->
                    val clickAction: () -> Unit =
                        if (perm.id == "background_location" && onOpenBackgroundLocationDisclosure != null) {
                            onOpenBackgroundLocationDisclosure
                        } else {
                            { PermissionUtils.openPermissionSettings(context, perm) }
                        }
                    PermissionRow(perm, clickAction)
                    if (i < optional.lastIndex) JarvisRowDivider()
                }
            }
        }
    }
}

@Composable
private fun PermissionsStatusHeader(missingRequired: Int) {
    val extras = MaterialTheme.jarvisExtras
    val scheme = MaterialTheme.colorScheme
    val title: String
    val body: String
    val accent = if (missingRequired == 0) extras.statusGreen else extras.statusAmber
    if (missingRequired == 0) {
        title = "All set"
        body = "Every permission Jarvis needs is granted."
    } else {
        title = "$missingRequired to grant"
        body = "Jarvis needs a few more permissions to work fully."
    }

    JarvisCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(JarvisTokens.Radius.md))
                    .background(accent.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (missingRequired == 0) Icons.Filled.CheckCircle else Icons.Filled.ErrorOutline,
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier.size(22.dp),
                )
            }
            Spacer(Modifier.width(JarvisTokens.Space.md))
            Column {
                Text(title, color = scheme.onSurface, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(body, color = scheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun PermissionRow(perm: PermissionHealth, onFix: () -> Unit) {
    val extras = MaterialTheme.jarvisExtras
    val scheme = MaterialTheme.colorScheme
    val granted = perm.granted

    val icon = when {
        granted       -> Icons.Filled.CheckCircle
        perm.required -> Icons.Filled.ErrorOutline
        else          -> Icons.Filled.RadioButtonUnchecked
    }
    val tint = when {
        granted       -> extras.statusGreen
        perm.required -> extras.statusAmber
        else          -> extras.textMuted
    }

    val rowMod = Modifier
        .fillMaxWidth()
        .then(if (!granted) Modifier.clickable(onClick = onFix) else Modifier)
        .padding(horizontal = JarvisTokens.Space.lg, vertical = JarvisTokens.Space.md)

    Row(modifier = rowMod, verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(JarvisTokens.Space.md))
        Column(modifier = Modifier.weight(1f)) {
            Text(perm.name, color = scheme.onSurface, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
            Text(perm.detail, color = scheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.width(JarvisTokens.Space.sm))
        when {
            granted       -> PillTag(text = "Granted", color = extras.statusGreen)
            perm.required  -> PillTag(text = "Required", color = extras.statusAmber)
            else          -> PillTag(text = "Optional", color = extras.textMuted)
        }
    }
}

@Preview(name = "Permissions", showBackground = true, widthDp = 412, heightDp = 915)
@Composable
private fun PreviewPermissions() {
    JarvisTheme {
        PermissionsScreen(onBack = {}, onClose = {})
    }
}
