package com.jarvis.assistant.ui.tablet

import android.content.Intent
import android.provider.CalendarContract
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

// ── Palette ───────────────────────────────────────────────────────────────────
private val PanelBg   = Color(0xFF060B14)   // deepest navy
private val CardBg    = Color(0xFF0B1628)   // card surface
private val TextPri   = Color(0xFFCCE0F0)   // blue-tinted body text
private val TextMuted = Color(0xFF7A8FAA)   // blue-grey secondary labels
private val CyanHigh  = Color(0xFF3FA7FF)   // blueprint blue
private val PurpleHi  = Color(0xFFCE93D8)   // calendar / AI highlight
private val BorderC   = Color(0xFF0E1C33)   // divider

data class CalendarEvent(
    val title     : String,
    val startMs   : Long,
    val endMs     : Long,
    val location  : String?,
    val allDay    : Boolean,
)

/**
 * TabletCalendarPanel — detail pane for the Calendar destination.
 *
 * Queries the device calendar for events in the next 7 days and displays them
 * in a card list.  Provides a quick-open button for the calendar app and voice
 * command hints for Jarvis.
 */
@Composable
internal fun TabletCalendarPanel(vm: TabletViewModel) {
    val context = LocalContext.current
    val events  by produceState<List<CalendarEvent>>(initialValue = emptyList()) {
        value = withContext(Dispatchers.IO) { queryUpcomingEvents(context) }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(PanelBg)
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // ── Header ─────────────────────────────────────────────────────────────
        Row(
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier              = Modifier.fillMaxWidth(),
        ) {
            PanelHeader(label = "CALENDAR", icon = Icons.Filled.CalendarToday, tint = PurpleHi)
            OutlinedButton(
                onClick = {
                    context.startActivity(
                        Intent(Intent.ACTION_MAIN)
                            .addCategory(Intent.CATEGORY_APP_CALENDAR)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                },
                shape  = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = PurpleHi),
                border = androidx.compose.foundation.BorderStroke(1.dp, PurpleHi.copy(alpha = 0.4f)),
            ) {
                Icon(Icons.Filled.OpenInNew, contentDescription = null, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(4.dp))
                Text("Open calendar", fontSize = 11.sp, fontFamily = FontFamily.Monospace)
            }
        }

        HorizontalDivider(color = BorderC)

        // ── Event list ─────────────────────────────────────────────────────────
        Text(
            "NEXT 7 DAYS",
            color        = TextMuted,
            fontSize     = 9.sp,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 2.sp,
        )

        if (events.isEmpty()) {
            EmptyCard("No upcoming events found, or calendar permission not granted.")
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                events.take(10).forEach { event ->
                    EventCard(event = event)
                }
            }
        }

        Spacer(Modifier.weight(1f))

        // ── Voice hints ────────────────────────────────────────────────────────
        VoiceHints(
            hints = listOf(
                "\"Jarvis, what's on my calendar today?\"",
                "\"Jarvis, add a meeting at 3pm tomorrow\"",
                "\"Jarvis, when is my next event?\"",
                "\"Jarvis, remind me about [event]\"",
            )
        )
    }
}

@Composable
private fun EventCard(event: CalendarEvent) {
    val dateStr = if (event.allDay) {
        DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(event.startMs))
    } else {
        buildString {
            append(DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
                .format(Date(event.startMs)))
            append(" – ")
            append(DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(event.endMs)))
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(CardBg)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            event.title,
            color      = TextPri,
            fontSize   = 13.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
        )
        Text(
            dateStr,
            color      = PurpleHi.copy(alpha = 0.8f),
            fontSize   = 11.sp,
            fontFamily = FontFamily.Monospace,
        )
        if (!event.location.isNullOrBlank()) {
            Row(
                verticalAlignment     = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(
                    Icons.Filled.LocationOn,
                    contentDescription = null,
                    tint     = TextMuted,
                    modifier = Modifier.size(12.dp),
                )
                Text(
                    event.location,
                    color      = TextMuted,
                    fontSize   = 10.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
    }
}

// ── Calendar query ────────────────────────────────────────────────────────────

private fun queryUpcomingEvents(context: android.content.Context): List<CalendarEvent> {
    val results = mutableListOf<CalendarEvent>()
    try {
        val now     = System.currentTimeMillis()
        val weekOut = now + 7L * 24 * 60 * 60 * 1_000L

        val projection = arrayOf(
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.ALL_DAY,
        )
        val selection = "(${CalendarContract.Events.DTSTART} >= ? AND " +
            "${CalendarContract.Events.DTSTART} <= ?) OR " +
            "(${CalendarContract.Events.ALL_DAY} = 1 AND " +
            "${CalendarContract.Events.DTSTART} >= ?)"
        val selArgs = arrayOf(now.toString(), weekOut.toString(), now.toString())

        context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            selection,
            selArgs,
            "${CalendarContract.Events.DTSTART} ASC",
        )?.use { cursor ->
            val titleCol = cursor.getColumnIndexOrThrow(CalendarContract.Events.TITLE)
            val startCol = cursor.getColumnIndexOrThrow(CalendarContract.Events.DTSTART)
            val endCol   = cursor.getColumnIndexOrThrow(CalendarContract.Events.DTEND)
            val locCol   = cursor.getColumnIndexOrThrow(CalendarContract.Events.EVENT_LOCATION)
            val dayCol   = cursor.getColumnIndexOrThrow(CalendarContract.Events.ALL_DAY)
            var count    = 0
            while (cursor.moveToNext() && count < 20) {
                val title = cursor.getString(titleCol) ?: continue
                results += CalendarEvent(
                    title    = title,
                    startMs  = cursor.getLong(startCol),
                    endMs    = cursor.getLong(endCol),
                    location = cursor.getString(locCol)?.takeIf { it.isNotBlank() },
                    allDay   = cursor.getInt(dayCol) == 1,
                )
                count++
            }
        }
    } catch (_: Exception) { /* calendar not accessible */ }
    return results
}
