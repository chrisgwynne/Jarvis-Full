package com.jarvis.assistant.ui.settings.screens

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsDropdownRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsPrimaryButton
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsSliderRow
import com.jarvis.assistant.ui.settings.SettingsTextFieldRow
import com.jarvis.assistant.ui.settings.SettingsTheme
import com.jarvis.assistant.ui.settings.SettingsToggleRow

@Composable
internal fun AdvancedSettingsScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current

    val provider         by vm.llmProvider.collectAsStateWithLifecycle()
    val apiKey           by vm.apiKey.collectAsStateWithLifecycle()
    val ollamaUrl        by vm.ollamaBaseUrl.collectAsStateWithLifecycle()
    val miniMaxUrl       by vm.miniMaxBaseUrl.collectAsStateWithLifecycle()
    val miniMaxModel     by vm.miniMaxModel.collectAsStateWithLifecycle()
    val maxTokens        by vm.maxTokens.collectAsStateWithLifecycle()
    val fallbackProvider by vm.fallbackProvider.collectAsStateWithLifecycle()

    val openAiClientId   by vm.openAiClientId.collectAsStateWithLifecycle()
    val openAiSignedIn   by vm.openAiSignedIn.collectAsStateWithLifecycle()
    val openAiError      by vm.openAiOAuthError.collectAsStateWithLifecycle()

    SettingsScaffold(title = "Advanced", onBack = onBack, onClose = onClose) {

        /* ── LLM provider ────────────────────────────────────────────────── */
        SettingsGroup(
            title  = "LLM provider",
            footer = "Jarvis uses this provider for chat, planning and tool use.",
        ) {
            SettingsDropdownRow(
                title      = "Provider",
                options    = vm.providers,
                selected   = provider,
                label      = { it },
                onSelected = vm::setLlmProvider,
            )
            SettingsRowDivider()
            val fallbackOptions = listOf("") + vm.providers
            SettingsDropdownRow(
                title       = "Fallback provider",
                description = "Used if the primary provider fails. Disabled by default.",
                options     = fallbackOptions,
                selected    = fallbackProvider,
                label       = { if (it.isBlank()) "Disabled" else it },
                onSelected  = vm::setFallbackProvider,
            )
        }

        /* ── Response tuning ─────────────────────────────────────────────── */
        SettingsGroup(
            title  = "Response tuning",
            footer = "1200 is a good default. Raise for long-form; lower for snappier replies.",
        ) {
            SettingsSliderRow(
                title       = "Max response tokens",
                value       = maxTokens.toFloat(),
                onValueChange = { vm.setMaxTokens(it.toInt()) },
                valueRange  = 400f..4000f,
                steps       = 35,
                valueLabel  = { it.toInt().toString() },
            )
        }

        when (provider) {
            "OpenAI" -> {
                SettingsGroup(title = "OpenAI account") {
                    if (openAiSignedIn) {
                        SettingsInfoCard(
                            title      = "Connected",
                            body       = "Jarvis is signed in to OpenAI via OAuth.",
                            accent     = SettingsTheme.Success,
                            background = SettingsTheme.SuccessBg,
                        )
                        SettingsRowDivider()
                        SettingsActionRow(
                            title       = "Sign out",
                            description = "Revokes the access token on this device.",
                            actionLabel = "Sign out of OpenAI",
                            destructive = true,
                            confirm     = true,
                            confirmCopy = "Sign out",
                            onAction    = vm::signOutOpenAi,
                        )
                    } else {
                        SettingsInfoCard(
                            title = "Sign in with OpenAI",
                            body  = "Register an OAuth app at platform.openai.com to get a " +
                                    "client ID. Set the redirect URI to " +
                                    "com.jarvis.assistant://oauth/callback.",
                        )
                        SettingsRowDivider()
                        SettingsTextFieldRow(
                            title        = "OpenAI client ID",
                            value        = openAiClientId,
                            onValueChange = vm::setOpenAiClientId,
                            placeholder  = "app_…",
                        )
                        if (!openAiError.isNullOrBlank()) {
                            Text(
                                openAiError ?: "",
                                color = SettingsTheme.Destructive,
                                fontSize = 12.sp,
                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
                            )
                        }
                        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp)) {
                            SettingsPrimaryButton(
                                label   = "Sign in with OpenAI",
                                onClick = {
                                    val uri = vm.buildSignInUri()
                                    if (uri != null) {
                                        context.startActivity(Intent(Intent.ACTION_VIEW, uri))
                                    }
                                },
                            )
                        }
                    }
                }
            }

            "Ollama" -> {
                SettingsGroup(
                    title  = "Ollama",
                    footer = "Point Jarvis at your local Ollama server. No API key needed.",
                ) {
                    SettingsTextFieldRow(
                        title         = "Base URL",
                        value         = ollamaUrl,
                        onValueChange = vm::setOllamaBaseUrl,
                        placeholder   = "http://192.168.1.1:11434",
                    )
                }
            }

            "MiniMax" -> {
                SettingsGroup(
                    title  = "MiniMax",
                    footer = "International: api.minimax.io. China platform: api.minimax.chat/v1.",
                ) {
                    SettingsTextFieldRow(
                        title         = "API key",
                        value         = apiKey,
                        onValueChange = vm::setApiKey,
                        placeholder   = "sk-…",
                        isSecret      = true,
                    )
                    SettingsRowDivider()
                    SettingsTextFieldRow(
                        title         = "Base URL",
                        value         = miniMaxUrl,
                        onValueChange = vm::setMiniMaxBaseUrl,
                        placeholder   = "https://api.minimax.io/v1",
                    )
                    SettingsRowDivider()
                    SettingsTextFieldRow(
                        title         = "Model",
                        value         = miniMaxModel,
                        onValueChange = vm::setMiniMaxModel,
                        placeholder   = "MiniMax-M2.7",
                    )
                }
            }

            else -> {
                SettingsGroup(title = "API key") {
                    SettingsTextFieldRow(
                        title         = "$provider API key",
                        value         = apiKey,
                        onValueChange = vm::setApiKey,
                        placeholder   = "sk-…",
                        isSecret      = true,
                    )
                }
            }
        }

    }
}
