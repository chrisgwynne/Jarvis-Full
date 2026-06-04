package com.jarvis.assistant.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jarvis.assistant.memory.db.JarvisDatabase
import com.jarvis.assistant.memory.db.entity.ConversationTurn
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class ConversationViewModel(app: Application) : AndroidViewModel(app) {

    private val dao = JarvisDatabase.getInstance(app).conversationDao()

    private val _turns = MutableStateFlow<List<ConversationTurn>>(emptyList())
    val turns: StateFlow<List<ConversationTurn>> = _turns.asStateFlow()

    // #40: reactive collection of a Room Flow — updates on write instead of a
    // 1.5s busy-poll. (Method names kept so MainScreen's call sites are stable.)
    private var collectJob: Job? = null

    fun startPolling() {
        if (collectJob != null) return
        collectJob = viewModelScope.launch(Dispatchers.IO) {
            dao.observeRecentTurns(60).collect { _turns.value = it }
        }
    }

    fun stopPolling() {
        collectJob?.cancel()
        collectJob = null
    }

    fun refresh() {
        viewModelScope.launch(Dispatchers.IO) {
            _turns.value = dao.getRecentTurns(60)
        }
    }

    override fun onCleared() {
        super.onCleared()
        stopPolling()
    }
}
