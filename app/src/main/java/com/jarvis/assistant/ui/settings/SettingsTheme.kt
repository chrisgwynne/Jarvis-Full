package com.jarvis.assistant.ui.settings

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Shared palette, shapes and TextField styling for the settings surface.
 *
 * Kept separate from [com.jarvis.assistant.ui.SettingsScreen] so sub-screens
 * can share a single source of truth for look-and-feel.
 *
 * KNOWN LIMITATION (Phase 2): these colours are static and dark-only.
 * The newer [com.jarvis.assistant.ui.theme.JarvisTheme] supports
 * light / dark / AMOLED / dynamic colour, but every settings screen still
 * reads from this object directly so picking AMOLED in
 * [com.jarvis.assistant.ui.settings.screens.AppearanceSettingsScreen]
 * affects [com.jarvis.assistant.ui.MainScreen] but not the settings
 * screens themselves.  Migration is per-screen (~20 files) and is
 * deliberately deferred — new screens should consume
 * `MaterialTheme.colorScheme` + `MaterialTheme.jarvisExtras` instead of
 * this object.
 */
internal object SettingsTheme {
    // ── Blueprint deep-navy palette ───────────────────────────────────────────
    val BgDark        = Color(0xFF060B14)   // page background (deepest)
    val Surface       = Color(0xFF0B1628)   // card / group surface
    val SurfaceRaised = Color(0xFF11203A)   // input fields, elevated rows
    val Divider       = Color(0xFF0E1C33)   // barely-visible row separator
    val Border        = Color(0xFF1A2E4A)   // focused border / section divider
    val Cyan          = Color(0xFF3FA7FF)   // blueprint blue accent (replaces teal)
    val TextPrimary   = Color(0xFFE0E0E0)   // body text — unchanged
    val TextMuted     = Color(0xFF7A8FAA)   // secondary labels (blue-grey tint)
    val TextFaint     = Color(0xFF4A6080)   // helper/footer text
    val Destructive   = Color(0xFFFF5252)   // errors / destructive actions
    val Success       = Color(0xFF00E676)   // success / connected
    val InfoBg        = Color(0xFF070F1E)   // info-card background tint
    val SuccessBg     = Color(0xFF0A221A)   // success-card background tint

    val GroupShape    = RoundedCornerShape(14.dp)
    val RowShape      = RoundedCornerShape(10.dp)
    val ChipShape     = RoundedCornerShape(6.dp)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun settingsTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor      = SettingsTheme.Cyan,
    unfocusedBorderColor    = SettingsTheme.Border,
    focusedTextColor        = SettingsTheme.TextPrimary,
    unfocusedTextColor      = SettingsTheme.TextPrimary,
    cursorColor             = SettingsTheme.Cyan,
    focusedContainerColor   = SettingsTheme.SurfaceRaised,
    unfocusedContainerColor = SettingsTheme.SurfaceRaised,
)
