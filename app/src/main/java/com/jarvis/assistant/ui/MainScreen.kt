package com.jarvis.assistant.ui

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.jarvis.assistant.ui.ConversationViewModel
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.remote.macbridge.AndroidRole
import com.jarvis.assistant.service.JarvisService
import com.jarvis.assistant.ui.orb.OrbViewModel
import com.jarvis.assistant.ui.orb.OrbVisualState
import com.jarvis.assistant.ui.waveform.JarvisWaveform

// ── Blueprint palette ─────────────────────────────────────────────────────────
private val BgDeep      = Color(0xFF060B14)   // page background (deepest navy)
private val SurfaceCard = Color(0xFF11203A)   // orb card / bottom row surface
private val Surface     = Color(0xFF0B1628)   // orb circle background
private val Cyan        = Color(0xFF3FA7FF)   // blueprint blue accent
private val Green       = Color(0xFF00E676)   // listening / active
private val Amber       = Color(0xFFFFAB40)   // processing / thinking
private val Purple      = Color(0xFFCE93D8)   // speaking
private val Red         = Color(0xFFFF5252)   // interrupted / stop
private val TextPrimary = Color(0xFFE0E0E0)   // primary text
private val TextMuted   = Color(0xFF7A8FAA)   // secondary labels (blue-grey)

@Composable
fun MainScreen(onOpenSettings: () -> Unit) {
    val context = LocalContext.current

    LaunchedEffect(Unit) {
        val role = JarvisApp.macBridgeSettings.snapshot().androidRole
        if (role == AndroidRole.BRIDGE_ONLY && !JarvisService.isRunning(context)) {
            JarvisService.start(context)
        }
    }

    var isRunning    by remember { mutableStateOf(false) }
    var serviceState by remember { mutableStateOf("IDLE") }

    DisposableEffect(Unit) {
        isRunning = JarvisService.isRunning(context)

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                when (intent?.action) {
                    JarvisService.BROADCAST_SERVICE_STARTED -> isRunning = true
                    JarvisService.BROADCAST_SERVICE_STOPPED -> {
                        isRunning    = false
                        serviceState = "IDLE"
                    }
                    JarvisService.BROADCAST_STATE_CHANGED   ->
                        serviceState = intent.getStringExtra(JarvisService.EXTRA_STATE) ?: return
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(JarvisService.BROADCAST_SERVICE_STARTED)
            addAction(JarvisService.BROADCAST_SERVICE_STOPPED)
            addAction(JarvisService.BROADCAST_STATE_CHANGED)
        }
        LocalBroadcastManager.getInstance(context).registerReceiver(receiver, filter)
        onDispose { LocalBroadcastManager.getInstance(context).unregisterReceiver(receiver) }
    }

    val orbViewModel : OrbViewModel = viewModel()
    val visualState  by orbViewModel.visualState.collectAsStateWithLifecycle()
    val amplitude    by orbViewModel.amplitude.collectAsStateWithLifecycle()

    val convViewModel: ConversationViewModel = viewModel()
    val turns by convViewModel.turns.collectAsStateWithLifecycle()
    LaunchedEffect(isRunning) {
        if (isRunning) convViewModel.startPolling() else { convViewModel.stopPolling(); convViewModel.refresh() }
    }

    val statusLabel   = orbStatusLabel(visualState)
    val statusColor   by animateColorAsState(
        targetValue   = orbLabelColor(visualState),
        animationSpec = tween(300),
        label         = "statusColor"
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BgDeep)
            .systemBarsPadding(),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(Modifier.height(32.dp))

        // ── Header ────────────────────────────────────────────────────
        Text(
            text          = "JARVIS",
            color         = TextPrimary,
            fontSize      = 24.sp,
            fontWeight    = FontWeight.Bold,
            letterSpacing = 4.sp,
        )
        Text(
            text          = "ASSISTANT",
            color         = TextMuted,
            fontSize      = 12.sp,
            letterSpacing = 2.sp,
            modifier      = Modifier.padding(top = 4.dp)
        )

        Spacer(Modifier.weight(1f))

        // ── Main Orb / State Card ─────────────────────────────────────────
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp),
            shape = RoundedCornerShape(32.dp),
            colors = CardDefaults.cardColors(containerColor = SurfaceCard)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 40.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(160.dp)
                        .clip(CircleShape)
                        .background(Surface)
                ) {
                    JarvisWaveform(
                        visualState = visualState,
                        amplitude   = amplitude,
                        modifier    = Modifier.fillMaxSize()
                    )
                }

                Spacer(Modifier.height(32.dp))

                Text(
                    text          = statusLabel.uppercase(),
                    color         = statusColor,
                    fontSize      = 14.sp,
                    fontWeight    = FontWeight.SemiBold,
                    letterSpacing = 2.sp,
                    textAlign     = TextAlign.Center,
                    modifier      = Modifier.padding(horizontal = 32.dp)
                )
            }
        }

        ServiceHealthBanner(isRunning = isRunning)

        // ── Conversation history panel ────────────────────────────────────────
        Spacer(Modifier.height(24.dp))
        Box(modifier = Modifier.padding(horizontal = 24.dp)) {
            ConversationPanel(turns = turns)
        }

        Spacer(Modifier.weight(1f))

        // ── Bottom Action Row ─────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 48.dp, vertical = 24.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Stop Button
            IconButton(
                onClick = { JarvisService.stop(context) },
                enabled = isRunning,
                modifier = Modifier.background(if (isRunning) SurfaceCard else Color.Transparent, CircleShape)
            ) {
                Icon(Icons.Default.Stop, contentDescription = "Stop", tint = if (isRunning) Red else TextMuted.copy(alpha = 0.3f))
            }

            // Main Mic Button
            val isListening = visualState is OrbVisualState.Listening || visualState is OrbVisualState.WakeListening
            FloatingActionButton(
                onClick = {
                    if (isRunning) {
                        if (isListening) JarvisService.silence(context) else JarvisService.start(context)
                    } else {
                        JarvisService.start(context)
                    }
                },
                containerColor = if (isRunning) Cyan else SurfaceCard,
                contentColor = if (isRunning) Color.Black else TextMuted,
                shape = CircleShape,
                modifier = Modifier.size(72.dp)
            ) {
                Icon(Icons.Default.Mic, contentDescription = "Mic", modifier = Modifier.size(32.dp))
            }

            // Settings
            IconButton(
                onClick = onOpenSettings,
                modifier = Modifier.background(SurfaceCard, CircleShape)
            ) {
                Icon(Icons.Default.Settings, contentDescription = "Settings", tint = TextMuted)
            }
        }
    }
}

private fun orbStatusLabel(state: OrbVisualState): String = when (state) {
    is OrbVisualState.Dormant       -> "Offline"
    is OrbVisualState.WakeListening -> "Say \"Jarvis\""
    is OrbVisualState.Activating    -> "Waking up…"
    is OrbVisualState.Listening     -> "Listening…"
    is OrbVisualState.Processing    ->
        if (state.toolName != null) "Working on it…" else "Thinking…"
    is OrbVisualState.Speaking      -> "Speaking"
    is OrbVisualState.Interrupted   -> "Paused"
    is OrbVisualState.Silencing     -> "Done"
    is OrbVisualState.Degraded      -> "Running offline"
    is OrbVisualState.MicBlocked    -> "Microphone blocked"
}

private fun orbLabelColor(state: OrbVisualState): Color = when (state) {
    is OrbVisualState.WakeListening -> Cyan
    is OrbVisualState.Activating    -> Color(0xFFFFFFFF)
    is OrbVisualState.Listening     -> Green
    is OrbVisualState.Processing    -> Amber
    is OrbVisualState.Speaking      -> Purple
    is OrbVisualState.Interrupted   -> Red
    is OrbVisualState.Silencing     -> Cyan.copy(alpha = 0.5f)
    is OrbVisualState.Degraded      -> Color(0xFF78909C)
    is OrbVisualState.MicBlocked    -> Color(0xFF546E7A)
    else                            -> TextMuted
}
