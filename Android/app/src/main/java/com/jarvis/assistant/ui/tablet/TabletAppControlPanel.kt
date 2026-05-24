package com.jarvis.assistant.ui.tablet

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jarvis.assistant.accessibility.JarvisAccessibilityService
import kotlinx.coroutines.delay

// ── Palette ───────────────────────────────────────────────────────────────────
private val PanelBg    = Color(0xFF060B14)   // deepest navy
private val CardBg     = Color(0xFF0B1628)   // card surface
private val TileBg     = Color(0xFF11203A)   // elevated tile surface
private val TextPri    = Color(0xFFCCE0F0)   // blue-tinted body text
private val TextMuted  = Color(0xFF7A8FAA)   // blue-grey secondary labels
private val CyanHigh   = Color(0xFF3FA7FF)   // blueprint blue
private val GreenOk    = Color(0xFF00E676)   // status green
private val AmberHint  = Color(0xFFFFAB40)   // status amber
private val RedBad     = Color(0xFFFF5252)   // status red
private val BorderC    = Color(0xFF0E1C33)   // divider

// ── Quick-launch app descriptor ───────────────────────────────────────────────
private data class QuickApp(
    val label       : String,
    val packageName : String?,
    val action      : String? = null,
    val icon        : ImageVector,
    val tint        : Color,
)

private val QUICK_APPS = listOf(
    QuickApp("Phone",    "com.google.android.dialer",       icon = Icons.Filled.Call,          tint = GreenOk),
    QuickApp("Messages", null, Intent.ACTION_MAIN,          icon = Icons.Filled.Message,       tint = CyanHigh),
    QuickApp("Camera",   "com.android.camera2",             icon = Icons.Filled.CameraAlt,     tint = AmberHint),
    QuickApp("Maps",     "com.google.android.apps.maps",    icon = Icons.Filled.Map,           tint = Color(0xFF00E5FF)),
    QuickApp("YouTube",  "com.google.android.youtube",      icon = Icons.Filled.PlayArrow,     tint = Color(0xFFFF1744)),
    QuickApp("Spotify",  "com.spotify.music",               icon = Icons.Filled.MusicNote,     tint = GreenOk),
    QuickApp("Settings", "com.android.settings",            icon = Icons.Filled.Settings,      tint = TextMuted),
    QuickApp("Calendar", "com.google.android.calendar",     icon = Icons.Filled.CalendarToday, tint = Color(0xFFCE93D8)),
    QuickApp("Chrome",   "com.android.chrome",              icon = Icons.Filled.Language,      tint = Color(0xFFFFAB00)),
    QuickApp("WhatsApp", "com.whatsapp",                    icon = Icons.Filled.Chat,          tint = GreenOk),
    QuickApp("Gmail",    "com.google.android.gm",           icon = Icons.Filled.Email,         tint = AmberHint),
    QuickApp("Files",    "com.google.android.documentsui",  icon = Icons.Filled.Folder,        tint = CyanHigh),
)

// Max recent-app entries to track
private const val RECENT_CAP = 6

/**
 * TabletAppControlPanel — full app-control surface for the tablet shell.
 *
 * Features:
 *  - Accessibility service status badge with deep-link to fix
 *  - Live foreground app tracking (polls [JarvisAccessibilityService.currentForegroundPackage])
 *  - Rolling recent-apps list (up to [RECENT_CAP] unique packages, most-recent first)
 *  - OS global actions: Back / Home / Recents / Screenshot
 *  - Quick-launch grid for common apps
 *  - Voice command hints
 */
@Composable
internal fun TabletAppControlPanel(vm: TabletViewModel) {
    val context = LocalContext.current
    val pm      = context.packageManager

    // ── Live accessibility state ──────────────────────────────────────────────
    var a11yConnected by remember { mutableStateOf(JarvisAccessibilityService.isConnected()) }
    var foregroundPkg by remember { mutableStateOf(JarvisAccessibilityService.currentForegroundPackage) }
    // Rolling history of recently-seen packages (newest first, no duplicates, excludes own pkg)
    val recentApps = remember { mutableStateListOf<String>() }

    LaunchedEffect(Unit) {
        while (true) {
            a11yConnected = JarvisAccessibilityService.isConnected()
            val pkg = JarvisAccessibilityService.currentForegroundPackage
            if (pkg != null && pkg != foregroundPkg) {
                foregroundPkg = pkg
                // Maintain rolling list
                if (pkg != context.packageName) {
                    recentApps.remove(pkg)          // remove if already present
                    recentApps.add(0, pkg)          // insert at front
                    while (recentApps.size > RECENT_CAP) recentApps.removeLastOrNull()
                }
            }
            delay(1_500)
        }
    }

    // Helper: resolve a human-readable app label from a package name
    fun labelFor(pkg: String): String = try {
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: PackageManager.NameNotFoundException) { pkg }

    // Helper: launch a package, returns false if unavailable
    fun launchPackage(pkg: String): Boolean {
        val intent = pm.getLaunchIntentForPackage(pkg)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) ?: return false
        return try { context.startActivity(intent); true } catch (_: Exception) { false }
    }

    LazyColumn(
        modifier       = Modifier
            .fillMaxSize()
            .background(PanelBg),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 14.dp),
    ) {
        // ── Header ─────────────────────────────────────────────────────────────
        item {
            Row(
                modifier              = Modifier.fillMaxWidth(),
                verticalAlignment     = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                PanelHeader(label = "APPS", icon = Icons.Filled.Apps)
                A11yStatusBadge(connected = a11yConnected, onFix = {
                    context.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                })
            }
            Spacer(Modifier.height(12.dp))
        }

        // ── Accessibility service status (expanded diagnostics if not connected) ─
        if (!a11yConnected) {
            item {
                A11yDiagnosticsCard(onOpenSettings = {
                    context.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                })
                Spacer(Modifier.height(12.dp))
            }
        }

        // ── OS global action buttons ───────────────────────────────────────────
        item {
            GlobalActionsRow(enabled = a11yConnected)
            Spacer(Modifier.height(16.dp))
            HorizontalDivider(color = BorderC)
            Spacer(Modifier.height(12.dp))
        }

        // ── Current foreground app ─────────────────────────────────────────────
        item {
            SectionLabel("FOREGROUND APP")
            Spacer(Modifier.height(6.dp))
            if (foregroundPkg != null) {
                ForegroundAppCard(
                    pkg      = foregroundPkg!!,
                    label    = labelFor(foregroundPkg!!),
                    onLaunch = { launchPackage(foregroundPkg!!) },
                )
            } else {
                EmptyCard(
                    if (a11yConnected)
                        "No foreground app detected yet."
                    else
                        "Enable accessibility service to track foreground app."
                )
            }
            Spacer(Modifier.height(14.dp))
        }

        // ── Recent apps list ───────────────────────────────────────────────────
        item {
            SectionLabel("RECENT APPS")
            Spacer(Modifier.height(6.dp))
        }

        if (recentApps.isEmpty()) {
            item {
                EmptyCard("Recent apps appear here once you switch between apps.")
                Spacer(Modifier.height(14.dp))
            }
        } else {
            items(recentApps.size) { idx ->
                val pkg = recentApps[idx]
                RecentAppRow(
                    pkg      = pkg,
                    label    = labelFor(pkg),
                    onLaunch = { launchPackage(pkg) },
                )
            }
            item { Spacer(Modifier.height(14.dp)) }
        }

        // ── Quick-launch grid ──────────────────────────────────────────────────
        item {
            HorizontalDivider(color = BorderC)
            Spacer(Modifier.height(12.dp))
            SectionLabel("QUICK LAUNCH")
            Spacer(Modifier.height(10.dp))
            // LazyVerticalGrid inside LazyColumn needs a fixed height
            val rowCount = (QUICK_APPS.size + 3) / 4  // ~4 columns at ~90dp min
            val gridHeight = (rowCount * 80).dp
            LazyVerticalGrid(
                columns               = GridCells.Adaptive(minSize = 90.dp),
                modifier              = Modifier.fillMaxWidth().height(gridHeight),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalArrangement   = Arrangement.spacedBy(10.dp),
                userScrollEnabled     = false,
            ) {
                items(QUICK_APPS) { app ->
                    AppTile(app = app, onClick = {
                        val intent = if (app.packageName != null) {
                            pm.getLaunchIntentForPackage(app.packageName)
                                ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        } else {
                            Intent(app.action ?: Intent.ACTION_MAIN)
                                .addCategory(Intent.CATEGORY_APP_MESSAGING)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        intent?.let { try { context.startActivity(it) } catch (_: Exception) {} }
                    })
                }
            }
            Spacer(Modifier.height(14.dp))
        }

        // ── Voice hints ────────────────────────────────────────────────────────
        item {
            VoiceHints(
                hints = listOf(
                    "\"Jarvis, open [app name]\"",
                    "\"Jarvis, close this app\"",
                    "\"Jarvis, go home\"",
                    "\"Jarvis, show recent apps\"",
                )
            )
        }
    }
}

// ── Accessibility status badge ────────────────────────────────────────────────

@Composable
private fun A11yStatusBadge(connected: Boolean, onFix: () -> Unit) {
    val (label, bg, fg) = if (connected)
        Triple("A11Y ●", GreenOk.copy(alpha = 0.15f), GreenOk)
    else
        Triple("A11Y ✕", RedBad.copy(alpha = 0.15f), RedBad)

    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(bg)
            .then(if (!connected) Modifier.clickable(onClick = onFix) else Modifier)
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Text(
            label,
            color      = fg,
            fontSize   = 9.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
        )
    }
}

// ── Accessibility diagnostics card ────────────────────────────────────────────

@Composable
private fun A11yDiagnosticsCard(onOpenSettings: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(RedBad.copy(alpha = 0.08f))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                Icons.Filled.Warning,
                contentDescription = null,
                tint     = RedBad,
                modifier = Modifier.size(16.dp),
            )
            Text(
                "Accessibility Service Disconnected",
                color      = RedBad,
                fontSize   = 12.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
            )
        }
        Text(
            "Jarvis needs accessibility access for:\n" +
            "  • Foreground app tracking\n" +
            "  • Global actions (Home / Back / Recents)\n" +
            "  • Auto-send in WhatsApp\n" +
            "  • Screen reading and tap control",
            color      = TextPri.copy(alpha = 0.75f),
            fontSize   = 11.sp,
            fontFamily = FontFamily.Monospace,
            lineHeight = 17.sp,
        )
        OutlinedButton(
            onClick = onOpenSettings,
            shape   = RoundedCornerShape(8.dp),
            colors  = ButtonDefaults.outlinedButtonColors(contentColor = AmberHint),
            border  = androidx.compose.foundation.BorderStroke(1.dp, AmberHint.copy(alpha = 0.5f)),
        ) {
            Icon(Icons.Filled.OpenInNew, contentDescription = null, modifier = Modifier.size(13.dp))
            Spacer(Modifier.width(6.dp))
            Text("Open Accessibility Settings", fontSize = 11.sp, fontFamily = FontFamily.Monospace)
        }
    }
}

// ── Global action row ─────────────────────────────────────────────────────────

@Composable
private fun GlobalActionsRow(enabled: Boolean) {
    Row(
        modifier              = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        GlobalActionButton(
            label   = "Back",
            icon    = Icons.Filled.ArrowBack,
            enabled = enabled,
            onClick = { JarvisAccessibilityService.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK) },
        )
        GlobalActionButton(
            label   = "Home",
            icon    = Icons.Filled.Home,
            enabled = enabled,
            onClick = { JarvisAccessibilityService.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME) },
        )
        GlobalActionButton(
            label   = "Recents",
            icon    = Icons.Filled.Layers,
            enabled = enabled,
            onClick = { JarvisAccessibilityService.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS) },
        )
        GlobalActionButton(
            label   = "Screenshot",
            icon    = Icons.Filled.Screenshot,
            enabled = enabled,
            onClick = { JarvisAccessibilityService.performGlobalAction(AccessibilityService.GLOBAL_ACTION_TAKE_SCREENSHOT) },
        )
    }
}

@Composable
private fun RowScope.GlobalActionButton(
    label   : String,
    icon    : ImageVector,
    enabled : Boolean,
    onClick : () -> Unit,
) {
    OutlinedButton(
        onClick        = onClick,
        enabled        = enabled,
        shape          = RoundedCornerShape(8.dp),
        modifier       = Modifier.weight(1f).height(44.dp),
        colors         = ButtonDefaults.outlinedButtonColors(
            contentColor         = CyanHigh,
            disabledContentColor = TextMuted,
        ),
        border         = androidx.compose.foundation.BorderStroke(
            1.dp,
            if (enabled) CyanHigh.copy(alpha = 0.4f) else BorderC,
        ),
        contentPadding = PaddingValues(horizontal = 4.dp, vertical = 4.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, contentDescription = label, modifier = Modifier.size(16.dp))
            Text(label, fontSize = 8.sp, fontFamily = FontFamily.Monospace)
        }
    }
}

// ── Foreground app card ───────────────────────────────────────────────────────

@Composable
private fun ForegroundAppCard(
    pkg     : String,
    label   : String,
    onLaunch: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(CardBg)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment     = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(RoundedCornerShape(4.dp))
                .background(GreenOk),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                label,
                color      = TextPri,
                fontSize   = 14.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
            )
            Text(
                pkg,
                color      = TextMuted,
                fontSize   = 9.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
        IconButton(
            onClick  = onLaunch,
            modifier = Modifier.size(32.dp),
        ) {
            Icon(
                Icons.Filled.OpenInNew,
                contentDescription = "Re-open",
                tint     = CyanHigh,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

// ── Recent app row ────────────────────────────────────────────────────────────

@Composable
private fun RecentAppRow(
    pkg     : String,
    label   : String,
    onLaunch: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(PanelBg)
            .clickable(onClick = onLaunch)
            .padding(horizontal = 4.dp, vertical = 8.dp),
        verticalAlignment     = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            Icons.Filled.History,
            contentDescription = null,
            tint     = TextMuted,
            modifier = Modifier.size(14.dp),
        )
        Text(
            label,
            color      = TextPri.copy(alpha = 0.85f),
            fontSize   = 12.sp,
            fontFamily = FontFamily.Monospace,
            modifier   = Modifier.weight(1f),
        )
        Text(
            pkg.substringAfterLast('.'),
            color      = TextMuted,
            fontSize   = 9.sp,
            fontFamily = FontFamily.Monospace,
        )
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = "Open",
            tint     = TextMuted,
            modifier = Modifier.size(14.dp),
        )
    }
    HorizontalDivider(color = BorderC, modifier = Modifier.padding(start = 28.dp))
}

// ── Section label ─────────────────────────────────────────────────────────────

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        color        = TextMuted,
        fontSize     = 8.sp,
        fontFamily   = FontFamily.Monospace,
        letterSpacing = 2.sp,
        fontWeight   = FontWeight.Bold,
    )
}

// ── App tile (quick-launch grid) ──────────────────────────────────────────────

@Composable
private fun AppTile(app: QuickApp, onClick: () -> Unit) {
    Column(
        modifier = Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(TileBg)
            .clickable(onClick = onClick)
            .padding(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector        = app.icon,
            contentDescription = app.label,
            tint               = app.tint,
            modifier           = Modifier.size(28.dp),
        )
        Text(
            app.label,
            color      = TextPri,
            fontSize   = 10.sp,
            fontFamily = FontFamily.Monospace,
            maxLines   = 1,
        )
    }
}
