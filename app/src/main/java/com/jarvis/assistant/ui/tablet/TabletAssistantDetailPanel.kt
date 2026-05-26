package com.jarvis.assistant.ui.tablet

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.jarvis.assistant.memory.db.entity.ConversationTurn

// ── Palette ───────────────────────────────────────────────────────────────────
private val DetailBg     = Color(0xFF060B14)   // deepest navy
private val BubbleUser   = Color(0xFF072340)   // user bubble — deep navy-blue
private val BubbleAssist = Color(0xFF0D1628)   // assistant bubble — surface navy
private val TextBody     = Color(0xFFCCDAE8)   // body text — subtle blue tint
private val TextCyan     = Color(0xFF3FA7FF)   // blueprint blue accent
private val TextPurple   = Color(0xFFCE93D8)   // speaking / assistant highlight
private val TextMuted    = Color(0xFF4A6080)   // blueprint faint text
private val BorderLine   = Color(0xFF0E1C33)   // divider

/**
 * TabletAssistantDetailPanel — the detail pane when "Assistant" is selected.
 *
 * Layout (top to bottom):
 *  1. [TabletActionPlanPanel] — live action planner, collapsible once IDLE/COMPLETE
 *  2. Conversation header + full turn feed
 *
 * All data comes from [TabletViewModel.turns] and [TabletActionPlannerViewModel].
 */
@Composable
internal fun TabletAssistantDetailPanel(
    vm       : TabletViewModel              = viewModel(),
    plannerVm: TabletActionPlannerViewModel = viewModel(),
) {
    val turns     by vm.turns.collectAsState()
    val listState  = rememberLazyListState()
    val count      = turns.size

    LaunchedEffect(count) {
        if (count > 0) listState.animateScrollToItem(count - 1)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(DetailBg),
    ) {
        // ── Action plan panel (always shown — collapses when IDLE) ─────────────
        TabletActionPlanPanel(vm = plannerVm)

        HorizontalDivider(color = BorderLine)

        // ── Conversation header ────────────────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "CONVERSATION",
                color        = TextMuted,
                fontSize     = 9.sp,
                fontFamily   = FontFamily.Monospace,
                letterSpacing = 3.sp,
                fontWeight   = FontWeight.Bold,
            )
            Spacer(Modifier.weight(1f))
            Text(
                "${turns.size} turns",
                color      = TextMuted,
                fontSize   = 10.sp,
                fontFamily = FontFamily.Monospace,
            )
        }

        HorizontalDivider(color = BorderLine)

        // ── Turn feed ──────────────────────────────────────────────────────────
        if (turns.isEmpty()) {
            Box(
                modifier         = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "Say \"Jarvis\" to start a conversation.",
                    color      = TextMuted,
                    fontSize   = 13.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        } else {
            LazyColumn(
                state           = listState,
                modifier        = Modifier.fillMaxSize(),
                contentPadding  = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(turns, key = { it.id }) { turn ->
                    DetailTurnBubble(turn)
                }
            }
        }
    }
}

@Composable
private fun DetailTurnBubble(turn: ConversationTurn) {
    val isUser     = turn.role == "user"
    val bubbleBg   = if (isUser) BubbleUser else BubbleAssist
    val labelColor = if (isUser) TextCyan else TextPurple

    Row(
        modifier              = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 480.dp)
                .clip(
                    RoundedCornerShape(
                        topStart    = 12.dp,
                        topEnd      = 12.dp,
                        bottomStart = if (isUser) 12.dp else 3.dp,
                        bottomEnd   = if (isUser) 3.dp else 12.dp,
                    )
                )
                .background(bubbleBg)
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            Text(
                text        = if (isUser) "You" else "Jarvis",
                color       = labelColor,
                fontSize    = 9.sp,
                fontWeight  = FontWeight.Bold,
                fontFamily  = FontFamily.Monospace,
                letterSpacing = 1.sp,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text       = turn.content,
                color      = TextBody,
                fontSize   = 13.sp,
                lineHeight = 19.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}
