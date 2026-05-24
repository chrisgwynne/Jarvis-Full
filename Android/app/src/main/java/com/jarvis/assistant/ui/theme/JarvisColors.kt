package com.jarvis.assistant.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/**
 * JarvisColors — the blueprint palette and three baseline schemes.
 *
 * The brand identity is blueprint blue on a deep navy surface — a dark,
 * cinematic look that reads "intelligent infrastructure" rather than
 * "generic dark mode".  Three variants are exposed:
 *
 *   • Dark   — the primary scheme.  Background is deep navy (#060B14) so
 *              depth reads correctly on both OLED and LCD panels.
 *   • AMOLED — true black background for OLED battery savings on an
 *              always-on app like Jarvis.  Surfaces lift into deep navy.
 *   • Light  — high-contrast light scheme.  Mostly for accessibility.
 *              Blueprint blue is darkened so it stays readable on white.
 *
 * Material 3 dynamic-color is applied at the JarvisTheme level when the
 * user opts in (Android 12+).  These three schemes are the fallback and
 * the explicit user choice for "ignore wallpaper colours."
 */
object JarvisBrand {
    val cyan      = Color(0xFF3FA7FF)   // blueprint blue (primary accent)
    val cyanDeep  = Color(0xFF2080CC)   // darker blueprint blue for light scheme
    val green     = Color(0xFF00E676)
    val amber     = Color(0xFFFFAB40)
    val purple    = Color(0xFFCE93D8)
    val red       = Color(0xFFFF5252)
}

/**
 * Extra colours that don't fit neatly into the M3 ColorScheme contract
 * (status indicators, raised surfaces, divider tints).  Exposed via
 * [LocalJarvisExtraColors] so screens can read them off the composition.
 */
@Immutable
data class JarvisExtraColors(
    val surfaceRaised: Color,
    val divider: Color,
    val border: Color,
    val textMuted: Color,
    val textFaint: Color,
    val statusGreen: Color,
    val statusAmber: Color,
    val statusPurple: Color,
    val statusRed: Color,
    val infoBg: Color,
    val successBg: Color,
)

val LocalJarvisExtraColors = staticCompositionLocalOf {
    // Sensible default — the dark palette.  Real values come from JarvisTheme.
    DarkExtras
}

// ── Dark scheme ──────────────────────────────────────────────────────────────

internal val DarkColorScheme: ColorScheme = darkColorScheme(
    primary            = JarvisBrand.cyan,
    onPrimary          = Color(0xFF001529),
    primaryContainer   = Color(0xFF003A80),
    onPrimaryContainer = Color(0xFFA8D4FF),
    secondary          = JarvisBrand.purple,
    onSecondary        = Color(0xFF1A1024),
    background         = Color(0xFF060B14),     // deepest navy
    onBackground       = Color(0xFFCCE0F0),     // blue-tinted white
    surface            = Color(0xFF0B1628),     // card / group surface
    onSurface          = Color(0xFFE0E0E0),
    surfaceVariant     = Color(0xFF11203A),     // elevated input / raised surface
    onSurfaceVariant   = Color(0xFF7A8FAA),     // blue-grey secondary labels
    error              = JarvisBrand.red,
    onError            = Color(0xFF1A0508),
    outline            = Color(0xFF1A2E4A),     // blueprint border
)

internal val DarkExtras = JarvisExtraColors(
    surfaceRaised = Color(0xFF152742),
    divider       = Color(0xFF0E1C33),
    border        = Color(0xFF1A2E4A),
    textMuted     = Color(0xFF7A8FAA),
    textFaint     = Color(0xFF4A6080),
    statusGreen   = JarvisBrand.green,
    statusAmber   = JarvisBrand.amber,
    statusPurple  = JarvisBrand.purple,
    statusRed     = JarvisBrand.red,
    infoBg        = Color(0xFF070F1E),
    successBg     = Color(0xFF0A221A),
)

// ── AMOLED — true black for OLED battery savings on an always-on app ─────────

internal val AmoledColorScheme: ColorScheme = darkColorScheme(
    primary            = JarvisBrand.cyan,
    onPrimary          = Color(0xFF001529),
    primaryContainer   = Color(0xFF002860),
    onPrimaryContainer = Color(0xFFA8D4FF),
    secondary          = JarvisBrand.purple,
    onSecondary        = Color(0xFF1A1024),
    background         = Color.Black,
    onBackground       = Color(0xFFCCE0F0),
    surface            = Color.Black,
    onSurface          = Color(0xFFE0E0E0),
    surfaceVariant     = Color(0xFF060B14),     // first navy step above true black
    onSurfaceVariant   = Color(0xFF7A8FAA),
    error              = JarvisBrand.red,
    onError            = Color(0xFF1A0508),
    outline            = Color(0xFF0E1C33),
)

internal val AmoledExtras = JarvisExtraColors(
    surfaceRaised = Color(0xFF08111F),
    divider       = Color(0xFF060B14),
    border        = Color(0xFF0E1C33),
    textMuted     = Color(0xFF7A8FAA),
    textFaint     = Color(0xFF4A6080),
    statusGreen   = JarvisBrand.green,
    statusAmber   = JarvisBrand.amber,
    statusPurple  = JarvisBrand.purple,
    statusRed     = JarvisBrand.red,
    infoBg        = Color(0xFF050D15),
    successBg     = Color(0xFF050F0A),
)

// ── Light ────────────────────────────────────────────────────────────────────

internal val LightColorScheme: ColorScheme = lightColorScheme(
    primary            = JarvisBrand.cyanDeep,
    onPrimary          = Color.White,
    primaryContainer   = Color(0xFFCFE5FF),
    onPrimaryContainer = Color(0xFF001D3D),
    secondary          = Color(0xFF6750A4),
    onSecondary        = Color.White,
    background         = Color(0xFFF8F9FB),
    onBackground       = Color(0xFF1A1A24),
    surface            = Color.White,
    onSurface          = Color(0xFF1A1A24),
    surfaceVariant     = Color(0xFFEEF0F4),
    onSurfaceVariant   = Color(0xFF454556),
    error              = Color(0xFFC62828),
    onError            = Color.White,
    outline            = Color(0xFFC4C7D2),
)

internal val LightExtras = JarvisExtraColors(
    surfaceRaised = Color(0xFFFFFFFF),
    divider       = Color(0xFFE4E6EC),
    border        = Color(0xFFC4C7D2),
    textMuted     = Color(0xFF6B6B80),
    textFaint     = Color(0xFF9A9AB0),
    statusGreen   = Color(0xFF1B7F3D),
    statusAmber   = Color(0xFFB85C00),
    statusPurple  = Color(0xFF6750A4),
    statusRed     = Color(0xFFC62828),
    infoBg        = Color(0xFFE3F2FD),
    successBg     = Color(0xFFE8F5E9),
)
