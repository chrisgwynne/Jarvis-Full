package com.jarvis.assistant.ui.settings.screens

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.personality.JokeFrequency
import com.jarvis.assistant.personality.SarcasmLevel
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsDropdownRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsToggleRow

/**
 * Personality settings — exposes the user-tunable knobs that flow
 * through [com.jarvis.assistant.personality.PersonalityPromptSelector]
 * and [com.jarvis.assistant.personality.template.LocalResponseTemplateEngine].
 *
 * The *content* of Jarvis's voice lives in markdown files under
 * `app/src/main/assets/personality/` (loaded by
 * [com.jarvis.assistant.personality.PersonalityProfileLoader]).  This
 * screen is for the *policy* — when humour fires, how often, and
 * whether it applies to a given surface.
 */
@Composable
internal fun PersonalitySettingsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val repo  = JarvisApp.personalitySettings
    val state by repo.stateFlow.collectAsState()

    SettingsScaffold(title = "Personality", onBack = onBack, onClose = onClose) {

        SettingsInfoCard(
            title = "How Jarvis sounds",
            body  = "These controls decide when personality kicks in, " +
                    "how often humour fires, and where it applies. " +
                    "Changes take effect immediately.",
        )

        SettingsGroup(title = "Main control") {
            SettingsToggleRow(
                title           = "Personality enabled",
                description     = "Master switch.  Off = strict assistant tone everywhere.",
                checked         = state.enabled,
                onCheckedChange = repo::setEnabled,
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Tone") {
            SettingsDropdownRow(
                title       = "Sarcasm level",
                description = "How dry Jarvis gets to be by default.",
                options     = SarcasmLevel.values().toList(),
                selected    = state.sarcasm,
                label       = { it.displayLabel },
                onSelected  = repo::setSarcasm,
            )
            SettingsRowDivider()
            SettingsDropdownRow(
                title       = "Joke frequency",
                description = "How often a one-liner sneaks into a confirmation.",
                options     = JokeFrequency.values().toList(),
                selected    = state.jokeFrequency,
                label       = { it.displayLabel },
                onSelected  = repo::setJokeFrequency,
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Behaviour") {
            SettingsToggleRow(
                title           = "Pushback enabled",
                description     = "Ask clarifying questions for ambiguous commands.",
                checked         = state.pushbackEnabled,
                onCheckedChange = repo::setPushbackEnabled,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Friendly roasting",
                description     = "Allow mild, affectionate jabs (\"future you owes me one\").",
                checked         = state.friendlyRoastingEnabled,
                onCheckedChange = repo::setFriendlyRoastingEnabled,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Serious-mode auto-detect",
                description     = "Detect emergency / medical / distress / safety language and " +
                    "suppress humour automatically.",
                checked         = state.seriousModeAutoDetectEnabled,
                onCheckedChange = repo::setSeriousModeAutoDetect,
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Where it applies") {
            SettingsToggleRow(
                title           = "Proactive reminders",
                description     = "Give reminders the same personality voice as conversations.",
                checked         = state.applyToProactiveReminders,
                onCheckedChange = repo::setApplyToProactiveReminders,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Quick confirmations",
                description     = "Pick witty replies for short action confirmations.",
                checked         = state.applyToLocalConfirmations,
                onCheckedChange = repo::setApplyToLocalConfirmations,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "AI responses",
                description     = "Shape the tone of AI replies with the personality profile.",
                checked         = state.applyToLlmAnswers,
                onCheckedChange = repo::setApplyToLlmAnswers,
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Reset") {
            SettingsActionRow(
                title       = "Reset personality settings",
                description = "Restores the defaults from this screen.",
                actionLabel = "Reset",
                destructive = true,
                confirm     = true,
                onAction    = repo::resetToDefaults,
            )
        }

        Spacer(Modifier.height(24.dp))
    }
}
