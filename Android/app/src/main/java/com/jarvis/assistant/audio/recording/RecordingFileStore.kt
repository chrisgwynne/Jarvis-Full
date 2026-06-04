package com.jarvis.assistant.audio.recording

import android.content.Context
import java.io.File

/**
 * Manages app-owned audio recording files under getExternalFilesDir("Recordings").
 * Falls back to filesDir/recordings if external storage is unavailable.
 *
 * NO WRITE_EXTERNAL_STORAGE permission required — app-specific directories
 * are fully accessible without storage permission on all API levels.
 */
object RecordingFileStore {

    private const val DIR_NAME = "Recordings"

    /** Creates a new uniquely named M4A file ready for MediaRecorder output. */
    fun createRecordingFile(context: Context): File {
        val dir = storageDir(context)
        return File(dir, "jarvis_rec_${System.currentTimeMillis()}.m4a")
    }

    /**
     * Returns the most recently modified non-empty recording file,
     * or null if no recordings exist.
     */
    fun getLatestRecording(context: Context): File? =
        storageDir(context)
            .listFiles { f -> f.isFile && f.name.startsWith("jarvis_rec_") && f.length() > 0L }
            ?.maxByOrNull { it.lastModified() }

    /**
     * #30: delete recordings older than [maxAgeMs] (default 7 days). Called on
     * each new recording so audio never accumulates indefinitely. Returns the
     * number of files deleted.
     */
    fun pruneOlderThan(context: Context, maxAgeMs: Long = DEFAULT_RETENTION_MS): Int {
        val cutoff = System.currentTimeMillis() - maxAgeMs
        val files = storageDir(context)
            .listFiles { f -> f.isFile && f.name.startsWith("jarvis_rec_") }
            ?: return 0
        var deleted = 0
        for (f in files) {
            if (f.lastModified() < cutoff && f.delete()) deleted++
        }
        return deleted
    }

    /** #30: delete every recording (used by the app-wide data reset). */
    fun clearAll(context: Context): Int {
        val files = storageDir(context)
            .listFiles { f -> f.isFile && f.name.startsWith("jarvis_rec_") }
            ?: return 0
        var deleted = 0
        for (f in files) if (f.delete()) deleted++
        return deleted
    }

    private fun storageDir(context: Context): File {
        val dir = File(context.filesDir, DIR_NAME)
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    /** 7-day default retention for on-device recordings. */
    private const val DEFAULT_RETENTION_MS = 7L * 24 * 60 * 60 * 1000
}
