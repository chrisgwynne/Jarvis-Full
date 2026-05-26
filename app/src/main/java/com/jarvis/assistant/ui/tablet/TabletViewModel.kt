package com.jarvis.assistant.ui.tablet

import android.app.Application
import android.content.ContentUris
import android.content.Context
import android.provider.MediaStore
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.core.store.DeviceState
import com.jarvis.assistant.core.store.DeviceStateStore
import com.jarvis.assistant.memory.db.JarvisDatabase
import com.jarvis.assistant.memory.db.entity.ConversationTurn
import com.jarvis.assistant.service.JarvisService
import com.jarvis.assistant.session.context.RecentHomeAssistantContext
import com.jarvis.assistant.session.context.RecentMessageContext
import com.jarvis.assistant.tools.device.RecentAppContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

// ── Destinations ──────────────────────────────────────────────────────────────

enum class TabletDestination(val label: String) {
    Assistant("Assistant"),
    Files("Files"),
    Messages("Messages"),
    Email("Email"),
    Apps("Apps"),
    Home("Home"),
    Calendar("Calendar"),
    Settings("Settings"),
    Diagnostics("Diagnostics"),
}

// ── File entry ────────────────────────────────────────────────────────────────

data class TabletFileEntry(
    val name        : String,
    val mimeType    : String,
    val sizeBytes   : Long,
    val modifiedMs  : Long,
    val contentUri  : android.net.Uri,
)

// ── ViewModel ─────────────────────────────────────────────────────────────────

/**
 * TabletViewModel — state model for the tablet shell.
 *
 * Bridges all existing Jarvis singletons (DeviceStateStore, JarvisApp context
 * stores, JarvisService) to the tablet Compose hierarchy.  Contains zero new
 * business logic — UI-binding only.
 */
class TabletViewModel(private val app: Application) : AndroidViewModel(app) {

    // ── Navigation ────────────────────────────────────────────────────────────

    private val _destination = MutableStateFlow(TabletDestination.Assistant)
    val destination: StateFlow<TabletDestination> = _destination.asStateFlow()

    fun navigate(dest: TabletDestination) { _destination.value = dest }

    // ── Device state (singleton) ──────────────────────────────────────────────

    val deviceState: StateFlow<DeviceState> = DeviceStateStore.state

    // ── Conversation turns ────────────────────────────────────────────────────

    private val _turns = MutableStateFlow<List<ConversationTurn>>(emptyList())
    val turns: StateFlow<List<ConversationTurn>> = _turns.asStateFlow()

    private val dao = JarvisDatabase.getInstance(app).conversationDao()

    // ── Context stores (delegated from JarvisApp singletons) ─────────────────

    val messageContext: StateFlow<RecentMessageContext?> =
        JarvisApp.recentMessageContextStore.contextFlow

    val haContext: StateFlow<RecentHomeAssistantContext?> =
        JarvisApp.recentHaContextStore.contextFlow

    val appContext: StateFlow<RecentAppContext?> =
        JarvisApp.recentAppContextStore.contextFlow

    // ── Selected file (process-wide tablet file context) ─────────────────────

    /** The file the user has tapped in the file tray — drives email attach,
     *  share, and voice-file-reference commands. */
    val selectedFile: StateFlow<TabletSelectedFile?> = TabletFileContextStore.selectedFile

    fun selectFile(file: TabletSelectedFile) = TabletFileContextStore.select(file)
    fun clearSelectedFile()                   = TabletFileContextStore.clear()

    // ── Recent files ──────────────────────────────────────────────────────────

    private val _files = MutableStateFlow<List<TabletFileEntry>>(emptyList())
    val files: StateFlow<List<TabletFileEntry>> = _files.asStateFlow()

    fun loadRecentFiles() {
        viewModelScope.launch(Dispatchers.IO) {
            _files.value = queryRecentFiles(app)
        }
    }

    // ── Init ──────────────────────────────────────────────────────────────────

    init {
        // Conversation polling at the same cadence as the phone shell (1.5 s).
        viewModelScope.launch(Dispatchers.IO) {
            while (true) {
                _turns.value = dao.getRecentTurns(60)
                delay(1_500)
            }
        }
        loadRecentFiles()
    }

    // ── Service control ───────────────────────────────────────────────────────

    fun startService()     = JarvisService.start(app)
    fun stopService()      = JarvisService.stop(app)
    fun triggerListen()    = JarvisService.manualTrigger(app)
    fun silenceService()   = JarvisService.silence(app)
    fun isServiceRunning() = JarvisService.isRunning(app)

    // ── Internal helpers ──────────────────────────────────────────────────────

    private fun queryRecentFiles(ctx: Context): List<TabletFileEntry> {
        val results    = mutableListOf<TabletFileEntry>()
        val collection = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
        )
        try {
            ctx.contentResolver.query(
                collection,
                projection,
                "${MediaStore.Files.FileColumns.MIME_TYPE} IS NOT NULL " +
                    "AND ${MediaStore.Files.FileColumns.SIZE} > 0",
                null,
                "${MediaStore.Files.FileColumns.DATE_MODIFIED} DESC",
            )?.use { cursor ->
                val idCol   = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
                val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
                val modCol  = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)
                var count   = 0
                while (cursor.moveToNext() && count < 60) {
                    val name = cursor.getString(nameCol) ?: continue
                    val id   = cursor.getLong(idCol)
                    val mime = cursor.getString(mimeCol) ?: "*/*"
                    val size = cursor.getLong(sizeCol)
                    val mod  = cursor.getLong(modCol) * 1_000L
                    val uri  = ContentUris.withAppendedId(collection, id)
                    results += TabletFileEntry(name, mime, size, mod, uri)
                    count++
                }
            }
        } catch (_: Exception) { /* storage not accessible → return empty */ }
        return results
    }
}
