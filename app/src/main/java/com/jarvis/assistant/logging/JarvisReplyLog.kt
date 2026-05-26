package com.jarvis.assistant.logging

import android.content.Context
import com.google.gson.Gson
import com.google.gson.JsonSyntaxException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.util.UUID

// MARK: - Reply source

enum class ReplySource(val key: String) {
    COMMAND("command"),       // routed command response (PhraseRegistry)
    TEMPLATE("template"),     // explicit PhraseKey lookup
    LLM("llm"),               // LLM-generated response
    TOOL("tool"),             // tool execution result
    PROACTIVE("proactive"),   // unsolicited nudge or suggestion
    ERROR("error"),           // error / failure path
    WAKE("wake"),             // wake word acknowledgement
    SYSTEM("system");         // internal system message (not user-editable)

    companion object {
        fun fromKey(key: String): ReplySource = entries.firstOrNull { it.key == key } ?: SYSTEM
    }
}

// MARK: - Log entry

data class ReplyLogEntry(
    val id: String = UUID.randomUUID().toString(),
    val timestampMs: Long = Instant.now().toEpochMilli(),
    val source: String,
    val intent: String? = null,
    val phraseKey: String? = null,
    val spokenText: String,
    val device: String = "android",
    val editableFlag: Boolean = true,
    val correctedText: String? = null,
    val accepted: Boolean? = null,
)

// MARK: - Logger

/**
 * Appends every spoken reply to a bounded JSONL file at
 * [context.filesDir]/jarvis/reply_log.jsonl.
 *
 * Thread-safe: all I/O dispatched on [Dispatchers.IO].
 */
class JarvisReplyLogger private constructor(context: Context) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val logFile: File
    private val maxBytes = 4 * 1024 * 1024L   // 4 MB cap
    private val maxEntries = 2_000
    private val gson = Gson()

    private var cache: MutableList<ReplyLogEntry>? = null

    init {
        val dir = File(context.filesDir, "jarvis").also { it.mkdirs() }
        logFile = File(dir, "reply_log.jsonl")
    }

    companion object {
        @Volatile private var instance: JarvisReplyLogger? = null

        fun init(context: Context) {
            instance = JarvisReplyLogger(context.applicationContext)
        }

        fun get(): JarvisReplyLogger =
            instance ?: error("JarvisReplyLogger not initialized — call init() in Application.onCreate()")
    }

    // MARK: Append

    fun append(
        source: ReplySource,
        spokenText: String,
        intent: String? = null,
        phraseKey: String? = null,
        editableFlag: Boolean = true,
    ) {
        if (spokenText.isBlank()) return
        val entry = ReplyLogEntry(
            source      = source.key,
            intent      = intent,
            phraseKey   = phraseKey,
            spokenText  = spokenText,
            editableFlag = editableFlag,
        )
        scope.launch { writeEntry(entry) }
    }

    private fun writeEntry(entry: ReplyLogEntry) {
        val line = gson.toJson(entry) + "\n"
        logFile.appendText(line, Charsets.UTF_8)
        cache?.let {
            it.add(entry)
            if (it.size > maxEntries) repeat(it.size - maxEntries) { _ -> it.removeAt(0) }
        }
        rotateIfNeeded()
    }

    private fun rotateIfNeeded() {
        if (logFile.length() <= maxBytes) return
        val lines = logFile.readLines(Charsets.UTF_8).filter { it.isNotBlank() }
        val keep = lines.drop(lines.size / 2)
        logFile.writeText(keep.joinToString("\n") + "\n", Charsets.UTF_8)
        cache = null  // invalidate
    }

    // MARK: Read

    suspend fun recentEntries(limit: Int = 100): List<ReplyLogEntry> = withContext(Dispatchers.IO) {
        loadCache().takeLast(limit)
    }

    suspend fun allEntries(): List<ReplyLogEntry> = withContext(Dispatchers.IO) {
        loadCache().toList()
    }

    private fun loadCache(): MutableList<ReplyLogEntry> {
        cache?.let { return it }
        val loaded = if (!logFile.exists()) mutableListOf()
        else logFile.readLines(Charsets.UTF_8)
            .filter { it.isNotBlank() }
            .mapNotNull { line ->
                try { gson.fromJson(line, ReplyLogEntry::class.java) } catch (_: JsonSyntaxException) { null }
            }
            .toMutableList()
        if (loaded.size > maxEntries) loaded.subList(0, loaded.size - maxEntries).clear()
        cache = loaded
        return loaded
    }

    // MARK: Edit

    fun updateCorrection(id: String, correctedText: String, accepted: Boolean) {
        scope.launch {
            val entries = loadCache()
            val idx = entries.indexOfFirst { it.id == id }
            if (idx < 0) return@launch
            entries[idx] = entries[idx].copy(correctedText = correctedText, accepted = accepted)
            rewriteFile(entries)
        }
    }

    private fun rewriteFile(entries: List<ReplyLogEntry>) {
        val content = entries.joinToString("\n") { gson.toJson(it) } + "\n"
        logFile.writeText(content, Charsets.UTF_8)
    }

    // MARK: Export

    suspend fun exportJSONL(): String = withContext(Dispatchers.IO) {
        allEntries().joinToString("\n") { gson.toJson(it) }
    }

    suspend fun exportCSV(): String = withContext(Dispatchers.IO) {
        val header = "timestamp,source,intent,phraseKey,spokenText,correctedText,accepted,device,editableFlag"
        val rows = allEntries().map { e ->
            listOf(
                Instant.ofEpochMilli(e.timestampMs).toString(),
                e.source,
                e.intent.orEmpty(),
                e.phraseKey.orEmpty(),
                csvEscape(e.spokenText),
                e.correctedText?.let { csvEscape(it) }.orEmpty(),
                e.accepted?.toString().orEmpty(),
                e.device,
                e.editableFlag.toString(),
            ).joinToString(",")
        }
        (listOf(header) + rows).joinToString("\n")
    }

    private fun csvEscape(s: String) = "\"${s.replace("\"", "\"\"")}\""
}
