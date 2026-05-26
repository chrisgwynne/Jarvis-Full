package com.jarvis.assistant.ui

import android.app.Application
import android.net.Uri
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jarvis.assistant.audio.TtsEngine
import com.jarvis.assistant.auth.OAuthCallbackHolder
import com.jarvis.assistant.auth.OpenAiOAuthManager
import com.jarvis.assistant.service.JarvisService
import com.jarvis.assistant.memory.db.JarvisDatabase
import com.jarvis.assistant.tools.smart.HomeAssistantClient
import com.jarvis.assistant.util.SettingsStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.Locale
import java.util.UUID

/** A TTS voice entry shown in the voice picker. */
data class TtsVoiceInfo(
    /** Internal key stored in [SettingsStore.ttsVoiceName]. */
    val name: String,
    /** Human-readable label shown in the UI. */
    val displayName: String,
    /** True if the voice requires a network connection. */
    val isNetwork: Boolean
)

/**
 * SettingsViewModel — bridges SettingsStore (disk) and the Compose UI.
 */
class SettingsViewModel(app: Application) : AndroidViewModel(app) {

    val providers = listOf("OpenAI", "Anthropic", "Gemini", "Ollama", "OpenRouter", "Kimi", "MiniMax")

    private val store         = SettingsStore(app)
    private val db            = JarvisDatabase.getInstance(app)

    // ── Exposed state ──────────────────────────────────────────────────────

    private val _llmProvider = MutableStateFlow(store.llmProvider)
    val llmProvider: StateFlow<String> = _llmProvider.asStateFlow()

    private val _apiKey = MutableStateFlow(store.apiKey)
    val apiKey: StateFlow<String> = _apiKey.asStateFlow()

    private val _ollamaBaseUrl = MutableStateFlow(store.ollamaBaseUrl)
    val ollamaBaseUrl: StateFlow<String> = _ollamaBaseUrl.asStateFlow()

    private val _miniMaxBaseUrl = MutableStateFlow(store.miniMaxBaseUrl)
    val miniMaxBaseUrl: StateFlow<String> = _miniMaxBaseUrl.asStateFlow()

    private val _miniMaxModel = MutableStateFlow(store.miniMaxModel)
    val miniMaxModel: StateFlow<String> = _miniMaxModel.asStateFlow()

    private val _wakeWord = MutableStateFlow(store.wakeWord)
    val wakeWord: StateFlow<String> = _wakeWord.asStateFlow()

    private val _voiceResponse = MutableStateFlow(store.voiceResponse)
    val voiceResponse: StateFlow<Boolean> = _voiceResponse.asStateFlow()

    private val _ttsVoiceName = MutableStateFlow(store.ttsVoiceName)
    val ttsVoiceName: StateFlow<String> = _ttsVoiceName.asStateFlow()

    private val _braveSearchApiKey = MutableStateFlow(store.braveSearchApiKey)
    val braveSearchApiKey: StateFlow<String> = _braveSearchApiKey.asStateFlow()

    private val _defaultMsgChannel = MutableStateFlow(store.defaultMsgChannel)
    val defaultMsgChannel: StateFlow<String> = _defaultMsgChannel.asStateFlow()

    /** Available TTS voices on this device (populated asynchronously). */
    private val _availableVoices = MutableStateFlow<List<TtsVoiceInfo>>(emptyList())
    val availableVoices: StateFlow<List<TtsVoiceInfo>> = _availableVoices.asStateFlow()

    // Kept alive after enumeration so it can also play voice previews
    private var previewTts: TextToSpeech? = null

    // ── Memory management ──────────────────────────────────────────────────────

    /** Wipe all memory_entries rows (summaries, preferences, facts, tasks). */
    fun clearAllMemories() {
        viewModelScope.launch(Dispatchers.IO) {
            db.memoryDao().deleteAll()
            db.memoryFactDao().deleteAll()
        }
    }

    /** Wipe conversation_turns + conversation_sessions only (raw dialogue history). */
    fun clearConversationHistory() {
        viewModelScope.launch(Dispatchers.IO) {
            db.conversationDao().deleteAllTurns()
            db.conversationDao().deleteAllSessions()
        }
    }

    // ── Settings home state (used by SettingsHomeScreen) ──────────────────────

    private val _developerModeEnabled = MutableStateFlow(store.developerModeEnabled)
    val developerModeEnabled: StateFlow<Boolean> = _developerModeEnabled.asStateFlow()

    fun setDeveloperMode(enabled: Boolean) {
        store.developerModeEnabled = enabled
        _developerModeEnabled.value = enabled
    }

    /** Quick-read for the HA configuration badge on the home screen. */
    val haConfigured: Boolean get() = store.haBaseUrl.isNotBlank() && store.haApiToken.isNotBlank()

    /** Quick-read for the Mac Bridge configuration badge on the home screen. */
    val macBridgeConfigured: Boolean get() = store.macBridgeEnabled && store.macBridgeHost.isNotBlank()

    /** Quick-read for the Mac Brain configuration badge on the home screen. */
    val macBrainConfigured: Boolean get() = store.macBrainEnabled && store.macBrainBaseUrl.isNotBlank()

    /** Quick-read: proactive engine is on. */
    val proactivityEnabled: Boolean get() = store.proactivityEnabled

    /** Quick-read: a TTS voice has been selected (any non-blank name). */
    val ttsVoiceConfigured: Boolean get() = store.ttsVoiceName.isNotBlank()

    init {
        enumerateVoices()
    }

    private fun enumerateVoices() {
        previewTts = TextToSpeech(getApplication()) { status ->
            if (status != TextToSpeech.SUCCESS) return@TextToSpeech

            // All English voices, both offline and online, sorted by locale then name
            val rawVoices = previewTts?.voices
                ?.filter { it.locale.language == "en" }
                ?.sortedWith(compareBy({ it.locale.toLanguageTag() }, { it.name }))
                ?: emptyList()

            // Group by locale+gender so voices can be numbered meaningfully within each group
            val byGroup = rawVoices.groupBy { "${it.locale.toLanguageTag()}|${detectGender(it) ?: "?"}" }

            val deviceVoices = rawVoices.map { voice ->
                val groupKey = "${voice.locale.toLanguageTag()}|${detectGender(voice) ?: "?"}"
                val group    = byGroup[groupKey] ?: listOf(voice)
                val idxInGroup = group.indexOf(voice)
                TtsVoiceInfo(
                    name        = voice.name,
                    displayName = friendlyVoiceName(voice, idxInGroup, group.size),
                    isNetwork   = voice.isNetworkConnectionRequired
                )
            }

            // Include the bundled Piper neural voice at the top of the list.
            // When selected, TtsEngine will prefer the Piper path regardless
            // of the experimental flag state (which is primarily for testing
            // the G2P mapping on the system-default path).
            val allVoices = deviceVoices.toMutableList()
            allVoices.add(0, TtsVoiceInfo(
                name        = "piper:${com.jarvis.assistant.voice.piper.PiperVoiceRegistry.DEFAULT_VOICE_ID}",
                displayName = "Jarvis (Neural · Offline)",
                isNetwork   = false
            ))

            _availableVoices.value = allVoices
            // previewTts kept alive for previewVoice()
        }
    }

    /**
     * Speak a short sample phrase with [voiceName] so the user can audition it.
     * For the local Piper voice, routes the request through [JarvisService] so the
     * real TTS engine (including the ONNX model) is used.
     *
     * Suppresses JarvisService wake detection for the duration of playback so the
     * sample audio doesn't accidentally trigger the voice pipeline.
     */
    fun previewVoice(voiceName: String) {
        if (voiceName.startsWith("piper:")) {
            // Local Piper voice runs through the service runtime so it can use
            // the ONNX session + AudioTrack dispatcher.
            com.jarvis.assistant.service.JarvisService.testTts(
                getApplication(),
                voiceName.removePrefix("piper:")
            )
            return
        }

        val tts   = previewTts ?: return
        val voice = tts.voices?.find { it.name == voiceName } ?: return
        tts.voice = voice

        val app = getApplication<Application>()

        // Pause wake-word detection so the sample doesn't trigger Jarvis
        JarvisService.suppressWake(app)

        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) {
                JarvisService.restoreWake(app)
            }
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                JarvisService.restoreWake(app)
            }
            override fun onError(utteranceId: String?, errorCode: Int) {
                JarvisService.restoreWake(app)
            }
        })

        tts.speak(
            "Hi, I'm Jarvis. This is how I sound.",
            TextToSpeech.QUEUE_FLUSH,
            null,
            "jarvis_preview"
        )
    }

    /**
     * Try to infer gender from the voice's internal name.
     *
     * Covers Samsung TTS (`en-us-x-samf1-local`, `en-us-x-samm1-local`),
     * voices with explicit "male"/"female" substrings, and some OEM patterns
     * (e.g. `-f-`, `-m-` separators).  Returns null when undetermined.
     */
    private fun detectGender(voice: Voice): String? {
        val n = voice.name.lowercase()
        return when {
            "female" in n || "woman" in n || "girl" in n         -> "Female"
            ("male" in n && "female" !in n) || "man" in n        -> "Male"
            // Samsung: en-us-x-samf1-local / en-us-x-samm1-local
            Regex("""-samf\d+-""").containsMatchIn(n)            -> "Female"
            Regex("""-samm\d+-""").containsMatchIn(n)            -> "Male"
            // Generic OEM: -f1-, -f2-, -m1-, -m2- separators
            Regex("""-f\d+-""").containsMatchIn(n)               -> "Female"
            Regex("""-m\d+-""").containsMatchIn(n)               -> "Male"
            // voices whose 3-letter ID ends in 'f' (common Google pattern)
            Regex("""-x-[a-z]{2}f-""").containsMatchIn(n)       -> "Female"
            Regex("""-x-[a-z]{2}m-""").containsMatchIn(n)       -> "Male"
            else                                                   -> null
        }
    }

    /** Build a human-friendly label from an Android [Voice] object. */
    private fun friendlyVoiceName(voice: Voice, idxInGroup: Int, totalInGroup: Int): String {
        val accentLabel = accentName(voice.locale)
        val gender  = detectGender(voice)
        val quality = when {
            voice.quality >= Voice.QUALITY_VERY_HIGH -> "HD"
            voice.quality >= Voice.QUALITY_HIGH      -> "HQ"
            else                                      -> null
        }
        val network = if (voice.isNetworkConnectionRequired) "Online" else null
        val index   = if (totalInGroup > 1) "#${idxInGroup + 1}" else null

        return listOfNotNull(accentLabel, gender, quality, network, index).joinToString(" · ")
    }

    /**
     * Map a locale to a concise, human-friendly accent name.
     * Falls back to `"Language (Country)"` for unlisted locales.
     */
    private fun accentName(locale: Locale): String = when (locale.toLanguageTag()) {
        "en-US", "en"   -> "American English"
        "en-GB"          -> "British English"
        "en-AU"          -> "Australian English"
        "en-IE"          -> "Irish English"
        "en-IN"          -> "Indian English"
        "en-CA"          -> "Canadian English"
        "en-ZA"          -> "South African English"
        "en-NG"          -> "Nigerian English"
        "en-NZ"          -> "New Zealand English"
        "en-PH"          -> "Filipino English"
        "en-SG"          -> "Singaporean English"
        "en-HK"          -> "Hong Kong English"
        "en-KE"          -> "Kenyan English"
        "en-TZ"          -> "Tanzanian English"
        "en-GH"          -> "Ghanaian English"
        else -> {
            val lang    = locale.getDisplayLanguage(Locale.ENGLISH).trim()
            val country = locale.getDisplayCountry(Locale.ENGLISH).trim()
            if (country.isNotBlank() && !country.equals(lang, ignoreCase = true))
                "$lang ($country)" else lang
        }
    }

    override fun onCleared() {
        super.onCleared()
        previewTts?.shutdown()
        previewTts = null
    }

    // ── OpenAI OAuth state ─────────────────────────────────────────────────

    private val _maxTokens = MutableStateFlow(store.maxTokens)
    val maxTokens: StateFlow<Int> = _maxTokens.asStateFlow()

    private val _fallbackProvider = MutableStateFlow(store.fallbackProvider)
    val fallbackProvider: StateFlow<String> = _fallbackProvider.asStateFlow()

    private val _haBaseUrl = MutableStateFlow(store.haBaseUrl)
    val haBaseUrl: StateFlow<String> = _haBaseUrl.asStateFlow()

    private val _haApiToken = MutableStateFlow(store.haApiToken)
    val haApiToken: StateFlow<String> = _haApiToken.asStateFlow()

    private val _haConnectionStatus = MutableStateFlow<String?>(null)
    val haConnectionStatus: StateFlow<String?> = _haConnectionStatus.asStateFlow()

    private val _openAiClientId = MutableStateFlow(store.openAiClientId)
    val openAiClientId: StateFlow<String> = _openAiClientId.asStateFlow()

    /** True once an access token is stored. */
    private val _openAiSignedIn = MutableStateFlow(
        store.openAiOAuthEnabled && store.openAiAccessToken.isNotBlank()
    )
    val openAiSignedIn: StateFlow<Boolean> = _openAiSignedIn.asStateFlow()

    private val _openAiOAuthError = MutableStateFlow<String?>(null)
    val openAiOAuthError: StateFlow<String?> = _openAiOAuthError.asStateFlow()

    // ── Mutators ───────────────────────────────────────────────────────────

    fun setLlmProvider(v: String) { _llmProvider.value = v; store.llmProvider = v }
    fun setApiKey(v: String)       { _apiKey.value = v;       store.apiKey = v }
    fun setOllamaBaseUrl(v: String){ _ollamaBaseUrl.value = v; store.ollamaBaseUrl = v }
    fun setMiniMaxBaseUrl(v: String){ _miniMaxBaseUrl.value = v; store.miniMaxBaseUrl = v }
    fun setMiniMaxModel(v: String) { _miniMaxModel.value = v; store.miniMaxModel = v }
    fun setWakeWord(v: String)     { _wakeWord.value = v;     store.wakeWord = v }
    fun setVoiceResponse(v: Boolean){ _voiceResponse.value = v; store.voiceResponse = v }

    // ── Safety / lifecycle ────────────────────────────────────────────────

    // ── Appearance (Phase 2) ──────────────────────────────────────────────
    private val _themeMode = MutableStateFlow(store.themeMode)
    val themeMode: StateFlow<String> = _themeMode.asStateFlow()

    private val _dynamicColor = MutableStateFlow(store.dynamicColor)
    val dynamicColor: StateFlow<Boolean> = _dynamicColor.asStateFlow()

    fun setThemeMode(v: String)     { _themeMode.value = v;    store.themeMode = v }
    fun setDynamicColor(v: Boolean) { _dynamicColor.value = v; store.dynamicColor = v }

    private val _toolExecutionDisabled = MutableStateFlow(store.toolExecutionDisabled)
    val toolExecutionDisabled: StateFlow<Boolean> = _toolExecutionDisabled.asStateFlow()

    private val _autoStartOnBoot = MutableStateFlow(store.autoStartOnBoot)
    val autoStartOnBoot: StateFlow<Boolean> = _autoStartOnBoot.asStateFlow()

    fun setToolExecutionDisabled(v: Boolean) {
        _toolExecutionDisabled.value = v
        store.toolExecutionDisabled  = v
    }

    fun setAutoStartOnBoot(v: Boolean) {
        _autoStartOnBoot.value = v
        store.autoStartOnBoot  = v
    }

    /**
     * Stop the foreground [JarvisService].  Reminders and other AlarmManager
     * callbacks continue to fire, but wake-word listening and the proactive
     * loop shut down.  The user can relaunch from the app's main screen.
     */
    fun stopJarvisService() {
        JarvisService.stop(getApplication())
    }
    fun setTtsVoiceName(v: String) {
        _ttsVoiceName.value = v
        store.ttsVoiceName  = v
        // Push the change to the running service so it takes effect without a restart
        if (JarvisService.isRunning(getApplication())) {
            JarvisService.applyVoice(getApplication(), v)
        }
    }
    fun setBraveSearchApiKey(v: String)  { _braveSearchApiKey.value = v; store.braveSearchApiKey = v }
    fun setDefaultMsgChannel(v: String)  { _defaultMsgChannel.value = v; store.defaultMsgChannel = v }
    fun setMaxTokens(v: Int)         { _maxTokens.value = v; store.maxTokens = v }
    fun setFallbackProvider(v: String){ _fallbackProvider.value = v; store.fallbackProvider = v }
    fun setHaBaseUrl(v: String)      { _haBaseUrl.value = v; store.haBaseUrl = v; _haConnectionStatus.value = null }
    fun setHaApiToken(v: String)     { _haApiToken.value = v; store.haApiToken = v; _haConnectionStatus.value = null }

    fun testHaConnection() {
        viewModelScope.launch {
            _haConnectionStatus.value = "Connecting…"
            val ok = try {
                HomeAssistantClient(store.haBaseUrl, store.haApiToken).testConnection()
            } catch (_: Exception) { false }
            _haConnectionStatus.value = if (ok) "Connected" else "Unreachable — check URL and token"
        }
    }

    fun setOpenAiClientId(v: String){ _openAiClientId.value = v; store.openAiClientId = v }

    // ── OpenAI OAuth ───────────────────────────────────────────────────────

    /**
     * Generate a PKCE challenge and return the URI to open in the browser.
     * Returns null if no client_id has been entered.
     *
     * Also registers a one-shot callback in OAuthCallbackHolder so that when
     * MainActivity receives the redirect it can hand the code back here.
     */
    fun buildSignInUri(): Uri? {
        val clientId = store.openAiClientId.trim()
        if (clientId.isBlank()) {
            _openAiOAuthError.value = "Enter your OpenAI client ID first."
            return null
        }

        val verifier   = OpenAiOAuthManager.generateCodeVerifier()
        val challenge  = OpenAiOAuthManager.generateCodeChallenge(verifier)
        val state      = UUID.randomUUID().toString()

        // Persist verifier so it survives across process restart (unlikely but safe)
        store.openAiCodeVerifier = verifier

        // Register callback — called by MainActivity when the redirect arrives
        OAuthCallbackHolder.pendingCallback = { code ->
            handleOAuthCode(code, verifier, clientId)
        }

        _openAiOAuthError.value = null
        return OpenAiOAuthManager.buildAuthUri(clientId, challenge, state)
    }

    private fun handleOAuthCode(code: String, verifier: String, clientId: String) {
        viewModelScope.launch {
            try {
                val (access, refresh) = OpenAiOAuthManager.exchangeCode(code, verifier, clientId)
                store.openAiAccessToken  = access
                store.openAiRefreshToken = refresh
                store.openAiOAuthEnabled = true
                store.openAiCodeVerifier = ""   // clear temporary value
                _openAiSignedIn.value = true
                _openAiOAuthError.value = null
            } catch (e: Exception) {
                _openAiOAuthError.value = "Sign-in failed. Please try again."
            }
        }
    }

    fun signOutOpenAi() {
        store.clearOpenAiOAuth()
        _openAiSignedIn.value = false
        _openAiOAuthError.value = null
    }

    // ── GitHub reporting state ─────────────────────────────────────────────

    private val _githubReportingEnabled = MutableStateFlow(store.githubReportingEnabled)
    val githubReportingEnabled: StateFlow<Boolean> = _githubReportingEnabled.asStateFlow()

    private val _githubToken     = MutableStateFlow(store.githubToken)
    val githubToken: StateFlow<String> = _githubToken.asStateFlow()

    private val _githubRepoOwner = MutableStateFlow(store.githubRepoOwner)
    val githubRepoOwner: StateFlow<String> = _githubRepoOwner.asStateFlow()

    private val _githubRepoName  = MutableStateFlow(store.githubRepoName)
    val githubRepoName: StateFlow<String> = _githubRepoName.asStateFlow()

    fun setGithubReportingEnabled(v: Boolean) { _githubReportingEnabled.value = v; store.githubReportingEnabled = v }
    fun setGithubToken(v: String)     { _githubToken.value = v;     store.githubToken = v }
    fun setGithubRepoOwner(v: String) { _githubRepoOwner.value = v; store.githubRepoOwner = v }
    fun setGithubRepoName(v: String)  { _githubRepoName.value = v;  store.githubRepoName = v }

    // ── Vision state ───────────────────────────────────────────────────────

    private val _visionEnabled                       = MutableStateFlow(store.visionEnabled)
    val visionEnabled: StateFlow<Boolean>            = _visionEnabled.asStateFlow()

    private val _preferPhoneCamera                   = MutableStateFlow(store.preferPhoneCamera)
    val preferPhoneCamera: StateFlow<Boolean>        = _preferPhoneCamera.asStateFlow()

    private val _visionAutoFallbackToPhone           = MutableStateFlow(store.visionAutoFallbackToPhone)
    val visionAutoFallbackToPhone: StateFlow<Boolean> = _visionAutoFallbackToPhone.asStateFlow()

    private val _screenshotAnalysisEnabled           = MutableStateFlow(store.screenshotAnalysisEnabled)
    val screenshotAnalysisEnabled: StateFlow<Boolean> = _screenshotAnalysisEnabled.asStateFlow()

    private val _screenshotListenerEnabled           = MutableStateFlow(store.screenshotListenerEnabled)
    val screenshotListenerEnabled: StateFlow<Boolean> = _screenshotListenerEnabled.asStateFlow()

    private val _ocrEnabled                          = MutableStateFlow(store.ocrEnabled)
    val ocrEnabled: StateFlow<Boolean>               = _ocrEnabled.asStateFlow()

    private val _saveVisualContext                   = MutableStateFlow(store.saveVisualContext)
    val saveVisualContext: StateFlow<Boolean>        = _saveVisualContext.asStateFlow()

    private val _visualMemoryRetentionDays           = MutableStateFlow(store.visualMemoryRetentionDays)
    val visualMemoryRetentionDays: StateFlow<Int>    = _visualMemoryRetentionDays.asStateFlow()

    fun setVisionEnabled(v: Boolean)               { _visionEnabled.value = v;               store.visionEnabled = v }
    fun setPreferPhoneCamera(v: Boolean)           { _preferPhoneCamera.value = v;           store.preferPhoneCamera = v }
    fun setVisionAutoFallbackToPhone(v: Boolean)   { _visionAutoFallbackToPhone.value = v;   store.visionAutoFallbackToPhone = v }
    fun setScreenshotAnalysisEnabled(v: Boolean)   { _screenshotAnalysisEnabled.value = v;   store.screenshotAnalysisEnabled = v }
    fun setScreenshotListenerEnabled(v: Boolean)   { _screenshotListenerEnabled.value = v;   store.screenshotListenerEnabled = v }
    fun setOcrEnabled(v: Boolean)                  { _ocrEnabled.value = v;                  store.ocrEnabled = v }
    fun setSaveVisualContext(v: Boolean)            { _saveVisualContext.value = v;            store.saveVisualContext = v }
    fun setVisualMemoryRetentionDays(v: Int)        { _visualMemoryRetentionDays.value = v;   store.visualMemoryRetentionDays = v }

    // ── App control ───────────────────────────────────────────────────────────

    private val _appControlEnabled              = MutableStateFlow(store.appControlEnabled)
    val appControlEnabled: StateFlow<Boolean>   = _appControlEnabled.asStateFlow()

    private val _allowAccessibilityAppControl            = MutableStateFlow(store.allowAccessibilityAppControl)
    val allowAccessibilityAppControl: StateFlow<Boolean> = _allowAccessibilityAppControl.asStateFlow()

    private val _allowAppClose              = MutableStateFlow(store.allowAppClose)
    val allowAppClose: StateFlow<Boolean>   = _allowAppClose.asStateFlow()

    fun setAppControlEnabled(v: Boolean)             { _appControlEnabled.value = v;             store.appControlEnabled = v }
    fun setAllowAccessibilityAppControl(v: Boolean)  { _allowAccessibilityAppControl.value = v;  store.allowAccessibilityAppControl = v }
    fun setAllowAppClose(v: Boolean)                 { _allowAppClose.value = v;                 store.allowAppClose = v }

    // ── Mac Brain settings ─────────────────────────────────────────────────────

    private val _macBrainEnabled             = MutableStateFlow(store.macBrainEnabled)
    val macBrainEnabled: StateFlow<Boolean>  = _macBrainEnabled.asStateFlow()

    private val _macBrainBaseUrl             = MutableStateFlow(store.macBrainBaseUrl)
    val macBrainBaseUrl: StateFlow<String>   = _macBrainBaseUrl.asStateFlow()

    private val _macBrainApiKey              = MutableStateFlow(store.macBrainApiKey)
    val macBrainApiKey: StateFlow<String>    = _macBrainApiKey.asStateFlow()

    private val _macBrainWifiOnly            = MutableStateFlow(store.macBrainWifiOnly)
    val macBrainWifiOnly: StateFlow<Boolean> = _macBrainWifiOnly.asStateFlow()

    private val _macBrainAllowMemory             = MutableStateFlow(store.macBrainAllowMemory)
    val macBrainAllowMemory: StateFlow<Boolean>  = _macBrainAllowMemory.asStateFlow()

    private val _macBrainAllowProject            = MutableStateFlow(store.macBrainAllowProject)
    val macBrainAllowProject: StateFlow<Boolean> = _macBrainAllowProject.asStateFlow()

    private val _macBrainAllowPreferences            = MutableStateFlow(store.macBrainAllowPreferences)
    val macBrainAllowPreferences: StateFlow<Boolean> = _macBrainAllowPreferences.asStateFlow()

    private val _macBrainAllowOutcomes            = MutableStateFlow(store.macBrainAllowOutcomeReporting)
    val macBrainAllowOutcomes: StateFlow<Boolean> = _macBrainAllowOutcomes.asStateFlow()

    private val _macBrainAllowHaReporting            = MutableStateFlow(store.macBrainAllowHaReporting)
    val macBrainAllowHaReporting: StateFlow<Boolean> = _macBrainAllowHaReporting.asStateFlow()

    private val _macBrainTestStatus            = MutableStateFlow<String?>(null)
    val macBrainTestStatus: StateFlow<String?> = _macBrainTestStatus.asStateFlow()

    private val _macBrainUrlError              = MutableStateFlow<String?>(null)
    val macBrainUrlError: StateFlow<String?>   = _macBrainUrlError.asStateFlow()

    /** Live diagnostics snapshot from MacBrainStats — updated by HttpMacBrainClient. */
    val brainDiagnostics = com.jarvis.assistant.remote.macbrain.MacBrainStats.snapshot

    fun setMacBrainEnabled(v: Boolean) {
        store.macBrainEnabled = v
        _macBrainEnabled.value = v
        com.jarvis.assistant.remote.macbrain.MacBrainStats.record { copy(enabled = v) }
        if (!v) _macBrainTestStatus.value = null
    }

    fun setMacBrainBaseUrl(v: String) {
        store.macBrainBaseUrl = v
        _macBrainBaseUrl.value = v
        _macBrainTestStatus.value = null
        _macBrainUrlError.value = validateBrainUrl(v)
    }

    fun setMacBrainApiKey(v: String) {
        store.macBrainApiKey = v
        _macBrainApiKey.value = v
        _macBrainTestStatus.value = null
    }

    fun setMacBrainWifiOnly(v: Boolean)          { store.macBrainWifiOnly = v;                    _macBrainWifiOnly.value = v }
    fun setMacBrainAllowMemory(v: Boolean)       { store.macBrainAllowMemory = v;                 _macBrainAllowMemory.value = v }
    fun setMacBrainAllowProject(v: Boolean)      { store.macBrainAllowProject = v;                _macBrainAllowProject.value = v }
    fun setMacBrainAllowPreferences(v: Boolean)  { store.macBrainAllowPreferences = v;            _macBrainAllowPreferences.value = v }
    fun setMacBrainAllowOutcomes(v: Boolean)     { store.macBrainAllowOutcomeReporting = v;       _macBrainAllowOutcomes.value = v }
    fun setMacBrainAllowHaReporting(v: Boolean)  { store.macBrainAllowHaReporting = v;            _macBrainAllowHaReporting.value = v }

    fun clearBrainCache() { com.jarvis.assistant.remote.macbrain.MacBrainStats.clearCache() }
    fun resetBrainCircuit() { com.jarvis.assistant.remote.macbrain.MacBrainStats.resetCircuit() }

    /** Fire a test connection to /brain/health without touching the feature flag. */
    fun testBrainConnection() {
        viewModelScope.launch(Dispatchers.IO) {
            _macBrainTestStatus.value = "Testing…"
            val baseUrl = store.macBrainBaseUrl.trimEnd('/')
            val apiKey  = store.macBrainApiKey
            if (baseUrl.isBlank()) {
                _macBrainTestStatus.value = "Not configured — set server address first"
                return@launch
            }
            try {
                val url = "$baseUrl/brain/health"
                val req = okhttp3.Request.Builder()
                    .url(url)
                    .apply { if (apiKey.isNotBlank()) header("Authorization", "Bearer $apiKey") }
                    .build()
                val t0   = System.currentTimeMillis()
                val resp = com.jarvis.assistant.llm.NetworkClient.http.newCall(req).execute()
                val ms   = System.currentTimeMillis() - t0
                _macBrainTestStatus.value = when (resp.code) {
                    200      -> "Connected (${ms}ms)"
                    401, 403 -> "Auth failed — check token"
                    else     -> "Unexpected response (HTTP ${resp.code})"
                }
                resp.close()
            } catch (e: java.net.SocketTimeoutException) {
                _macBrainTestStatus.value = "Timed out"
            } catch (e: java.net.UnknownHostException) {
                _macBrainTestStatus.value = "Unreachable — DNS failed"
            } catch (e: java.net.ConnectException) {
                _macBrainTestStatus.value = "Connection refused — check URL and port"
            } catch (e: javax.net.ssl.SSLException) {
                _macBrainTestStatus.value = "SSL error — check the URL is http://, not https://"
            } catch (e: java.io.IOException) {
                _macBrainTestStatus.value = "Network error — couldn't reach the server"
            } catch (e: Exception) {
                _macBrainTestStatus.value = "Unexpected error — check the address and try again"
            }
        }
    }

    private fun validateBrainUrl(url: String): String? {
        if (url.isBlank()) return null
        if (url.startsWith("https://", ignoreCase = true))
            return "Mac Brain runs plain HTTP — change https:// to http:// (Tailscale encrypts the connection)"
        return if (url.startsWith("http://", ignoreCase = true)) null
        else "URL must start with http:// (e.g. http://100.x.x.x:7474)"
    }

    // ── Brain Gateway settings ─────────────────────────────────────────────────

    private val gatewayRepo = com.jarvis.assistant.JarvisApp.brainGatewaySettings

    private val _gatewayTestStatus            = MutableStateFlow<String?>(null)
    val gatewayTestStatus: StateFlow<String?> = _gatewayTestStatus.asStateFlow()

    private val _gatewayPairStatus            = MutableStateFlow<String?>(null)
    val gatewayPairStatus: StateFlow<String?> = _gatewayPairStatus.asStateFlow()

    /** Test the gateway /health endpoint and update [gatewayTestStatus]. */
    fun testGatewayConnection() {
        viewModelScope.launch(Dispatchers.IO) {
            val cfg = gatewayRepo.snapshot()
            if (cfg.baseUrl.isBlank()) {
                _gatewayTestStatus.value = "Not configured — scan QR or enter URL first"
                return@launch
            }
            _gatewayTestStatus.value = "Testing…"
            try {
                val req = okhttp3.Request.Builder()
                    .url(cfg.healthUrl)
                    .build()
                val t0   = System.currentTimeMillis()
                val resp = com.jarvis.assistant.llm.NetworkClient.http.newCall(req).execute()
                val ms   = System.currentTimeMillis() - t0
                _gatewayTestStatus.value = when (resp.code) {
                    200      -> "Reachable (${ms}ms)"
                    401, 403 -> "Auth failed — re-pair required"
                    else     -> "Unexpected response (HTTP ${resp.code})"
                }
                resp.close()
            } catch (e: java.net.SocketTimeoutException) {
                _gatewayTestStatus.value = "Timed out"
            } catch (e: java.net.UnknownHostException) {
                _gatewayTestStatus.value = "Unreachable — DNS failed"
            } catch (e: java.net.ConnectException) {
                _gatewayTestStatus.value = "Connection refused — check URL and port"
            } catch (e: javax.net.ssl.SSLException) {
                _gatewayTestStatus.value = "SSL error — check the URL is http://, not https://"
            } catch (e: java.io.IOException) {
                _gatewayTestStatus.value = "Network error — couldn't reach the server"
            } catch (e: Exception) {
                _gatewayTestStatus.value = "Unexpected error — check the address and try again"
            }
        }
    }

    /**
     * Complete the pairing handshake after a QR scan.
     * Saves the session token on success and updates [gatewayPairStatus].
     */
    fun completeGatewayPairing(gatewayUrl: String, pairingCode: String, deviceName: String) {
        viewModelScope.launch(Dispatchers.IO) {
            _gatewayPairStatus.value = "Pairing…"
            val cfg  = gatewayRepo.snapshot()
            val name = deviceName.ifBlank { cfg.deviceName.ifBlank { android.os.Build.MODEL } }
            val result = com.jarvis.assistant.JarvisApp.brainGatewayPairingClient.pair(
                baseUrl     = gatewayUrl,
                pairingCode = pairingCode,
                deviceId    = cfg.deviceId.ifBlank { java.util.UUID.randomUUID().toString() },
                deviceName  = name,
                appVersion  = try {
                    getApplication<android.app.Application>()
                        .packageManager
                        .getPackageInfo(getApplication<android.app.Application>().packageName, 0)
                        .versionName ?: ""
                } catch (_: Exception) { "" },
            )
            when (result) {
                is com.jarvis.assistant.remote.gateway.PairResult.Success -> {
                    gatewayRepo.savePaired(
                        sessionToken = result.sessionToken,
                        baseUrl      = gatewayUrl,
                    )
                    // Persist device name if provided
                    val updated = gatewayRepo.snapshot().copy(deviceName = name)
                    gatewayRepo.save(updated)
                    _gatewayPairStatus.value = "Paired with ${result.macDeviceName}"
                    _gatewayTestStatus.value = null
                }
                is com.jarvis.assistant.remote.gateway.PairResult.Failure -> {
                    _gatewayPairStatus.value = when (result.reason) {
                        com.jarvis.assistant.remote.gateway.PairFailure.InvalidCode ->
                            "Wrong pairing code — regenerate it on Mac Jarvis"
                        com.jarvis.assistant.remote.gateway.PairFailure.AlreadyPaired ->
                            "Already paired — unpair on Mac first"
                        com.jarvis.assistant.remote.gateway.PairFailure.MacUnavailable ->
                            "Mac unavailable — check URL and network"
                        com.jarvis.assistant.remote.gateway.PairFailure.BadResponse ->
                            "Unexpected response — is this a Jarvis Gateway?"
                    }
                }
            }
        }
    }

    /** Clear the session token and mark as unpaired. */
    fun unpairGateway() {
        gatewayRepo.clearAll()
        _gatewayTestStatus.value = null
        _gatewayPairStatus.value = null
    }

    /** Update the device name stored in the gateway config. */
    fun setGatewayDeviceName(name: String) {
        val updated = gatewayRepo.snapshot().copy(deviceName = name)
        gatewayRepo.save(updated)
    }

    /** Update the transport mode stored in the gateway config. */
    fun setGatewayTransportMode(mode: com.jarvis.assistant.remote.gateway.TransportMode) {
        val updated = gatewayRepo.snapshot().copy(transportMode = mode)
        gatewayRepo.save(updated)
    }
}
