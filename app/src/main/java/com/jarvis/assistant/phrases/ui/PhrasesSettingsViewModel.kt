package com.jarvis.assistant.phrases.ui

import android.app.Application
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jarvis.assistant.phrases.PhraseCategory
import com.jarvis.assistant.phrases.PhraseEntry
import com.jarvis.assistant.phrases.PhraseRegistry
import com.jarvis.assistant.phrases.PhraseResolver
import com.jarvis.assistant.phrases.PhraseVariant
import com.jarvis.assistant.phrases.db.PhraseDatabase
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

// ── UI state ──────────────────────────────────────────────────────────────────

data class PhrasesUiState(
    val phrases: List<PhraseEntry> = emptyList(),
    val searchQuery: String = "",
    val selectedCategory: PhraseCategory? = null,
    val isLoading: Boolean = true,
)

/** One-shot events fired on the main thread for the screen to consume. */
sealed interface PhrasesEvent {
    data class TestSpeak(val text: String) : PhrasesEvent
    data class ExportReady(val json: String) : PhrasesEvent
    data class ShowToast(val message: String) : PhrasesEvent
}

// ── ViewModel ─────────────────────────────────────────────────────────────────

class PhrasesSettingsViewModel(app: Application) : AndroidViewModel(app) {

    private val TAG = "PhrasesSettingsVM"

    private val store    = PhraseDatabase.getStore(app)
    private val resolver = PhraseResolver(store = store)

    // Source of truth: merged PhraseEntry list (defaults + user overrides applied)
    private val _mergedPhrases = MutableStateFlow<List<PhraseEntry>>(emptyList())
    private val _searchQuery   = MutableStateFlow("")
    private val _category      = MutableStateFlow<PhraseCategory?>(null)
    private val _isLoading     = MutableStateFlow(true)

    val uiState: StateFlow<PhrasesUiState> = combine(
        _mergedPhrases,
        _searchQuery,
        _category,
        _isLoading,
    ) { phrases, query, category, loading ->
        val filtered = phrases
            .filter { entry ->
                (category == null || entry.category == category) &&
                (query.isBlank() ||
                    entry.key.contains(query, ignoreCase = true) ||
                    entry.defaultText.contains(query, ignoreCase = true) ||
                    entry.description.contains(query, ignoreCase = true) ||
                    entry.variants.any { v -> v.text.contains(query, ignoreCase = true) })
            }
        PhrasesUiState(
            phrases          = filtered,
            searchQuery      = query,
            selectedCategory = category,
            isLoading        = loading,
        )
    }.stateIn(
        scope            = viewModelScope,
        started          = SharingStarted.WhileSubscribed(5_000),
        initialValue     = PhrasesUiState(),
    )

    // One-shot event channel — never replays
    private val _events = Channel<PhrasesEvent>(Channel.BUFFERED)
    val events = _events.receiveAsFlow()

    init {
        loadAll()
    }

    // ── Filter controls ───────────────────────────────────────────────────────

    fun setSearch(q: String) {
        _searchQuery.value = q
    }

    fun setCategory(cat: PhraseCategory?) {
        _category.value = cat
    }

    // ── Mutations ─────────────────────────────────────────────────────────────

    fun saveVariant(key: String, variant: PhraseVariant) {
        viewModelScope.launch {
            try {
                store.saveVariant(key, variant)
                resolver.invalidateCache(key)
                refreshKey(key)
            } catch (e: Exception) {
                Log.e(TAG, "saveVariant: failed for key='$key'", e)
                _events.send(PhrasesEvent.ShowToast("Failed to save variant."))
            }
        }
    }

    fun deleteVariant(key: String, variantId: String) {
        viewModelScope.launch {
            try {
                store.deleteVariant(key, variantId)
                resolver.invalidateCache(key)
                refreshKey(key)
            } catch (e: Exception) {
                Log.e(TAG, "deleteVariant: failed for key='$key' variantId='$variantId'", e)
                _events.send(PhrasesEvent.ShowToast("Failed to delete variant."))
            }
        }
    }

    fun resetKey(key: String) {
        viewModelScope.launch {
            try {
                store.resetKey(key)
                resolver.invalidateCache(key)
                refreshKey(key)
            } catch (e: Exception) {
                Log.e(TAG, "resetKey: failed for key='$key'", e)
                _events.send(PhrasesEvent.ShowToast("Failed to reset phrase."))
            }
        }
    }

    fun exportJson() {
        viewModelScope.launch {
            try {
                val json = store.exportJson()
                _events.send(PhrasesEvent.ExportReady(json))
            } catch (e: Exception) {
                Log.e(TAG, "exportJson: failed", e)
                _events.send(PhrasesEvent.ShowToast("Export failed."))
            }
        }
    }

    fun importJson(json: String) {
        viewModelScope.launch {
            try {
                val result = store.importJson(json)
                resolver.refreshCache()
                loadAll()
                val msg = if (result.failed == 0) {
                    "Imported ${result.imported} variants."
                } else {
                    "Imported ${result.imported}, failed ${result.failed}."
                }
                _events.send(PhrasesEvent.ShowToast(msg))
            } catch (e: Exception) {
                Log.e(TAG, "importJson: failed", e)
                _events.send(PhrasesEvent.ShowToast("Import failed: ${e.message}"))
            }
        }
    }

    /**
     * Fire a test-speak event so the screen (or TTS host) can speak the
     * currently resolved text for [key] using [vars].
     */
    fun testSpeak(key: String, vars: Map<String, String> = emptyMap()) {
        val text = resolver.resolve(key, vars)
        viewModelScope.launch {
            if (text.isNotBlank()) {
                _events.send(PhrasesEvent.TestSpeak(text))
            } else {
                _events.send(PhrasesEvent.ShowToast("Phrase is empty — nothing to speak."))
            }
        }
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    private fun loadAll() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                resolver.refreshCache()
                _mergedPhrases.value = buildMergedList()
            } catch (e: Exception) {
                Log.e(TAG, "loadAll: failed", e)
            } finally {
                _isLoading.value = false
            }
        }
    }

    private suspend fun refreshKey(key: String) {
        val updated = _mergedPhrases.value.toMutableList()
        val idx = updated.indexOfFirst { it.key == key }
        if (idx >= 0) {
            val overrides = store.getOverride(key)
            updated[idx] = updated[idx].copy(variants = overrides)
            _mergedPhrases.value = updated
        }
    }

    private suspend fun buildMergedList(): List<PhraseEntry> {
        val allOverrides = store.getAllOverrides()
        return PhraseRegistry.defaults.values.map { entry ->
            val userVariants = allOverrides[entry.key]
            if (userVariants != null) entry.copy(variants = userVariants) else entry
        }
    }
}
