package com.jarvis.assistant.ui.tablet

import android.net.Uri
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

// ── Data class ────────────────────────────────────────────────────────────────

/**
 * Represents a file the user has selected in the tablet file tray.
 * Uses a content URI so it is safe across different storage backends (SAF,
 * MediaStore) without making raw-filesystem assumptions.
 */
data class TabletSelectedFile(
    val uri       : Uri,
    val name      : String,
    val mimeType  : String,
    val sizeBytes : Long,
    val modifiedMs: Long,
) {
    val isImage   : Boolean get() = mimeType.startsWith("image/")
    val isVideo   : Boolean get() = mimeType.startsWith("video/")
    val isAudio   : Boolean get() = mimeType.startsWith("audio/")
    val isPdf     : Boolean get() = mimeType == "application/pdf"
    val isDocument: Boolean get() = mimeType.startsWith("text/") || isPdf ||
        mimeType.contains("document") || mimeType.contains("spreadsheet")

    /** Human-readable size string. */
    val sizeLabel: String get() = when {
        sizeBytes < 1_024L         -> "${sizeBytes} B"
        sizeBytes < 1_048_576L     -> "${"%.1f".format(sizeBytes / 1_024.0)} KB"
        sizeBytes < 1_073_741_824L -> "${"%.1f".format(sizeBytes / 1_048_576.0)} MB"
        else                       -> "${"%.2f".format(sizeBytes / 1_073_741_824.0)} GB"
    }
}

// ── Process-wide singleton store ──────────────────────────────────────────────

/**
 * TabletFileContextStore — process-wide singleton tracking the file the user
 * has actively selected in the tablet file tray.
 *
 * Exposed as a [StateFlow] so any panel (email compose, action planner,
 * assistant sidebar) can observe the selection reactively.  Only the tablet
 * shell reads or writes this store — the phone shell never references it.
 */
object TabletFileContextStore {

    private val _selected = MutableStateFlow<TabletSelectedFile?>(null)

    /** Currently selected file, or null if nothing is selected. */
    val selectedFile: StateFlow<TabletSelectedFile?> = _selected.asStateFlow()

    /** Synchronous snapshot — safe to read from any thread. */
    val current: TabletSelectedFile? get() = _selected.value

    /** Mark [file] as the active context file. */
    fun select(file: TabletSelectedFile) { _selected.value = file }

    /** Deselect and clear the active file context. */
    fun clear() { _selected.value = null }

    /** True when a file is currently selected. */
    val hasSelection: Boolean get() = _selected.value != null
}
