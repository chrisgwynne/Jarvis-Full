package com.jarvis.assistant.overlay.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Help
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.layout.offset
import com.jarvis.assistant.overlay.OverlayCardManager
import com.jarvis.assistant.overlay.OverlayEventBridge
import com.jarvis.assistant.overlay.model.OverlayCard
import com.jarvis.assistant.overlay.model.OverlayCardType
import kotlin.math.roundToInt
import kotlinx.coroutines.delay

// ── Palette (hard-coded dark — no Activity/MaterialTheme context in Service) ──

private val BgCard        = Color(0xEE12121E)   // ~93% dark navy
private val BgListening   = Color(0xBB00BCD4)   // ~73% cyan — softened from 0xDD
private val AccentSuccess = Color(0xFF00E676)
private val AccentFailed  = Color(0xFFFF5252)
private val AccentNav     = Color(0xFF00BCD4)
private val AccentHa      = Color(0xFFFFAB40)
private val AccentReply   = Color(0xFFCE93D8)
private val AccentProact  = Color(0xFFCE93D8)
private val AccentDevice  = Color(0xFFB0B0C0)
private val TextPrimary   = Color(0xFFE0E0E0)
private val TextSecondary = Color(0xFFB0B0C0)

// Swipe-to-dismiss threshold in pixels
private const val SWIPE_DISMISS_PX = 80f

// ── Root content ──────────────────────────────────────────────────────────────

@Composable
fun OverlayContent() {
    val cards by OverlayCardManager.cards.collectAsState()

    Column(
        modifier            = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
        horizontalAlignment = Alignment.End,
    ) {
        val listeningCard = cards.firstOrNull { it.type == OverlayCardType.LISTENING_STATE }
        AnimatedVisibility(
            visible = listeningCard != null,
            enter   = slideInVertically(tween(100)) { -it } + fadeIn(tween(100)),
            exit    = slideOutVertically(tween(80)) { -it } + fadeOut(tween(80)),
        ) {
            ListeningPill()
        }

        val actionCards = cards.filter { it.type != OverlayCardType.LISTENING_STATE }
        actionCards.forEach { card ->
            key(card.id) {
                AnimatedCard(card = card)
            }
        }
    }
}

// ── Per-card animation wrapper with swipe-to-dismiss ─────────────────────────

@Composable
private fun AnimatedCard(card: OverlayCard) {
    val haptic   = LocalHapticFeedback.current
    var visible  by remember { mutableStateOf(false) }
    var swiping  by remember { mutableStateOf(false) }
    var swipeX   by remember { mutableFloatStateOf(0f) }

    // Snap-back animation when swipe is released below threshold
    val animatedSwipeX by animateFloatAsState(
        targetValue     = if (swiping) swipeX else 0f,
        animationSpec   = if (swiping) tween(0) else spring(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness    = Spring.StiffnessMedium,
        ),
        label = "swipeOffset",
    )

    // Enter: play spring slide-in after first composition
    LaunchedEffect(card.id) { visible = true }

    // Dismissal: set visible=false first so exit animation plays, then remove from manager
    val dismiss: () -> Unit = remember(card.id) {
        {
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            visible = false
            // OverlayCardManager.dismiss is called by the LaunchedEffect below
        }
    }

    LaunchedEffect(visible, card.id) {
        // When visible flips to false (user dismissed), wait for exit animation then remove
        if (!visible) {
            delay(100L)
            OverlayCardManager.dismiss(card.id)
        }
    }

    AnimatedVisibility(
        visible = visible,
        enter   = slideInHorizontally(
            animationSpec = spring(
                dampingRatio = Spring.DampingRatioMediumBouncy,
                stiffness    = Spring.StiffnessMediumLow,
            )
        ) { it } + fadeIn(tween(120)),
        exit    = slideOutHorizontally(tween(80)) { it } + fadeOut(tween(80)),
    ) {
        Box(
            modifier = Modifier
                .offset { IntOffset(animatedSwipeX.roundToInt(), 0) }
                .pointerInput(card.id) {
                    detectHorizontalDragGestures(
                        onDragStart  = { swiping = true },
                        onDragEnd    = {
                            if (swipeX >= SWIPE_DISMISS_PX) {
                                dismiss()
                            } else {
                                swiping = false
                                swipeX  = 0f
                            }
                        },
                        onDragCancel = { swiping = false; swipeX = 0f },
                        onHorizontalDrag = { _, dragAmount ->
                            // Only allow rightward swipe (positive X = toward dismiss)
                            swipeX = (swipeX + dragAmount).coerceAtLeast(0f)
                        },
                    )
                }
                // Fade card as it approaches the dismiss threshold
                .graphicsLayer { alpha = (1f - (animatedSwipeX / (SWIPE_DISMISS_PX * 2f))).coerceIn(0f, 1f) },
        ) {
            OverlayCardItem(
                card      = card,
                onDismiss = dismiss,
                onAction  = { key ->
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    OverlayEventBridge.fireAction(card.id, key)
                },
            )
        }
    }
}

// ── Listening pill ────────────────────────────────────────────────────────────

@Composable
private fun ListeningPill() {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(BgListening)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment     = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector        = Icons.Default.Mic,
            contentDescription = null,
            tint               = Color(0xFF003D49),
            modifier           = Modifier.size(14.dp),
        )
        Text(
            text       = "Listening…",
            color      = Color(0xFF003D49),
            fontSize   = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

// ── Card item ─────────────────────────────────────────────────────────────────

@Composable
private fun OverlayCardItem(
    card: OverlayCard,
    onDismiss: () -> Unit,
    onAction: (String) -> Unit,
) {
    val accent = card.type.accentColor()
    val icon   = card.type.icon()

    Box(
        modifier = Modifier
            .widthIn(min = 180.dp, max = 280.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(BgCard),
    ) {
        // Left accent bar
        Box(
            modifier = Modifier
                .width(3.dp)
                .matchParentSize()
                .background(accent),
        )

        Column(
            modifier = Modifier.padding(start = 11.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
        ) {
            // Header: icon + title + 48dp close target
            Row(
                verticalAlignment     = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    imageVector        = icon,
                    contentDescription = null,
                    tint               = accent,
                    modifier           = Modifier.size(16.dp),
                )
                Text(
                    text       = card.title,
                    color      = TextPrimary,
                    fontSize   = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines   = 1,
                    overflow   = TextOverflow.Ellipsis,
                    modifier   = Modifier.weight(1f),
                )
                // 44×44 touch target wrapping the 16dp icon
                Box(
                    modifier           = Modifier
                        .size(44.dp)
                        .clickable(onClick = onDismiss)
                        .wrapContentSize(Alignment.Center),
                    contentAlignment   = Alignment.Center,
                ) {
                    Icon(
                        imageVector        = Icons.Default.Close,
                        contentDescription = "Dismiss",
                        tint               = TextSecondary,
                        modifier           = Modifier.size(16.dp),
                    )
                }
            }

            // Optional message
            if (card.message.isNotBlank()) {
                Text(
                    text     = card.message,
                    color    = TextSecondary,
                    fontSize = 12.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp, end = 4.dp),
                )
            }

            // Action buttons — minimum 44dp height for comfortable tapping
            if (card.actions.isNotEmpty()) {
                Row(
                    modifier              = Modifier
                        .padding(top = 2.dp)
                        .fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                    verticalAlignment     = Alignment.CenterVertically,
                ) {
                    card.actions.forEach { action ->
                        TextButton(
                            onClick  = { onAction(action.actionKey) },
                            modifier = Modifier
                                .heightIn(min = 44.dp)
                                .padding(horizontal = 2.dp),
                        ) {
                            Text(
                                text       = action.label,
                                color      = if (action.isPrimary) accent else TextSecondary,
                                fontSize   = 12.sp,
                                fontWeight = if (action.isPrimary) FontWeight.Bold else FontWeight.Normal,
                            )
                        }
                    }
                }
            }
        }
    }
}

// ── Type → accent / icon ──────────────────────────────────────────────────────

private fun OverlayCardType.accentColor() = when (this) {
    OverlayCardType.ACTION_SUCCESS        -> AccentSuccess
    OverlayCardType.ACTION_FAILED         -> AccentFailed
    OverlayCardType.CONFIRMATION          -> AccentNav
    OverlayCardType.SMART_REPLY           -> AccentReply
    OverlayCardType.NAVIGATION            -> AccentNav
    OverlayCardType.HOME_ASSISTANT_ALERT  -> AccentHa
    OverlayCardType.PROACTIVE_PROMPT      -> AccentProact
    OverlayCardType.DEVICE_CONTEXT        -> AccentDevice
    OverlayCardType.LISTENING_STATE       -> AccentNav
    OverlayCardType.DIAGNOSTICS           -> AccentDevice  // neutral debug colour
}

private fun OverlayCardType.icon(): ImageVector = when (this) {
    OverlayCardType.ACTION_SUCCESS        -> Icons.Default.CheckCircle
    OverlayCardType.ACTION_FAILED         -> Icons.Default.Error
    OverlayCardType.CONFIRMATION          -> Icons.AutoMirrored.Filled.Help
    OverlayCardType.SMART_REPLY           -> Icons.AutoMirrored.Filled.Reply
    OverlayCardType.NAVIGATION            -> Icons.Default.Navigation
    OverlayCardType.HOME_ASSISTANT_ALERT  -> Icons.Default.Home
    OverlayCardType.PROACTIVE_PROMPT      -> Icons.Default.AutoAwesome
    OverlayCardType.DEVICE_CONTEXT        -> Icons.Default.PhoneAndroid
    OverlayCardType.LISTENING_STATE       -> Icons.Default.Mic
    OverlayCardType.DIAGNOSTICS           -> Icons.Default.PhoneAndroid
}
