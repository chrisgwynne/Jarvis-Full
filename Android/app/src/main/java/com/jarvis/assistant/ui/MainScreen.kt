package com.jarvis.assistant.ui

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.jarvis.assistant.remote.brain.MacBrainConnectionManager
import com.jarvis.assistant.remote.brain.MacBrainStatus
import com.jarvis.assistant.service.JarvisService
import com.jarvis.assistant.ui.components.JarvisStatus
import com.jarvis.assistant.ui.components.StateBadge
import com.jarvis.assistant.ui.components.color
import com.jarvis.assistant.ui.orb.JarvisOrb
import com.jarvis.assistant.ui.orb.OrbVisualState
import com.jarvis.assistant.ui.theme.JarvisGradients
import com.jarvis.assistant.ui.theme.JarvisTheme
import com.jarvis.assistant.ui.theme.JarvisTokens
import com.jarvis.assistant.ui.theme.jarvisExtras

/**
 * MainScreen — the assistant home.
 *
 * Premium light-theme layout, conversation-first and appliance-simple:
 *  - A bright hero "stage" card holding the animated orb + a live state badge.
 *  - A connection status strip (Connected to Mac brain / Reconnecting / Offline
 *    / Mic blocked) that reads from [MacBrainConnectionManager.sharedStatus]
 *    and the orb state.
 *  - A polished conversation area ([ConversationPanel]).
 *  - One-handed, bottom-anchored controls: a big press-to-talk primary
 *    (idle → manualTrigger, listening → silence, speaking/thinking → calm
 *    Cancel; long-press → full stop) and a tertiary Settings control.
 *
 * Accessibility: the orb/state carries a `liveRegion = Polite` content
 * description so TalkBack announces state transitions.
 */
@Composable
fun MainScreen(onOpenSettings: () -> Unit) {
    val context = LocalContext.current

    LaunchedEffect(Unit) {
        if (!JarvisService.isRunning(context)) {
            JarvisService.start(context)
        }
    }

    var isRunning by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        isRunning = JarvisService.isRunning(context)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                when (intent?.action) {
                    JarvisService.BROADCAST_SERVICE_STARTED -> isRunning = true
                    JarvisService.BROADCAST_SERVICE_STOPPED -> isRunning = false
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(JarvisService.BROADCAST_SERVICE_STARTED)
            addAction(JarvisService.BROADCAST_SERVICE_STOPPED)
        }
        LocalBroadcastManager.getInstance(context).registerReceiver(receiver, filter)
        onDispose { LocalBroadcastManager.getInstance(context).unregisterReceiver(receiver) }
    }

    val orbViewModel: com.jarvis.assistant.ui.orb.OrbViewModel = viewModel()
    val visualState by orbViewModel.visualState.collectAsStateWithLifecycle()
    val amplitude by orbViewModel.amplitude.collectAsStateWithLifecycle()

    val convViewModel: ConversationViewModel = viewModel()
    val turns by convViewModel.turns.collectAsStateWithLifecycle()
    LaunchedEffect(isRunning) {
        if (isRunning) convViewModel.startPolling() else { convViewModel.stopPolling(); convViewModel.refresh() }
    }

    val macStatus by MacBrainConnectionManager.sharedStatus.collectAsStateWithLifecycle()

    MainScreenContent(
        visualState = visualState,
        amplitude = amplitude,
        macStatus = macStatus,
        isRunning = isRunning,
        turns = turns,
        onPrimary = {
            // Press-to-talk: wake the pipeline when idle, otherwise silence the
            // current turn (calm cancel while speaking/thinking).  Uses only
            // the existing JarvisService API.
            if (!isRunning) {
                JarvisService.start(context)
            } else when (visualState) {
                is OrbVisualState.Listening,
                is OrbVisualState.WakeListening,
                is OrbVisualState.Speaking,
                is OrbVisualState.Processing -> JarvisService.silence(context)
                else -> JarvisService.manualTrigger(context)
            }
        },
        onPrimaryLongPress = { JarvisService.stop(context) },
        onOpenSettings = onOpenSettings,
    )
}

// ── Stateless content (preview-friendly) ─────────────────────────────────────

@Composable
private fun MainScreenContent(
    visualState: OrbVisualState,
    amplitude: Float,
    macStatus: MacBrainStatus,
    isRunning: Boolean,
    turns: List<com.jarvis.assistant.memory.db.entity.ConversationTurn>,
    onPrimary: () -> Unit,
    onPrimaryLongPress: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme

    val assistantStatus = visualState.toStatus()
    val connection = connectionStatus(macStatus, visualState, isRunning)
    val statusLabel = orbAnnouncement(visualState)

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(JarvisGradients.lightBackdrop)),
        contentAlignment = Alignment.TopCenter,
    ) {
        // Responsive: on wide screens (unfolded foldables that still route to
        // the phone layout) keep the content at a comfortable reading width so
        // the hero and controls don't stretch edge-to-edge.
        val contentWidth = if (maxWidth > 560.dp) 560.dp else maxWidth
        Column(
            modifier = Modifier
                .width(contentWidth)
                .fillMaxHeight()
                .systemBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // ── Header ────────────────────────────────────────────────────
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = JarvisTokens.Space.xl, vertical = JarvisTokens.Space.lg),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Jarvis",
                        color = scheme.onBackground,
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = "Your assistant",
                        color = scheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                ConnectionChip(connection)
            }

            Spacer(Modifier.weight(1f))

            // ── Hero stage: orb + live state badge ────────────────────────
            HeroStage(
                visualState = visualState,
                amplitude = amplitude,
                assistantStatus = assistantStatus,
                announcement = statusLabel,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = JarvisTokens.Space.xl),
            )

            Spacer(Modifier.height(JarvisTokens.Space.lg))

            // ── Connection / battery health strip ─────────────────────────
            ServiceHealthBanner(isRunning = isRunning)

            // ── Conversation ──────────────────────────────────────────────
            Spacer(Modifier.height(JarvisTokens.Space.lg))
            ConversationPanel(
                turns = turns,
                modifier = Modifier.padding(horizontal = JarvisTokens.Space.xl),
            )

            Spacer(Modifier.weight(1f))

            // ── Bottom controls (one-handed reachable) ────────────────────
            BottomControls(
                visualState = visualState,
                onPrimary = onPrimary,
                onPrimaryLongPress = onPrimaryLongPress,
                onOpenSettings = onOpenSettings,
            )
        }
    }
}

// ── Hero stage ───────────────────────────────────────────────────────────────

@Composable
private fun HeroStage(
    visualState: OrbVisualState,
    amplitude: Float,
    assistantStatus: JarvisStatus,
    announcement: String,
    modifier: Modifier = Modifier,
) {
    val extras = MaterialTheme.jarvisExtras
    Column(
        modifier = modifier
            .shadow(JarvisTokens.Shadow.raised, JarvisTokens.Shape.stage, clip = false, ambientColor = StageShadow, spotColor = StageShadow)
            .clip(JarvisTokens.Shape.stage)
            .background(extras.surfaceRaised)
            .background(Brush.verticalGradient(JarvisGradients.heroHalo))
            .padding(vertical = JarvisTokens.Space.xxl),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // JarvisOrb sizes its own Canvas at orbDiameterDp × 2 (glow headroom),
        // so the wrapping Box matches that footprint (120dp orb → 240dp stage)
        // to avoid clipping the atmospheric glow.
        Box(
            modifier = Modifier
                .size(240.dp)
                .semantics {
                    contentDescription = announcement
                    liveRegion = LiveRegionMode.Polite
                },
            contentAlignment = Alignment.Center,
        ) {
            JarvisOrb(
                visualState = visualState,
                amplitude = amplitude,
                orbDiameterDp = 120.dp,
            )
        }

        Spacer(Modifier.height(JarvisTokens.Space.lg))

        StateBadge(status = assistantStatus)
    }
}

private val StageShadow = Color(0xFF2A3D66)

// ── Connection chip (header) ─────────────────────────────────────────────────

@Composable
private fun ConnectionChip(status: JarvisStatus) {
    val accent by animateColorAsState(status.color(), tween(JarvisTokens.Motion.medium), label = "connAccent")
    Surface(
        shape = JarvisTokens.Shape.pill,
        color = accent.copy(alpha = 0.10f),
        border = BorderStroke(1.dp, accent.copy(alpha = 0.25f)),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = JarvisTokens.Space.md, vertical = JarvisTokens.Space.sm),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(JarvisTokens.Space.sm),
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(accent),
            )
            Text(
                text = connectionChipLabel(status),
                color = accent,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

// ── Bottom controls ──────────────────────────────────────────────────────────

@Composable
private fun BottomControls(
    visualState: OrbVisualState,
    onPrimary: () -> Unit,
    onPrimaryLongPress: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val extras = MaterialTheme.jarvisExtras
    val scheme = MaterialTheme.colorScheme

    val isBusy = visualState is OrbVisualState.Listening ||
        visualState is OrbVisualState.WakeListening ||
        visualState is OrbVisualState.Speaking ||
        visualState is OrbVisualState.Processing

    val primaryAccent by animateColorAsState(
        if (isBusy) extras.statusRed else scheme.primary,
        tween(JarvisTokens.Motion.medium),
        label = "primaryAccent",
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = JarvisTokens.Space.xxl, vertical = JarvisTokens.Space.xl),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Spacer to balance the trailing settings button, keeping the primary
        // control visually centred.
        Box(modifier = Modifier.size(JarvisTokens.Touch.minTarget))

        Spacer(Modifier.weight(1f))

        // Primary press-to-talk control.
        val label = primaryControlLabel(visualState)
        Box(
            modifier = Modifier
                .size(80.dp)
                .shadow(JarvisTokens.Shadow.float, CircleShape, clip = false, ambientColor = StageShadow, spotColor = StageShadow)
                .clip(CircleShape)
                .background(
                    if (isBusy) Brush.linearGradient(listOf(primaryAccent, primaryAccent))
                    else Brush.linearGradient(JarvisGradients.primaryButton)
                )
                .pointerInput(isBusy) {
                    detectTapGestures(
                        onTap = { onPrimary() },
                        onLongPress = { onPrimaryLongPress() },
                    )
                }
                .semantics { contentDescription = label },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (isBusy) Icons.Filled.Close else Icons.Filled.Mic,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(34.dp),
            )
        }

        Spacer(Modifier.weight(1f))

        // Tertiary: settings.
        Box(
            modifier = Modifier
                .size(JarvisTokens.Touch.minTarget)
                .clip(CircleShape)
                .background(extras.surfaceRaised)
                .border(1.dp, extras.divider, CircleShape)
                .pointerInput(Unit) { detectTapGestures(onTap = { onOpenSettings() }) }
                .semantics { contentDescription = "Open settings" },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.Settings,
                contentDescription = null,
                tint = scheme.onSurfaceVariant,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

// ── State mapping helpers ─────────────────────────────────────────────────────

private fun OrbVisualState.toStatus(): JarvisStatus = when (this) {
    is OrbVisualState.Dormant       -> JarvisStatus.Idle
    is OrbVisualState.WakeListening -> JarvisStatus.Idle
    is OrbVisualState.Activating    -> JarvisStatus.Listening
    is OrbVisualState.Listening     -> JarvisStatus.Listening
    is OrbVisualState.Processing    -> if (toolName != null) JarvisStatus.RunningAction else JarvisStatus.Thinking
    is OrbVisualState.Speaking      -> JarvisStatus.Speaking
    is OrbVisualState.Interrupted   -> JarvisStatus.Paused
    is OrbVisualState.Silencing     -> JarvisStatus.Idle
    is OrbVisualState.Degraded      -> JarvisStatus.Offline
    is OrbVisualState.MicBlocked    -> JarvisStatus.MicBlocked
}

/** Connection chip shown top-right — combines Mac status + mic/offline state. */
private fun connectionStatus(
    macStatus: MacBrainStatus,
    visualState: OrbVisualState,
    isRunning: Boolean,
): JarvisStatus = when {
    visualState is OrbVisualState.MicBlocked -> JarvisStatus.MicBlocked
    macStatus == MacBrainStatus.Connected    -> JarvisStatus.Connected
    macStatus == MacBrainStatus.Connecting   -> JarvisStatus.Reconnecting
    macStatus == MacBrainStatus.Reconnecting -> JarvisStatus.Reconnecting
    else                                     -> JarvisStatus.Offline
}

private fun connectionChipLabel(status: JarvisStatus): String = when (status) {
    JarvisStatus.Connected    -> "Connected"
    JarvisStatus.Reconnecting -> "Reconnecting"
    JarvisStatus.MicBlocked   -> "Mic blocked"
    else                      -> "Offline"
}

/** Bottom-control label / a11y description for the current state. */
private fun primaryControlLabel(state: OrbVisualState): String = when (state) {
    is OrbVisualState.Listening,
    is OrbVisualState.WakeListening -> "Stop listening"
    is OrbVisualState.Speaking,
    is OrbVisualState.Processing    -> "Cancel"
    else                            -> "Talk to Jarvis"
}

/** Full spoken-state announcement for TalkBack. */
private fun orbAnnouncement(state: OrbVisualState): String = when (state) {
    is OrbVisualState.Dormant       -> "Jarvis is offline"
    is OrbVisualState.WakeListening -> "Jarvis is ready. Say Jarvis, or press to talk."
    is OrbVisualState.Activating    -> "Waking up"
    is OrbVisualState.Listening     -> "Listening"
    is OrbVisualState.Processing    -> if (state.toolName != null) "Working on it" else "Thinking"
    is OrbVisualState.Speaking      -> "Speaking"
    is OrbVisualState.Interrupted   -> "Paused"
    is OrbVisualState.Silencing     -> "Done"
    is OrbVisualState.Degraded      -> "Running offline"
    is OrbVisualState.MicBlocked    -> "Microphone is blocked"
}

// ── Previews ──────────────────────────────────────────────────────────────────

@Preview(name = "Main · Listening", showBackground = true, widthDp = 412, heightDp = 915)
@Composable
private fun PreviewMainListening() {
    JarvisTheme {
        MainScreenContent(
            visualState = OrbVisualState.Listening(0.6f),
            amplitude = 0.6f,
            macStatus = MacBrainStatus.Connected,
            isRunning = true,
            turns = emptyList(),
            onPrimary = {}, onPrimaryLongPress = {}, onOpenSettings = {},
        )
    }
}

@Preview(name = "Main · Speaking", showBackground = true, widthDp = 412, heightDp = 915)
@Composable
private fun PreviewMainSpeaking() {
    JarvisTheme {
        MainScreenContent(
            visualState = OrbVisualState.Speaking(0.5f),
            amplitude = 0.5f,
            macStatus = MacBrainStatus.Connected,
            isRunning = true,
            turns = emptyList(),
            onPrimary = {}, onPrimaryLongPress = {}, onOpenSettings = {},
        )
    }
}

@Preview(name = "Main · Offline", showBackground = true, widthDp = 412, heightDp = 915)
@Composable
private fun PreviewMainOffline() {
    JarvisTheme {
        MainScreenContent(
            visualState = OrbVisualState.WakeListening,
            amplitude = 0f,
            macStatus = MacBrainStatus.Disconnected,
            isRunning = true,
            turns = emptyList(),
            onPrimary = {}, onPrimaryLongPress = {}, onOpenSettings = {},
        )
    }
}

@Preview(name = "Main · Thinking", showBackground = true, widthDp = 412, heightDp = 915)
@Composable
private fun PreviewMainThinking() {
    JarvisTheme {
        MainScreenContent(
            visualState = OrbVisualState.Processing(),
            amplitude = 0f,
            macStatus = MacBrainStatus.Reconnecting,
            isRunning = true,
            turns = emptyList(),
            onPrimary = {}, onPrimaryLongPress = {}, onOpenSettings = {},
        )
    }
}
