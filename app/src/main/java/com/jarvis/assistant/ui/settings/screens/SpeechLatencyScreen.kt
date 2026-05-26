package com.jarvis.assistant.ui.settings.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.util.SpeechTurnStore
import com.jarvis.assistant.util.SpeechTurnTrace
import com.jarvis.assistant.util.TurnRoute
import kotlinx.coroutines.delay

@Composable
internal fun SpeechLatencyScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    var traces by remember { mutableStateOf(SpeechTurnStore.recentTraces()) }

    LaunchedEffect(Unit) {
        while (true) {
            traces = SpeechTurnStore.recentTraces()
            delay(2_000)
        }
    }

    SettingsScaffold(title = "Speech Latency", onBack = onBack, onClose = onClose) {
        Spacer(Modifier.height(4.dp))

        SummaryCard(traces)
        Spacer(Modifier.height(8.dp))
        RouteBreakdownCard(traces)
        Spacer(Modifier.height(8.dp))
        StageComparisonCard(traces)
        Spacer(Modifier.height(12.dp))
        SectionHeader("RECENT TURNS (${traces.size})")
        Spacer(Modifier.height(6.dp))

        if (traces.isEmpty()) {
            Text(
                text = "No turns recorded yet. Speak to Jarvis to populate.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 13.sp,
                modifier = Modifier.padding(vertical = 8.dp),
            )
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                traces.take(20).forEach { trace -> TurnRow(trace) }
            }
        }

        Spacer(Modifier.height(24.dp))
    }
}

// MARK: - Summary card

@Composable
private fun SummaryCard(traces: List<SpeechTurnTrace>) {
    val avg = SpeechTurnStore.averageTotalMs()
    val p50 = SpeechTurnStore.p50()
    val p95 = SpeechTurnStore.p95()

    DiagCard {
        SectionHeader("SUMMARY")
        Spacer(Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            StatBox("avg",  avg?.let { "%.0fms".format(it) } ?: "—")
            StatBox("p50",  p50?.let { "${it}ms" } ?: "—")
            StatBox("p95",  p95?.let { "${it}ms" } ?: "—")
        }

        val commandTraces = traces.filter { it.route == TurnRoute.FAST_COMMAND || it.route == TurnRoute.DIRECT_COMMAND }
        val llmTraces     = traces.filter { it.llmUsed }
        if (commandTraces.isNotEmpty() || llmTraces.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
            Spacer(Modifier.height(6.dp))
            val cmdAvg = commandTraces.map { it.totalLatencyMs }.filter { it > 0 }
                .average().takeIf { commandTraces.isNotEmpty() }
            val llmAvg = llmTraces.map { it.totalLatencyMs }.filter { it > 0 }
                .average().takeIf { llmTraces.isNotEmpty() }
            Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                StatBox("cmd avg", cmdAvg?.let { "%.0fms".format(it) } ?: "—", color = Color(0xFF4CAF50))
                StatBox("llm avg", llmAvg?.let { "%.0fms".format(it) } ?: "—", color = Color(0xFFFFB74D))
            }
        }
    }
}

// MARK: - Route breakdown

@Composable
private fun RouteBreakdownCard(traces: List<SpeechTurnTrace>) {
    val breakdown = SpeechTurnStore.routeBreakdown()
    val total = breakdown.values.sum().coerceAtLeast(1)

    DiagCard {
        SectionHeader("ROUTE BREAKDOWN")
        Spacer(Modifier.height(6.dp))
        TurnRoute.values().forEach { route ->
            val count = breakdown[route] ?: 0
            if (count > 0) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(vertical = 2.dp),
                ) {
                    Box(Modifier.size(8.dp).background(routeColor(route), RoundedCornerShape(2.dp)))
                    Text(
                        route.key,
                        fontSize = 12.sp, fontFamily = FontFamily.Monospace,
                        modifier = Modifier.weight(1f),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        "${count} (${100 * count / total}%)",
                        fontSize = 12.sp, fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

// MARK: - Stage comparison

@Composable
private fun StageComparisonCard(traces: List<SpeechTurnTrace>) {
    DiagCard {
        SectionHeader("AVG STAGE TIMES")
        Spacer(Modifier.height(6.dp))

        fun avg(selector: (SpeechTurnTrace) -> Long): Double? {
            val vals = traces.map(selector).filter { it > 0 }
            return if (vals.isEmpty()) null else vals.average()
        }

        val stages = listOf(
            Triple("STT",         avg { it.sttMs },          1500L),
            Triple("intent",      avg { it.intentMs },        50L),
            Triple("LLM total",   avg { it.llmMs },           800L),
            Triple("LLM 1st tok", avg { it.llmFirstTokenMs }, 400L),
            Triple("TTS",         avg { it.ttsMs },           200L),
            Triple("replyLogger", avg { it.replyLoggerMs },    5L),
        )
        stages.forEach { (label, avgMs, budget) -> StageRow(label, avgMs, budget) }
    }
}

@Composable
private fun StageRow(label: String, avgMs: Double?, budgetMs: Long) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(vertical = 2.dp),
    ) {
        Text(label, fontSize = 11.sp, fontFamily = FontFamily.Monospace, modifier = Modifier.weight(1f),
            color = MaterialTheme.colorScheme.onSurface)
        if (avgMs != null) {
            val over = avgMs > budgetMs
            Text(
                "%.0fms".format(avgMs),
                fontSize = 11.sp, fontFamily = FontFamily.Monospace,
                color = if (over) Color(0xFFEF5350) else Color(0xFF66BB6A),
                fontWeight = if (over) FontWeight.Bold else FontWeight.Normal,
            )
        } else {
            Text("—", fontSize = 11.sp, fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// MARK: - Turn row

@Composable
private fun TurnRow(trace: SpeechTurnTrace) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(6.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(3.dp))
                .background(routeColor(trace.route).copy(alpha = 0.2f))
                .padding(horizontal = 5.dp, vertical = 2.dp)
        ) {
            Text(
                text = trace.route.key.replace("_", " "),
                fontSize = 9.sp, fontFamily = FontFamily.Monospace,
                color = routeColor(trace.route),
            )
        }

        val total = trace.totalLatencyMs
        Text(
            text = "${total}ms",
            fontSize = 12.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium,
            color = if (total > 2000) Color(0xFFEF5350) else MaterialTheme.colorScheme.onSurface,
        )

        if (trace.llmUsed)  Tag("LLM",  Color(0xFFFFB74D))
        if (trace.toolUsed) Tag("TOOL", Color(0xFFFF7043))

        Spacer(Modifier.weight(1f))

        // compact stt|llm|tts breakdown
        val stageSummary = buildList {
            if (trace.sttMs > 0) add("s:${trace.sttMs}")
            if (trace.llmMs > 0) add("l:${trace.llmMs}")
            if (trace.ttsMs > 0) add("t:${trace.ttsMs}")
        }.joinToString(" ")
        if (stageSummary.isNotEmpty()) {
            Text(stageSummary, fontSize = 9.sp, fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// MARK: - Helper composables

@Composable
private fun DiagCard(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .padding(12.dp),
    ) { content() }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text = text, fontSize = 9.sp, fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant,
        letterSpacing = 1.sp,
    )
}

@Composable
private fun StatBox(label: String, value: String, color: Color = Color(0xFFFF8F00)) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontSize = 18.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, color = color)
        Text(label, fontSize = 9.sp, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Tag(label: String, color: Color) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(2.dp))
            .background(color.copy(alpha = 0.2f))
            .padding(horizontal = 4.dp, vertical = 1.dp)
    ) {
        Text(label, fontSize = 8.sp, fontFamily = FontFamily.Monospace, color = color, fontWeight = FontWeight.Bold)
    }
}

private fun routeColor(route: TurnRoute): Color = when (route) {
    TurnRoute.FAST_COMMAND, TurnRoute.DIRECT_COMMAND -> Color(0xFF66BB6A)
    TurnRoute.LLM_FALLBACK  -> Color(0xFFFFEE58)
    TurnRoute.LLM_WITH_TOOL -> Color(0xFFFF8F00)
    TurnRoute.UNKNOWN       -> Color(0xFF9E9E9E)
}
