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

    // ── 2026 premium light-theme accent ramp ──────────────────────────────────
    // Electric blue / soft cyan / clean purple on white & warm blue-grey.
    // These are the colours the redesigned light surfaces draw from; the
    // darker -OnLight variants stay legible as text/fills on white.
    val electricBlue      = Color(0xFF2563EB)   // primary CTA on light
    val electricBlueBright = Color(0xFF3B82F6)  // gradient top stop
    val softCyan          = Color(0xFF22D3EE)   // secondary accent / listening
    val cleanPurple       = Color(0xFF7C5CFF)   // tertiary accent / speaking
    val violetOnLight     = Color(0xFF6D28D9)   // purple text on white
    val greenOnLight      = Color(0xFF059669)   // connected / success on white
    val amberOnLight      = Color(0xFFD97706)   // thinking / warning on white
    val redOnLight        = Color(0xFFDC2626)   // error / stop on white
}

/**
 * Reusable brand gradients.  Built as plain colour lists so callers can feed
 * them into [androidx.compose.ui.graphics.Brush.linearGradient] /
 * `verticalGradient` at the size they need (Brush dimensions are layout-bound,
 * so we expose the stops rather than a pre-sized Brush).
 */
object JarvisGradients {
    /** Primary CTA — electric blue → clean purple, top-left to bottom-right. */
    val primaryButton = listOf(JarvisBrand.electricBlueBright, JarvisBrand.cleanPurple)

    /** App background wash — barely-there blue-grey lift on white. */
    val lightBackdrop = listOf(Color(0xFFFFFFFF), Color(0xFFEEF3FB))

    /** Glass-card sheen — subtle white→translucent-blue diagonal. */
    val glassSheen = listOf(
        Color(0x66FFFFFF),
        Color(0x14FFFFFF),
    )

    /** Orb stage halo on the light hero card. */
    val heroHalo = listOf(Color(0x143B82F6), Color(0x00FFFFFF))
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
    // ── Premium design-system roles (added for the 2026 redesign) ─────────────
    /** Accent used for "listening" / soft-cyan secondary moments. */
    val accentCyan: Color = statusGreen,
    /** Accent used for "speaking" / tertiary purple moments. */
    val accentPurple: Color = statusPurple,
    /** A glass-panel fill (semi-transparent surface for layered cards). */
    val glassFill: Color = surfaceRaised,
    /** Hairline used on glass panels / elevated surfaces. */
    val glassBorder: Color = border,
    /** Soft tint behind selected / highlighted rows. */
    val accentSoft: Color = infoBg,
    /** Ambient page-tint used at the bottom of the hero background wash. */
    val backdropTint: Color = surfaceRaised,
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
    primary            = JarvisBrand.electricBlue,        // electric blue CTA
    onPrimary          = Color.White,
    primaryContainer   = Color(0xFFDCE7FF),               // soft blue chip fill
    onPrimaryContainer = Color(0xFF0B2A6B),
    secondary          = JarvisBrand.violetOnLight,       // clean purple
    onSecondary        = Color.White,
    secondaryContainer = Color(0xFFEDE6FF),
    onSecondaryContainer = Color(0xFF34146E),
    tertiary           = Color(0xFF0E7490),               // deep cyan
    onTertiary         = Color.White,
    background         = Color(0xFFFAFBFE),               // near-white, faint blue
    onBackground       = Color(0xFF121622),               // ink
    surface            = Color.White,
    onSurface          = Color(0xFF121622),
    surfaceVariant     = Color(0xFFEEF2F9),               // warm blue-grey card
    onSurfaceVariant   = Color(0xFF49506B),               // muted slate label
    error              = JarvisBrand.redOnLight,
    onError            = Color.White,
    outline            = Color(0xFFD3DAE8),               // hairline on white
    outlineVariant     = Color(0xFFE6EBF4),
)

internal val LightExtras = JarvisExtraColors(
    surfaceRaised = Color(0xFFFFFFFF),
    divider       = Color(0xFFEAEEF6),
    border        = Color(0xFFDCE2EE),
    textMuted     = Color(0xFF5B6275),
    textFaint     = Color(0xFF9097AB),
    statusGreen   = JarvisBrand.greenOnLight,
    statusAmber   = JarvisBrand.amberOnLight,
    statusPurple  = JarvisBrand.violetOnLight,
    statusRed     = JarvisBrand.redOnLight,
    infoBg        = Color(0xFFEAF2FF),
    successBg     = Color(0xFFE7F7EF),
    accentCyan    = Color(0xFF0E7490),
    accentPurple  = JarvisBrand.violetOnLight,
    glassFill     = Color(0xF2FFFFFF),                    // 95% white glass
    glassBorder   = Color(0x14122149),                   // faint ink hairline
    accentSoft    = Color(0xFFEAF2FF),
    backdropTint  = Color(0xFFEFF4FC),
)
