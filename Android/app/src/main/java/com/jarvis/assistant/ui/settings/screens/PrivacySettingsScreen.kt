package com.jarvis.assistant.ui.settings.screens

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.speaker.db.PersonRecord
import com.jarvis.assistant.trust.AutonomyPreset
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.*

/**
 * Privacy & Data — unified screen replacing the former Privacy, Memory and
 * Trust & Autonomy sub-screens.
 *
 * Sections:
 *  1. App permissions + special access
 *  2. Control (tool kill-switch, boot, service)
 *  3. Accounts
 *  4. Memory (speaker profiles, stored data)
 *  5. How Jarvis decides (autonomy preset + confirmations + context trust)
 */
@Composable
internal fun PrivacySettingsScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    // ── Existing privacy state ────────────────────────────────────────────────
    val signedIn   by vm.openAiSignedIn.collectAsStateWithLifecycle()
    val killSwitch by vm.toolExecutionDisabled.collectAsStateWithLifecycle()
    val autoStart  by vm.autoStartOnBoot.collectAsStateWithLifecycle()

    // ── Memory state ──────────────────────────────────────────────────────────
    val profiles by vm.speakerProfiles.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.loadSpeakerProfiles() }

    // ── Trust & Autonomy state ────────────────────────────────────────────────
    val autonomyRepo  = JarvisApp.autonomySettingsRepo
    val autonomyState by autonomyRepo.settingsFlow.collectAsState()
    val learnedTrust  = JarvisApp.learnedTrustStore

    // ── Runtime permission checks (refresh on resume) ─────────────────────────
    var micOk           by remember { mutableStateOf(false) }
    var notifOk         by remember { mutableStateOf(false) }
    var contactsOk      by remember { mutableStateOf(false) }
    var smsOk           by remember { mutableStateOf(false) }
    var phoneOk         by remember { mutableStateOf(false) }
    var calendarOk      by remember { mutableStateOf(false) }
    var locationOk      by remember { mutableStateOf(false) }
    var cameraOk        by remember { mutableStateOf(false) }
    var accessibilityOk by remember { mutableStateOf(false) }
    var overlayOk       by remember { mutableStateOf(false) }
    var batteryOk       by remember { mutableStateOf(false) }

    fun refreshPermissions() {
        micOk           = PermissionUtils.isMicrophoneGranted(context)
        notifOk         = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                              PermissionUtils.isGranted(context, android.Manifest.permission.POST_NOTIFICATIONS)
                          else true
        contactsOk      = PermissionUtils.isGranted(context, android.Manifest.permission.READ_CONTACTS)
        smsOk           = PermissionUtils.isGranted(context, android.Manifest.permission.SEND_SMS)
        phoneOk         = PermissionUtils.isGranted(context, android.Manifest.permission.CALL_PHONE)
        calendarOk      = PermissionUtils.isGranted(context, android.Manifest.permission.READ_CALENDAR)
        locationOk      = PermissionUtils.isGranted(context, android.Manifest.permission.ACCESS_FINE_LOCATION)
        cameraOk        = PermissionUtils.isGranted(context, android.Manifest.permission.CAMERA)
        accessibilityOk = PermissionUtils.isAccessibilityServiceEnabled(context)
        overlayOk       = PermissionUtils.canDrawOverlays(context)
        batteryOk       = context.getSystemService(android.os.PowerManager::class.java)
                              ?.isIgnoringBatteryOptimizations(context.packageName) == true
    }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) refreshPermissions()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    SettingsScaffold(title = "Privacy & Data", onBack = onBack, onClose = onClose) {

        // ── App permissions ───────────────────────────────────────────────────
        SettingsGroup(title = "App Permissions") {
            PermissionRow(
                title = "Microphone",
                reason = "Required to hear wake words and commands.",
                granted = micOk,
                onFix = { openAppSettings(context) }
            )
            SettingsRowDivider()
            PermissionRow(
                title = "Notifications",
                reason = "Required to show persistent status.",
                granted = notifOk,
                onFix = { openAppSettings(context) }
            )
            SettingsRowDivider()
            PermissionRow(
                title = "Contacts",
                reason = "Required to look up names for messaging.",
                granted = contactsOk,
                onFix = { openAppSettings(context) }
            )
            SettingsRowDivider()
            PermissionRow(
                title = "SMS",
                reason = "Required to send text messages.",
                granted = smsOk,
                onFix = { openAppSettings(context) }
            )
            SettingsRowDivider()
            PermissionRow(
                title = "Phone",
                reason = "Required to make phone calls.",
                granted = phoneOk,
                onFix = { openAppSettings(context) }
            )
            SettingsRowDivider()
            PermissionRow(
                title = "Calendar",
                reason = "Required to read/add events.",
                granted = calendarOk,
                onFix = { openAppSettings(context) }
            )
            SettingsRowDivider()
            PermissionRow(
                title = "Location",
                reason = "Required for weather and navigation.",
                granted = locationOk,
                onFix = { openAppSettings(context) }
            )
            SettingsRowDivider()
            PermissionRow(
                title = "Camera",
                reason = "Required to take photos.",
                granted = cameraOk,
                onFix = { openAppSettings(context) }
            )
        }

        // ── Special access ────────────────────────────────────────────────────
        SettingsGroup(title = "Special Access") {
            PermissionRow(
                title = "Accessibility",
                reason = "Required for WhatsApp auto-send and screen reading.",
                granted = accessibilityOk,
                onFix = {
                    context.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                }
            )
            SettingsRowDivider()
            PermissionRow(
                title = "Battery Optimisation",
                reason = "Required to prevent Android killing Jarvis in background.",
                granted = batteryOk,
                onFix = {
                    try {
                        context.startActivity(
                            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                data = Uri.parse("package:${context.packageName}")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                        )
                    } catch (_: Exception) {}
                }
            )
            SettingsRowDivider()
            PermissionRow(
                title = "Display over other apps",
                reason = "Required for overlay cards.",
                granted = overlayOk,
                onFix = {
                    try {
                        context.startActivity(
                            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
                                data = Uri.parse("package:${context.packageName}")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                        )
                    } catch (_: Exception) {}
                }
            )
        }

        // ── Control ───────────────────────────────────────────────────────────
        SettingsGroup(
            title  = "Control",
            footer = "Pausing tool execution keeps conversation working but blocks every " +
                     "device action until the toggle is turned back on.",
        ) {
            SettingsToggleRow(
                title           = "Pause tool execution",
                description     = "Disable every tool while still allowing conversation.",
                checked         = killSwitch,
                onCheckedChange = vm::setToolExecutionDisabled,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Start Jarvis on boot",
                description     = "When off, Jarvis stays idle after device reboot.",
                checked         = autoStart,
                onCheckedChange = vm::setAutoStartOnBoot,
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Stop Jarvis now",
                description = "Shut down the foreground service until you relaunch the app.",
                actionLabel = "Stop service",
                destructive = true,
                confirm     = true,
                confirmCopy = "Stop",
                onAction    = vm::stopJarvisService,
            )
        }

        // ── Accounts ──────────────────────────────────────────────────────────
        SettingsGroup(title = "Accounts") {
            if (signedIn) {
                SettingsActionRow(
                    title       = "OpenAI account",
                    description = "You're signed in with OAuth. Sign out to revoke access.",
                    actionLabel = "Sign out",
                    destructive = true,
                    confirm     = true,
                    confirmCopy = "Sign out",
                    onAction    = vm::signOutOpenAi,
                )
            } else {
                SettingsInfoCard(
                    title = "OpenAI account",
                    body  = "Not signed in. Sign in from Advanced → LLM provider.",
                )
            }
        }
        Spacer(Modifier.height(8.dp))

        // ── Memory ────────────────────────────────────────────────────────────
        SettingsGroup(
            title  = "Speaker profiles",
            footer = "Jarvis learns voices over time. Say your name when it asks \"Who's this?\" " +
                     "to start enrolling.",
        ) {
            if (profiles.isEmpty()) {
                SettingsInfoCard(
                    title = "No profiles yet",
                    body  = "As Jarvis meets people it will build a voice profile for each one.",
                )
            } else {
                profiles.forEachIndexed { index, person ->
                    SpeakerRow(person = person, onDelete = { vm.deleteSpeakerProfile(person.id) })
                    if (index < profiles.lastIndex) SettingsRowDivider()
                }
            }
        }

        SettingsGroup(
            title  = "Stored data",
            footer = "Both actions are permanent and can't be undone.",
        ) {
            SettingsActionRow(
                title       = "Conversation history",
                description = "Raw dialogue logs — does not remove learned preferences or profile facts.",
                actionLabel = "Clear conversation history",
                destructive = true,
                confirm     = true,
                confirmCopy = "Clear history",
                onAction    = vm::clearConversationHistory,
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Learned memories",
                description = "Everything Jarvis remembers about you — preferences, facts and summaries.",
                actionLabel = "Clear all memories",
                destructive = true,
                confirm     = true,
                confirmCopy = "Clear memories",
                onAction    = vm::clearAllMemories,
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── How Jarvis decides ────────────────────────────────────────────────
        SettingsInfoCard(
            title = "How Jarvis decides",
            body  = "Jarvis evaluates trust signals (voice, session, location context) " +
                    "to decide whether to act immediately or ask first. " +
                    "The preset controls the baseline; per-category overrides let you fine-tune.",
        )

        SettingsGroup(
            title  = "Autonomy preset",
            footer = "Conservative always asks for medium-risk actions. " +
                     "Balanced auto-approves when trust is high. " +
                     "Jarvis-style minimises interruptions.",
        ) {
            SettingsDropdownRow(
                title       = "Preset",
                description = "Overall decision-making stance.",
                options     = AutonomyPreset.entries,
                selected    = autonomyState.preset,
                label       = { preset ->
                    preset.name.replace('_', ' ').lowercase().replaceFirstChar { it.uppercase() }
                },
                onSelected  = { autonomyRepo.setPreset(it) },
            )
        }

        SettingsGroup(
            title       = "Action confirmations",
            description = "Always ask before these action types, regardless of trust score",
        ) {
            SettingsToggleRow(
                title           = "Confirm before sending messages",
                description     = "SMS, WhatsApp and email sends",
                checked         = autonomyState.requireConfirmForMessages,
                onCheckedChange = { autonomyRepo.setRequireConfirmForMessages(it) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Confirm before calls",
                description     = "Outgoing phone calls",
                checked         = autonomyState.requireConfirmForCalls,
                onCheckedChange = { autonomyRepo.setRequireConfirmForCalls(it) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Confirm before sharing media",
                description     = "Photos and visual follow-ups",
                checked         = autonomyState.requireConfirmForMediaShare,
                onCheckedChange = { autonomyRepo.setRequireConfirmForMediaShare(it) },
            )
        }

        SettingsGroup(
            title       = "Context-sensitive trust",
            description = "Signals that relax or restrict autonomy",
        ) {
            SettingsToggleRow(
                title           = "Lockscreen restrictions",
                description     = "Block sensitive reads and sends when the screen is locked",
                checked         = autonomyState.lockscreenRestrictions,
                onCheckedChange = { autonomyRepo.setLockscreenRestrictions(it) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Car mode — maximise autonomy",
                description     = "Auto-approve low and medium-risk actions while driving",
                checked         = autonomyState.carModeAutonomy,
                onCheckedChange = { autonomyRepo.setCarModeAutonomy(it) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Headphones as private context",
                description     = "Treat headphones as a signal that you're in private — relaxes some confirmations",
                checked         = autonomyState.headphonesPrivateMode,
                onCheckedChange = { autonomyRepo.setHeadphonesPrivateMode(it) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Home Wi-Fi as trusted context",
                description     = "Relax confirmations when connected to your home network",
                checked         = autonomyState.homeTrustedMode,
                onCheckedChange = { autonomyRepo.setHomeTrustedMode(it) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Voice identity trust",
                description     = "Use voice match as an additional trust signal",
                checked         = autonomyState.voiceTrustEnabled,
                onCheckedChange = { autonomyRepo.setVoiceTrustEnabled(it) },
            )
        }

        SettingsGroup(
            title       = "Learned preferences",
            description = "Patterns Jarvis has picked up from your confirmations",
        ) {
            SettingsActionRow(
                title       = "Reset learned decisions",
                description = "Clear all \"stop asking me that\" and auto-approval streaks",
                actionLabel = "Reset",
                destructive = true,
                confirm     = true,
                onAction    = {
                    learnedTrust.clearAll()
                    Toast.makeText(context, "Learned trust data cleared", Toast.LENGTH_SHORT).show()
                },
            )
        }

        Spacer(Modifier.height(24.dp))
    }
}

// ── Private composables ───────────────────────────────────────────────────────

@Composable
private fun SpeakerRow(person: PersonRecord, onDelete: () -> Unit) {
    val statusLabel = when (person.typedEnrollmentStatus) {
        PersonRecord.EnrollmentStatus.NONE       -> "No voice samples"
        PersonRecord.EnrollmentStatus.TRAINING   -> "Training · ${person.enrolledUtteranceCount} samples"
        PersonRecord.EnrollmentStatus.SUFFICIENT -> "Sufficient · ${person.enrolledUtteranceCount} samples"
        PersonRecord.EnrollmentStatus.ENROLLED   -> "Enrolled · ${person.enrolledUtteranceCount} samples"
    }
    val statusColor = when (person.typedEnrollmentStatus) {
        PersonRecord.EnrollmentStatus.ENROLLED   -> SettingsTheme.Success
        PersonRecord.EnrollmentStatus.SUFFICIENT -> androidx.compose.ui.graphics.Color(0xFFFFD600)
        PersonRecord.EnrollmentStatus.TRAINING   -> androidx.compose.ui.graphics.Color(0xFFFF9800)
        PersonRecord.EnrollmentStatus.NONE       -> SettingsTheme.TextMuted
    }

    var confirming by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Filled.Person,
            contentDescription = null,
            tint = if (person.isOwner) SettingsTheme.Cyan else SettingsTheme.TextMuted,
            modifier = Modifier.size(22.dp),
        )
        Column(modifier = Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    person.displayName,
                    color = SettingsTheme.TextPrimary,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                )
                if (person.isOwner) {
                    Text(
                        "Owner",
                        color = SettingsTheme.Cyan,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier
                            .background(SettingsTheme.Cyan.copy(alpha = 0.15f), SettingsTheme.ChipShape)
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                }
            }
            Text(statusLabel, color = statusColor, fontSize = 11.sp)
        }
        if (confirming) {
            TextButton(onClick = { confirming = false }) {
                Text("Cancel", color = SettingsTheme.TextMuted, fontSize = 12.sp)
            }
            TextButton(onClick = { onDelete(); confirming = false }) {
                Text("Delete", color = SettingsTheme.Destructive, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            }
        } else {
            IconButton(onClick = { confirming = true }, modifier = Modifier.size(32.dp)) {
                Icon(
                    Icons.Filled.Delete,
                    contentDescription = "Delete ${person.displayName}",
                    tint = SettingsTheme.TextMuted,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun PermissionRow(title: String, reason: String, granted: Boolean, onFix: () -> Unit) {
    SettingsActionRow(
        title       = title,
        description = if (granted) "Granted" else "$reason\nMissing.",
        actionLabel = if (granted) "OK" else "Fix",
        onAction    = { if (!granted) onFix() },
    )
}

private fun openAppSettings(context: android.content.Context) {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
        data = Uri.fromParts("package", context.packageName, null)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    try { context.startActivity(intent) } catch (_: Exception) {}
}
