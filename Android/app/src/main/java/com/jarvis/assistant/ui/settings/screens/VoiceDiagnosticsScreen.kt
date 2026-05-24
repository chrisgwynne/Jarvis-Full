package com.jarvis.assistant.ui.settings.screens

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.reliability.ListenerDiagnostics
import com.jarvis.assistant.runtime.power.BatteryOptimisationHelper
import com.jarvis.assistant.service.JarvisService
import com.jarvis.assistant.voice.VoiceFeatureFlags
import com.jarvis.assistant.voice.piper.PiperDiagnostics
import com.jarvis.assistant.voice.piper.SherpaPiperPhonemizer
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsToggleRow
import com.jarvis.assistant.ui.settings.SettingsValueRow
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
internal fun VoiceDiagnosticsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val scope   = rememberCoroutineScope()

    // Poll both Piper diagnostics and listener diagnostics every 500 ms.
    var snapshot by remember { mutableStateOf(PiperDiagnostics.snapshot()) }
    var listenerSnap by remember { mutableStateOf(ListenerDiagnostics.snapshot()) }
    var runtime      by remember { mutableStateOf(JarvisService.runtimeOrNull()) }
    var wakeLockHeld by remember { mutableStateOf(runtime?.isListeningWakeLockHeld() == true) }
    var batteryOk    by remember { mutableStateOf(BatteryOptimisationHelper.isIgnoringBatteryOptimisations(context)) }

    LaunchedEffect(Unit) {
        while (true) {
            snapshot     = PiperDiagnostics.snapshot()
            listenerSnap = ListenerDiagnostics.snapshot()
            runtime      = JarvisService.runtimeOrNull()
            wakeLockHeld = runtime?.isListeningWakeLockHeld() == true
            batteryOk    = BatteryOptimisationHelper.isIgnoringBatteryOptimisations(context)
            delay(500)
        }
    }

    val piper = try { JarvisApp.piperVoiceManager } catch (_: Exception) { null }
    val flagStore = try { JarvisApp.featureFlagStore } catch (_: Exception) { null }
    // Recompose on every override change so the toggle reflects state
    // written from elsewhere (e.g. the Experimental Flags screen).  Falls
    // back to a constant empty flow when the store isn't wired (test path).
    val overrides by remember(flagStore) {
        flagStore?.overridesFlow
            ?: kotlinx.coroutines.flow.MutableStateFlow<Map<String, Boolean?>>(emptyMap())
    }.collectAsState()
    @Suppress("UNUSED_VARIABLE")
    val _overridesObserved = overrides   // observed for recomposition only
    val flagOn = VoiceFeatureFlags.isEnabled(
        VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P
    )

    SettingsScaffold(title = "Voice Diagnostics", onBack = onBack, onClose = onClose) {

        // ── Listening lifecycle ───────────────────────────────────────────────
        SettingsGroup(
            title  = "Listening lifecycle",
            footer = "Live snapshot — updates every 500 ms.",
        ) {
            SettingsValueRow(
                title = "Service running",
                value = if (runtime != null) "yes" else "no",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Wake lock held",
                value = if (wakeLockHeld) "yes" else "no",
                description = if (!wakeLockHeld) "CPU may sleep while screen is off — Doze hole open." else null,
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Battery optimization",
                value = if (batteryOk) "disabled (good)" else "enabled (restricted)",
                description = if (!batteryOk) "Android may kill Jarvis in the background." else null,
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Role",
                value = listenerSnap.currentRole,
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "State",
                value = listenerSnap.currentListeningState,
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Wake detectors",
                value = listenerSnap.activeWakeDetectorCount.toString(),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Speech recognizers",
                value = listenerSnap.activeSpeechRecognizerCount.toString(),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last stop reason",
                value = listenerSnap.lastListenStopReason ?: "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last audio focus event",
                value = listenerSnap.lastAudioFocusEvent ?: "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Watchdog restarts",
                value = listenerSnap.watchdogRestartCount.toString(),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last watchdog restart",
                value = if (listenerSnap.lastWatchdogRestartMs > 0L)
                    "${(System.currentTimeMillis() - listenerSnap.lastWatchdogRestartMs) / 1000}s ago"
                else "—",
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Piper neural voice ────────────────────────────────────────────────
        SettingsInfoCard(
            title = "Piper voice",
            body  = "Optional local neural voice. Drop the .onnx + .onnx.json files into " +
                    "app/src/main/assets/voices/, install a phonemizer, then enable the " +
                    "experimental flag below and tap Reload Voice. The experimental flag is " +
                    "OFF by default so normal Jarvis speech is never affected by an " +
                    "in-development voice path."
        )

        // ── Experimental gate ───────────────────────────────────────────────
        // The flag is the master switch.  When OFF, PiperVoiceManager.isReady
        // returns false and every utterance goes to Android TTS.  Toggle ON
        // to test the experimental Kotlin G2P pipeline.
        SettingsGroup(
            title  = "Experimental gate",
            footer = "Master switch for the experimental Kotlin G2P. " +
                     "When OFF (default), normal Jarvis speech is unaffected. " +
                     "When ON, Piper is attempted; mapping success below " +
                     "${SherpaPiperPhonemizer.MIN_MAPPING_SUCCESS_PERCENT}% " +
                     "still falls back to Android TTS automatically.",
        ) {
            SettingsToggleRow(
                title       = "Use experimental Kotlin G2P",
                description = "Enables the bundled phonemizer + Piper synthesis path. " +
                              "OFF by default — flip ON to test, OFF to revert.",
                checked     = flagOn,
                enabled     = flagStore != null,
                onCheckedChange = { newValue ->
                    flagStore?.setOverride(
                        VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P,
                        newValue,
                    )
                },
            )
        }

        SettingsGroup(title = "Status") {
            SettingsValueRow(title = "Active voice", value = snapshot.activeVoiceId ?: "—")
            SettingsRowDivider()
            SettingsValueRow(title = "Model path", value = snapshot.modelPath ?: "—")
            SettingsRowDivider()
            SettingsValueRow(
                title = "Model size",
                value = if (snapshot.modelSizeBytes > 0)
                    "%.1f MB".format(snapshot.modelSizeBytes / (1024.0 * 1024.0))
                else "—",
            )
            SettingsRowDivider()
            SettingsValueRow(title = "JSON loaded", value = if (snapshot.jsonLoaded) "yes" else "no")
            SettingsRowDivider()
            SettingsValueRow(title = "ONNX loaded", value = if (snapshot.onnxLoaded) "yes" else "no")
            SettingsRowDivider()
            SettingsValueRow(
                title = "Phonemizer",
                value = if (snapshot.phonemizerAvailable)
                    "${snapshot.phonemizerName} (available)"
                else "not configured",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Sample rate",
                value = if (snapshot.sampleRate > 0) "${snapshot.sampleRate} Hz" else "—",
            )
        }

        // ── Last call detail — populated by SherpaPiperPhonemizer + engine.
        SettingsGroup(title = "Last call") {
            SettingsValueRow(
                title = "Normalized length",
                value = if (snapshot.lastNormalizedTextLen > 0)
                    "${snapshot.lastNormalizedTextLen} chars" else "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Phoneme generation",
                value = if (snapshot.lastPhonemeGenerationMs > 0)
                    "${snapshot.lastPhonemeGenerationMs} ms · ${snapshot.lastPhonemeCount} phonemes"
                else "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Phoneme IDs",
                value = if (snapshot.lastPhonemeIdCount > 0) {
                    val tail = if (snapshot.lastPhonemeIdSkips > 0)
                        " · ${snapshot.lastPhonemeIdSkips} skipped"
                    else ""
                    "${snapshot.lastPhonemeIdCount} ids$tail"
                } else "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Mapping success",
                value = when {
                    snapshot.phonemeMappingAbortedLowCoverage ->
                        "${snapshot.phonemeMappingSuccessPercent}% — ABORTED " +
                        "(threshold ${SherpaPiperPhonemizer.MIN_MAPPING_SUCCESS_PERCENT}%)"
                    snapshot.phonemeMappingSuccessPercent > 0 ->
                        "${snapshot.phonemeMappingSuccessPercent}%"
                    else -> "—"
                },
                description = "Fraction of generated phonemes that mapped to model ids. " +
                              "Below ${SherpaPiperPhonemizer.MIN_MAPPING_SUCCESS_PERCENT}% " +
                              "the synth aborts and Android TTS handles the utterance.",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Input tensor",
                value = snapshot.lastInputTensorShape.ifBlank { "—" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "PCM output",
                value = if (snapshot.lastPcmSamples > 0)
                    "${snapshot.lastPcmSamples} samples · ${snapshot.lastPcmDurationMs} ms"
                else "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Playback",
                value = when {
                    snapshot.lastPlaybackCompleted -> "completed"
                    snapshot.lastPlaybackStarted   -> "started (interrupted)"
                    else                           -> "—"
                },
            )
        }

        // ── Debug-only — empty unless SherpaPiperPhonemizer.LOG_VERBOSE_TEXT is on.
        if (snapshot.lastNormalizedTextDebug.isNotEmpty() ||
            snapshot.lastPhonemeListDebug.isNotEmpty()
        ) {
            SettingsGroup(
                title  = "Debug (verbose only)",
                footer = "Populated only when LOG_VERBOSE_TEXT is enabled in source — " +
                         "never leaves the device.",
            ) {
                SettingsValueRow(
                    title = "Normalized text",
                    value = snapshot.lastNormalizedTextDebug.ifBlank { "—" },
                )
                SettingsRowDivider()
                SettingsValueRow(
                    title = "Phonemes",
                    value = snapshot.lastPhonemeListDebug.ifBlank { "—" },
                )
            }
        }

        SettingsGroup(title = "Performance") {
            SettingsValueRow(
                title = "Load duration",
                value = if (snapshot.loadDurationMs > 0) "${snapshot.loadDurationMs} ms" else "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Memory before load",
                value = if (snapshot.memoryBeforeLoadBytes > 0)
                    "%.1f MB".format(snapshot.memoryBeforeLoadBytes / (1024.0 * 1024.0))
                else "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Memory after load",
                value = if (snapshot.memoryAfterLoadBytes > 0)
                    "%.1f MB".format(snapshot.memoryAfterLoadBytes / (1024.0 * 1024.0))
                else "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last inference",
                value = if (snapshot.lastInferenceMs > 0)
                    "${snapshot.lastInferenceMs} ms · ${snapshot.lastInferenceChars} phonemes"
                else "—",
            )
        }

        SettingsGroup(title = "Failures") {
            SettingsValueRow(
                title = "Fallback active",
                value = if (snapshot.fallbackActive) "yes (using Android TTS)" else "no",
            )
            SettingsRowDivider()
            SettingsValueRow(title = "Failure count", value = snapshot.failureCount.toString())
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last failure",
                value = snapshot.lastInferenceFailReason.ifBlank { "—" },
            )
        }

        SettingsGroup(
            title  = "Actions",
            footer = "These never crash the app — Android system TTS always remains available.",
        ) {
            SettingsActionRow(
                title       = "Test voice",
                description = "Speaks: \"Hello Chris. Systems are online.\"",
                actionLabel = "Test",
                onAction    = {
                    val mgr = piper ?: return@SettingsActionRow
                    scope.launch { mgr.speakTestPhrase() }
                },
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Reload voice",
                description = "Re-copies assets and rebuilds the ONNX session.",
                actionLabel = "Reload",
                onAction    = {
                    val mgr = piper ?: return@SettingsActionRow
                    scope.launch {
                        mgr.shutdown()
                        mgr.resetFallback()
                        mgr.initialize()
                    }
                },
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Clear voice cache",
                description = "Deletes copied model files from internal storage.",
                actionLabel = "Clear",
                destructive = true,
                confirm     = true,
                confirmCopy = "Yes, clear",
                onAction    = {
                    val mgr = piper ?: return@SettingsActionRow
                    scope.launch { mgr.clearCacheAndShutdown() }
                },
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Switch to Android TTS",
                description = "Trips the fallback flag — Piper is skipped until you reload.",
                actionLabel = "Use Android TTS",
                onAction    = {
                    val mgr = piper ?: return@SettingsActionRow
                    scope.launch { mgr.shutdown() }
                },
            )
        }
    }
}
