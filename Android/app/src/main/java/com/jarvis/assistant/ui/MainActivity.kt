package com.jarvis.assistant.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import com.jarvis.assistant.auth.OAuthCallbackHolder
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalConfiguration
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.rememberMultiplePermissionsState
import com.jarvis.assistant.ui.tablet.TabletNavHost
import com.jarvis.assistant.ui.theme.JarvisTheme
import com.jarvis.assistant.ui.theme.JarvisThemeMode
import com.jarvis.assistant.util.SettingsStore

/**
 * MainActivity — the single Activity in the app.
 *
 * RESPONSIBILITIES:
 *  1. Request all runtime permissions (mic, notifications, boot).
 *  2. Explain why we need battery-optimisation exemption, then request it.
 *  3. Host the Compose NavHost with two routes: main and settings.
 *
 * WHY ONE ACTIVITY?
 * Jetpack Compose works best with a single Activity. Navigation between
 * "screens" is handled by NavHost in Compose, not by starting new Activities.
 */
class MainActivity : ComponentActivity() {

    @OptIn(ExperimentalPermissionsApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            // Theme preferences are stored in EncryptedSharedPreferences and
            // read once per composition.  Switching the radio in Settings
            // recreates the Activity (handled by SettingsViewModel) so this
            // doesn't need to observe; a flow-backed read can land in a
            // future pass once the rest of settings move to DataStore.
            val settings = remember { SettingsStore(this@MainActivity) }
            val themeMode = remember(settings.themeMode) {
                when (settings.themeMode.lowercase()) {
                    "light"  -> JarvisThemeMode.LIGHT
                    "dark"   -> JarvisThemeMode.DARK
                    "amoled" -> JarvisThemeMode.AMOLED
                    else     -> JarvisThemeMode.SYSTEM
                }
            }
            JarvisTheme(
                mode         = themeMode,
                dynamicColor = settings.dynamicColor,
            ) {
                // ── Permission gating ─────────────────────────────────────
                // Build the list of permissions we need at runtime.
                // Some are only required on newer API levels.
                val runtimePermissions = buildList {
                    add(Manifest.permission.RECORD_AUDIO)
                    add(Manifest.permission.CALL_PHONE)
                    add(Manifest.permission.READ_CONTACTS)
                    add(Manifest.permission.SEND_SMS)
                    add(Manifest.permission.ACCESS_COARSE_LOCATION)
                    add(Manifest.permission.ACCESS_FINE_LOCATION)
                    // BLUETOOTH_CONNECT is a runtime permission from Android 12 (S) onwards.
                    // Required to query connected headsets and route audio through SCO.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        add(Manifest.permission.BLUETOOTH_CONNECT)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        add(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }

                val permissionState = rememberMultiplePermissionsState(runtimePermissions)

                // Battery optimisation dialog state
                var showBatteryDialog by remember { mutableStateOf(false) }

                // Once all runtime permissions granted, check battery optimisation
                LaunchedEffect(permissionState.allPermissionsGranted) {
                    if (permissionState.allPermissionsGranted) {
                        showBatteryDialog = !isBatteryOptimisationIgnored()
                    }
                }

                if (!permissionState.allPermissionsGranted) {
                    PermissionRationaleScreen(
                        onRequest = { permissionState.launchMultiplePermissionRequest() }
                    )
                } else {
                    // All permissions granted — show app
                    val configuration = LocalConfiguration.current
                    if (configuration.smallestScreenWidthDp >= 600) {
                        TabletNavHost()
                    } else {
                        AppNavHost()
                    }
                }

                // Battery optimisation dialog
                if (showBatteryDialog) {
                    BatteryOptimisationDialog(
                        onConfirm = {
                            showBatteryDialog = false
                            requestBatteryOptimisationExemption()
                        },
                        onDismiss = { showBatteryDialog = false }
                    )
                }
            }
        }
    }

    /**
     * Called when the app is already running and receives a new Intent —
     * specifically the OAuth redirect: com.jarvis.assistant://oauth/callback?code=...
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = intent.data ?: return
        if (uri.scheme == "com.jarvis.assistant" && uri.host == "oauth") {
            val code = uri.getQueryParameter("code") ?: return
            OAuthCallbackHolder.invoke(code)
        }
    }

    private fun isBatteryOptimisationIgnored(): Boolean {
        val pm = getSystemService(android.os.PowerManager::class.java)
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestBatteryOptimisationExemption() {
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }
        startActivity(intent)
    }
}

// ── Navigation ─────────────────────────────────────────────────────────────────

@Composable
private fun AppNavHost() {
    val nav = rememberNavController()

    NavHost(navController = nav, startDestination = "main") {
        composable("main") {
            MainScreen(onOpenSettings = { nav.navigate("settings") })
        }
        composable("settings") {
            SettingsScreen(onBack = { nav.popBackStack() })
        }
    }
}

// ── Permission rationale screen ────────────────────────────────────────────────

@Composable
private fun PermissionRationaleScreen(onRequest: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                androidx.compose.ui.graphics.Brush.verticalGradient(
                    com.jarvis.assistant.ui.theme.JarvisGradients.lightBackdrop
                )
            ),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(8.dp))
            Text(
                "Let's get Jarvis set up",
                color = scheme.onBackground,
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
            )
            Text(
                "Jarvis only asks for what it needs to be useful. You can change any of " +
                    "these later in Settings.",
                color = scheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(bottom = 4.dp),
            )

            PermissionItem("Microphone", "So Jarvis can hear you when you talk or say its name.")
            PermissionItem("Phone & Contacts", "So you can say “call Sarah” and Jarvis knows who you mean.")
            PermissionItem("Messages", "So you can send a text hands-free — “text Alex I'm on my way”.")
            PermissionItem("Location", "For nearby answers, directions and commute times.")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PermissionItem("Bluetooth", "To use a headset for hands-free voice.")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                PermissionItem("Notifications", "To show a quiet “listening” status while Jarvis runs.")
            }

            Spacer(Modifier.height(8.dp))

            com.jarvis.assistant.ui.components.JarvisButton(
                text = "Continue",
                onClick = onRequest,
                fillWidth = true,
            )
            Text(
                "You'll be asked to confirm each permission on the next screen.",
                color = scheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun PermissionItem(name: String, reason: String) {
    val scheme = MaterialTheme.colorScheme
    com.jarvis.assistant.ui.components.JarvisCard(
        shape = com.jarvis.assistant.ui.theme.JarvisTokens.Shape.card,
        contentPadding = PaddingValues(16.dp),
    ) {
        Text(name, color = scheme.onSurface, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(reason, color = scheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
    }
}

// ── Battery optimisation dialog ────────────────────────────────────────────────

@Composable
private fun BatteryOptimisationDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = scheme.surface,
        shape = RoundedCornerShape(24.dp),
        title = {
            Text("Keep Jarvis running", color = scheme.onSurface, fontWeight = FontWeight.Bold)
        },
        text = {
            Text(
                "Android can pause Jarvis when the screen turns off to save battery. " +
                "To stay ready to listen, Jarvis needs to be exempt from battery " +
                "optimisation. Tap Allow to open the system screen.",
                color = scheme.onSurfaceVariant,
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("Allow", color = scheme.primary, fontWeight = FontWeight.Bold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Not now", color = scheme.onSurfaceVariant)
            }
        }
    )
}

// JarvisTheme moved to com.jarvis.assistant.ui.theme.JarvisTheme — supports
// system/light/dark/AMOLED variants and dynamic colour on Android 12+.
