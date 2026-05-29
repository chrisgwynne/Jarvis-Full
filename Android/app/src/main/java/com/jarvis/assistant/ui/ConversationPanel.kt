package com.jarvis.assistant.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.jarvis.assistant.memory.db.entity.ConversationTurn
import com.jarvis.assistant.ui.theme.JarvisTokens
import com.jarvis.assistant.ui.theme.jarvisExtras

/**
 * Conversation transcript — a premium, theme-aware chat surface.
 *
 *  - A tappable summary header (latest line + expand chevron) sits in a soft
 *    rounded card.
 *  - Expanding reveals the recent turns as chat bubbles: the user on the
 *    right (primary-tinted), Jarvis on the left (surface card).
 *  - Empty state reads as a calm prompt rather than a debug placeholder.
 */
@Composable
fun ConversationPanel(
    turns: List<ConversationTurn>,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val extras = MaterialTheme.jarvisExtras
    var expanded by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()

    val turnCount = turns.size
    LaunchedEffect(turnCount, expanded) {
        if (expanded && turnCount > 0) listState.animateScrollToItem(turnCount - 1)
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(JarvisTokens.Shape.card)
            .background(extras.surfaceRaised)
            .border(1.dp, extras.divider, JarvisTokens.Shape.card),
    ) {
        // ── Summary header ────────────────────────────────────────────────
        val latest = turns.lastOrNull()
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = turns.isNotEmpty()) { expanded = !expanded }
                .padding(horizontal = JarvisTokens.Space.lg, vertical = JarvisTokens.Space.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(JarvisTokens.Space.md),
        ) {
            Icon(
                Icons.AutoMirrored.Filled.Chat,
                contentDescription = null,
                tint = scheme.primary,
                modifier = Modifier.size(18.dp),
            )
            Text(
                text = when {
                    latest != null -> latest.content.take(70) + if (latest.content.length > 70) "…" else ""
                    else           -> "No conversation yet — press to talk or say “Jarvis”"
                },
                color = if (latest != null) scheme.onSurface else scheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (turns.isNotEmpty()) {
                Icon(
                    if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = if (expanded) "Collapse conversation" else "Expand conversation",
                    tint = extras.textMuted,
                    modifier = Modifier.size(20.dp),
                )
            }
        }

        // ── Expandable transcript ─────────────────────────────────────────
        AnimatedVisibility(
            visible = expanded,
            enter = expandVertically(tween(JarvisTokens.Motion.medium)),
            exit = shrinkVertically(tween(JarvisTokens.Motion.medium)),
        ) {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 300.dp)
                    .padding(horizontal = JarvisTokens.Space.md, vertical = JarvisTokens.Space.sm),
                verticalArrangement = Arrangement.spacedBy(JarvisTokens.Space.sm),
            ) {
                items(turns, key = { it.id }) { turn -> TurnBubble(turn) }
            }
        }
    }
}

@Composable
private fun TurnBubble(turn: ConversationTurn) {
    val scheme = MaterialTheme.colorScheme
    val extras = MaterialTheme.jarvisExtras
    val isUser = turn.role == "user"

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 280.dp)
                .clip(
                    RoundedCornerShape(
                        topStart = JarvisTokens.Radius.lg,
                        topEnd = JarvisTokens.Radius.lg,
                        bottomStart = if (isUser) JarvisTokens.Radius.lg else JarvisTokens.Radius.xs,
                        bottomEnd = if (isUser) JarvisTokens.Radius.xs else JarvisTokens.Radius.lg,
                    )
                )
                .background(if (isUser) scheme.primaryContainer else scheme.surfaceVariant)
                .padding(horizontal = JarvisTokens.Space.md, vertical = JarvisTokens.Space.sm),
        ) {
            Text(
                text = if (isUser) "You" else "Jarvis",
                color = if (isUser) scheme.onPrimaryContainer else extras.accentPurple,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(JarvisTokens.Space.xxs))
            Text(
                text = if (isUser) androidx.compose.ui.text.AnnotatedString(turn.content)
                       else renderMarkdownInline(turn.content, codeColor = scheme.primary),
                color = if (isUser) scheme.onPrimaryContainer else scheme.onSurface,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}
