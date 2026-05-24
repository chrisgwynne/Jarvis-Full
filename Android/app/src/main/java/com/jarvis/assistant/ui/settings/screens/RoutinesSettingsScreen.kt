package com.jarvis.assistant.ui.settings.screens

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.jarvis.assistant.core.routines.RoutineRepository
import com.jarvis.assistant.core.routines.SavedRoutineEntity
import com.jarvis.assistant.memory.db.JarvisDatabase
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsValueRow
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
internal fun RoutinesSettingsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val repo  = remember {
        RoutineRepository(JarvisDatabase.getInstance(context).savedRoutineDao())
    }

    var routines by remember { mutableStateOf<List<SavedRoutineEntity>>(emptyList()) }
    var version  by remember { mutableStateOf(0) }

    LaunchedEffect(version) {
        routines = repo.list()
    }

    val df = remember { SimpleDateFormat("d MMM, HH:mm", Locale.getDefault()) }

    SettingsScaffold(title = "Routines", onBack = onBack, onClose = onClose) {

        SettingsInfoCard(
            title = "How it works",
            body  = "Save a sequence of actions and run them by name. " +
                    "Say \"save that as bedtime\" right after running a sequence, " +
                    "then \"run bedtime\" to repeat. Manage your saved routines below."
        )

        if (routines.isEmpty()) {
            SettingsGroup(
                title  = "No routines yet",
                footer = "Try: turn off the lights, set DND on, set an alarm for 7am — " +
                         "then say \"save that as bedtime\".",
            ) { /* empty body */ }
            return@SettingsScaffold
        }

        SettingsGroup(
            title  = "Saved routines",
            footer = "Tap delete on any routine you no longer use.",
        ) {
            routines.forEachIndexed { index, routine ->
                val stepCount = countSteps(routine.stepsJson)
                val lastRun = routine.lastRunAtMs?.let { df.format(Date(it)) } ?: "never"
                val subtitle = buildString {
                    append("$stepCount ")
                    append(if (stepCount == 1) "step" else "steps")
                    append(" • ${routine.runCount} run")
                    if (routine.runCount != 1) append("s")
                    append(" • last: $lastRun")
                }
                SettingsValueRow(title = routine.name, value = subtitle)
                SettingsRowDivider()
                SettingsActionRow(
                    title       = "Delete ${routine.name}",
                    actionLabel = "Delete",
                    destructive = true,
                    confirm     = true,
                    confirmCopy = "Yes, delete",
                    onAction    = {
                        scope.launch {
                            repo.delete(routine.name)
                            version++
                        }
                    },
                )
                if (index < routines.size - 1) SettingsRowDivider()
            }
        }
    }
}

/**
 * Count the number of steps in the stored JSON array without fully
 * deserialising — cheap heuristic, good enough for a row subtitle.
 */
private fun countSteps(stepsJson: String): Int {
    // Steps are stored as a JSON array.  Count opening braces for objects.
    return stepsJson.count { it == '{' }
}
