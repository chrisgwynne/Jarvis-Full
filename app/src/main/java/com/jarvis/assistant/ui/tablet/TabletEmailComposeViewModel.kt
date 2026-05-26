package com.jarvis.assistant.ui.tablet

import android.app.Application
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

/**
 * TabletEmailComposeViewModel — manages the full email compose state for the
 * tablet shell.
 *
 * Responsibilities:
 *  - Hold [TabletEmailComposeState] which survives screen rotation.
 *  - Auto-save dirty drafts to [TabletEmailDraftStore] on each change.
 *  - Integrate with [TabletFileContextStore] so "attach current file" works.
 *  - Build the send Intent (ACTION_SEND / ACTION_SENDTO) and launch it.
 *
 * What it deliberately does NOT do:
 *  - Speak or invoke the LLM — that is JarvisService's job.
 *  - Implement SMTP — Android email apps handle delivery.
 */
class TabletEmailComposeViewModel(app: Application) : AndroidViewModel(app) {

    private val draftStore = TabletEmailDraftStore(app)

    private val _state = MutableStateFlow(
        draftStore.load() ?: TabletEmailComposeState()
    )
    val state: StateFlow<TabletEmailComposeState> = _state.asStateFlow()

    // Observe the selected file so "attach current" always reflects reality.
    val selectedFile: StateFlow<TabletSelectedFile?> = TabletFileContextStore.selectedFile

    // ── Voice send trigger ────────────────────────────────────────────────────
    // Emitted when a "send email" voice command arrives — observed by
    // TabletEmailPanel to fire the send Intent on the main thread.
    private val _sendTrigger = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val sendTrigger: SharedFlow<Unit> = _sendTrigger

    // ── Voice command observer ────────────────────────────────────────────────
    init {
        viewModelScope.launch {
            TabletEmailCommandStore.commands.collect { intent ->
                applyVoiceIntent(intent)
            }
        }
    }

    // ── Voice intent application ──────────────────────────────────────────────

    private fun applyVoiceIntent(intent: TabletEmailVoiceIntent) {
        val ageMs = System.currentTimeMillis() - intent.issuedAtMs
        if (ageMs > TabletEmailCommandStore.STALE_THRESHOLD_MS) return

        // Apply field mutations only when values are present
        if (intent.to.isNotBlank())   mutate { copy(to = intent.to,           isDirty = true) }
        if (intent.subject.isNotBlank()) mutate { copy(subject = intent.subject, isDirty = true) }
        if (intent.body.isNotBlank()) mutate { copy(body = intent.body,       isDirty = true) }
        if (intent.appendBody.isNotBlank()) {
            mutate { copy(body = (if (body.isNotBlank()) "$body\n" else "") + intent.appendBody, isDirty = true) }
        }
        if (intent.attachCurrentFile)       attachSelectedFile()
        if (intent.removeLastAttachment)    _state.value.attachments.lastOrNull()?.let { removeAttachment(it) }
        if (intent.saveDraft)               saveDraft()
        if (intent.clearDraft)              clearDraft()
        if (intent.send)                    _sendTrigger.tryEmit(Unit)
    }

    // ── Field mutations ───────────────────────────────────────────────────────

    fun updateTo(v: String)      = mutate { copy(to = v,      isDirty = true) }
    fun updateCc(v: String)      = mutate { copy(cc = v,      isDirty = true) }
    fun updateBcc(v: String)     = mutate { copy(bcc = v,     isDirty = true) }
    fun updateSubject(v: String) = mutate { copy(subject = v, isDirty = true) }
    fun updateBody(v: String)    = mutate { copy(body = v,    isDirty = true) }
    fun toggleCcBcc()            = mutate { copy(showCcBcc = !showCcBcc) }

    // ── Attachments ───────────────────────────────────────────────────────────

    /** Attach the currently selected file from [TabletFileContextStore]. */
    fun attachSelectedFile() {
        val file = TabletFileContextStore.current ?: return
        if (_state.value.attachments.any { it.uri == file.uri }) return  // already attached
        mutate { copy(attachments = attachments + file, isDirty = true) }
    }

    fun removeAttachment(file: TabletSelectedFile) {
        mutate { copy(attachments = attachments - file, isDirty = true) }
    }

    fun clearAttachments() {
        mutate { copy(attachments = emptyList(), isDirty = true) }
    }

    // ── Draft management ──────────────────────────────────────────────────────

    fun saveDraft() {
        draftStore.save(_state.value)
    }

    fun clearDraft() {
        draftStore.clear()
        _state.value = TabletEmailComposeState()
    }

    val hasSavedDraft: Boolean get() = draftStore.hasDraft

    // ── Send ──────────────────────────────────────────────────────────────────

    /**
     * Build and return the send Intent.
     *
     * If attachments are present uses ACTION_SEND (supports multiple files
     * via ACTION_SEND_MULTIPLE).  Without attachments uses ACTION_SENDTO
     * with a mailto: URI which is more precise (only email apps respond).
     *
     * Returns null if the compose state has no recipient.
     */
    fun buildSendIntent(): Intent? {
        val s = _state.value
        if (!s.hasRecipient) return null

        return if (s.hasAttachments) {
            buildSendWithAttachmentsIntent(s)
        } else {
            buildMailtoIntent(s)
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    private fun mutate(block: TabletEmailComposeState.() -> TabletEmailComposeState) {
        _state.update { it.block() }
        // Debounce-save: auto-persist draft on every mutation.
        viewModelScope.launch { draftStore.save(_state.value) }
    }

    private fun buildMailtoIntent(s: TabletEmailComposeState): Intent {
        val uri = Uri.Builder()
            .scheme("mailto")
            .path(s.to.trim())
            .appendQueryParameter("subject", s.subject)
            .appendQueryParameter("body", s.body)
            .also { b ->
                if (s.cc.isNotBlank()) b.appendQueryParameter("cc", s.cc)
                if (s.bcc.isNotBlank()) b.appendQueryParameter("bcc", s.bcc)
            }
            .build()
        return Intent(Intent.ACTION_SENDTO, uri)
    }

    private fun buildSendWithAttachmentsIntent(s: TabletEmailComposeState): Intent {
        val base = Intent(
            if (s.attachments.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE
        ).apply {
            type = if (s.attachments.size == 1) s.attachments[0].mimeType else "*/*"
            putExtra(Intent.EXTRA_EMAIL,   arrayOf(s.to.trim()))
            putExtra(Intent.EXTRA_SUBJECT, s.subject)
            putExtra(Intent.EXTRA_TEXT,    s.body)
            if (s.cc.isNotBlank())  putExtra(Intent.EXTRA_CC,  arrayOf(s.cc.trim()))
            if (s.bcc.isNotBlank()) putExtra(Intent.EXTRA_BCC, arrayOf(s.bcc.trim()))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        if (s.attachments.size == 1) {
            base.putExtra(Intent.EXTRA_STREAM, s.attachments[0].uri)
        } else {
            base.putParcelableArrayListExtra(
                Intent.EXTRA_STREAM,
                ArrayList(s.attachments.map { it.uri })
            )
        }
        return Intent.createChooser(base, "Send email")
    }

    override fun onCleared() {
        super.onCleared()
        draftStore.save(_state.value)
    }
}
