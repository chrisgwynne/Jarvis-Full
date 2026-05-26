package com.jarvis.assistant.logging

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

// MARK: - ViewModel

class ReplyReviewViewModel : ViewModel() {

    private val _entries = MutableStateFlow<List<ReplyLogEntry>>(emptyList())
    val entries = _entries.asStateFlow()

    private val _query = MutableStateFlow("")
    val query = _query.asStateFlow()

    private val _filterSource = MutableStateFlow<ReplySource?>(null)
    val filterSource = _filterSource.asStateFlow()

    private val _exportMessage = MutableStateFlow<String?>(null)
    val exportMessage = _exportMessage.asStateFlow()

    val filteredEntries: List<ReplyLogEntry>
        get() {
            val q = _query.value.lowercase()
            val src = _filterSource.value
            return _entries.value.reversed().filter { e ->
                (q.isEmpty() || e.spokenText.lowercase().contains(q) || e.phraseKey?.lowercase()?.contains(q) == true) &&
                (src == null || e.source == src.key)
            }
        }

    fun load() {
        viewModelScope.launch {
            val all = JarvisReplyLogger.get().allEntries()
            _entries.value = all
        }
    }

    fun setQuery(q: String) { _query.value = q }
    fun setSourceFilter(src: ReplySource?) { _filterSource.value = src }

    fun updateCorrection(id: String, correctedText: String, accepted: Boolean) {
        JarvisReplyLogger.get().updateCorrection(id, correctedText, accepted)
        // Optimistic update in-memory
        _entries.value = _entries.value.map { e ->
            if (e.id == id) e.copy(correctedText = correctedText, accepted = accepted) else e
        }
    }

    fun exportJSONL(context: Context) {
        viewModelScope.launch {
            val jsonl = JarvisReplyLogger.get().exportJSONL()
            shareText(context, jsonl, "reply_log.jsonl", "application/jsonl")
            _exportMessage.value = "JSONL exported."
        }
    }

    fun exportCSV(context: Context) {
        viewModelScope.launch {
            val csv = JarvisReplyLogger.get().exportCSV()
            shareText(context, csv, "reply_log.csv", "text/csv")
            _exportMessage.value = "CSV exported."
        }
    }

    fun clearExportMessage() { _exportMessage.value = null }

    private fun shareText(context: Context, content: String, filename: String, mimeType: String) {
        val dir = File(context.cacheDir, "exports").also { it.mkdirs() }
        val file = File(dir, filename).also { it.writeText(content) }
        val uri: Uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, "Export $filename"))
    }
}

// MARK: - Screen

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReplyReviewScreen(
    viewModel: ReplyReviewViewModel,
    onNavigateUp: () -> Unit,
) {
    val context = LocalContext.current
    val entries by viewModel.entries.collectAsState()
    val query by viewModel.query.collectAsState()
    val filterSource by viewModel.filterSource.collectAsState()
    val exportMessage by viewModel.exportMessage.collectAsState()

    LaunchedEffect(Unit) { viewModel.load() }

    val filtered = viewModel.filteredEntries

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Reply Review") },
                navigationIcon = {
                    IconButton(onClick = onNavigateUp) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    var showExportMenu by remember { mutableStateOf(false) }
                    IconButton(onClick = { showExportMenu = true }) {
                        Icon(Icons.Default.Share, contentDescription = "Export")
                    }
                    DropdownMenu(expanded = showExportMenu, onDismissRequest = { showExportMenu = false }) {
                        DropdownMenuItem(
                            text = { Text("Export JSONL") },
                            onClick = { viewModel.exportJSONL(context); showExportMenu = false }
                        )
                        DropdownMenuItem(
                            text = { Text("Export CSV") },
                            onClick = { viewModel.exportCSV(context); showExportMenu = false }
                        )
                    }
                }
            )
        },
        snackbarHost = {
            exportMessage?.let { msg ->
                LaunchedEffect(msg) {
                    kotlinx.coroutines.delay(2000)
                    viewModel.clearExportMessage()
                }
                Snackbar { Text(msg) }
            }
        }
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {

            // Search bar
            OutlinedTextField(
                value = query,
                onValueChange = viewModel::setQuery,
                placeholder = { Text("Search replies…") },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                trailingIcon = {
                    if (query.isNotEmpty()) {
                        IconButton(onClick = { viewModel.setQuery("") }) {
                            Icon(Icons.Default.Clear, contentDescription = "Clear")
                        }
                    }
                },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = {})
            )

            // Source filter chips
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                FilterChip(
                    selected = filterSource == null,
                    onClick = { viewModel.setSourceFilter(null) },
                    label = { Text("All") },
                )
                ReplySource.entries.take(5).forEach { src ->
                    FilterChip(
                        selected = filterSource == src,
                        onClick = { viewModel.setSourceFilter(if (filterSource == src) null else src) },
                        label = { Text(src.key.replaceFirstChar { it.uppercase() }) },
                    )
                }
            }

            // Stats row
            Text(
                text = "${filtered.size} of ${entries.size} replies",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.outline,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp)
            )

            Divider()

            // Entry list
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(filtered, key = { it.id }) { entry ->
                    ReplyEntryCard(entry = entry, onCorrect = { corrected, accepted ->
                        viewModel.updateCorrection(entry.id, corrected, accepted)
                    })
                    Divider(thickness = 0.5.dp)
                }
            }
        }
    }
}

// MARK: - Entry card

private val timeFormatter = DateTimeFormatter.ofPattern("HH:mm:ss")
    .withZone(ZoneId.systemDefault())

@Composable
private fun ReplyEntryCard(
    entry: ReplyLogEntry,
    onCorrect: (correctedText: String, accepted: Boolean) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    var editMode by remember { mutableStateOf(false) }
    var editText by remember(entry.id) { mutableStateOf(entry.correctedText ?: entry.spokenText) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { expanded = !expanded }
            .padding(horizontal = 16.dp, vertical = 10.dp)
    ) {
        // Header row
        Row(verticalAlignment = Alignment.CenterVertically) {
            SourceBadge(source = entry.source)
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = timeFormatter.format(Instant.ofEpochMilli(entry.timestampMs)),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.outline,
            )
            Spacer(modifier = Modifier.weight(1f))
            entry.accepted?.let { accepted ->
                Icon(
                    imageVector = if (accepted) Icons.Default.ThumbUp else Icons.Default.ThumbDown,
                    contentDescription = null,
                    tint = if (accepted) Color(0xFF4CAF50) else Color(0xFFE53935),
                    modifier = Modifier.size(14.dp)
                )
            }
        }

        Spacer(modifier = Modifier.height(4.dp))

        // Spoken text
        Text(
            text = entry.correctedText ?: entry.spokenText,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = if (expanded) Int.MAX_VALUE else 2,
            overflow = TextOverflow.Ellipsis,
        )

        if (entry.correctedText != null) {
            Text(
                text = "Original: ${entry.spokenText}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        // Expanded detail
        if (expanded) {
            Spacer(modifier = Modifier.height(6.dp))
            entry.phraseKey?.let {
                Text(
                    text = "Key: $it",
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.tertiary,
                )
            }
            entry.intent?.let {
                Text(
                    text = "Intent: $it",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.outline,
                )
            }

            if (!editMode) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { editMode = true }) { Text("Edit") }
                    TextButton(onClick = { onCorrect(entry.spokenText, true) }) { Text("Accept") }
                    TextButton(onClick = { onCorrect(entry.spokenText, false) }) { Text("Reject") }
                }
            } else {
                OutlinedTextField(
                    value = editText,
                    onValueChange = { editText = it },
                    label = { Text("Corrected reply") },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 2,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = {
                        onCorrect(editText, true)
                        editMode = false
                    }) { Text("Save") }
                    TextButton(onClick = { editMode = false }) { Text("Cancel") }
                }
            }
        }
    }
}

@Composable
private fun SourceBadge(source: String) {
    val (bg, label) = when (source) {
        ReplySource.COMMAND.key  -> Color(0xFF1565C0) to "CMD"
        ReplySource.TEMPLATE.key -> Color(0xFF2E7D32) to "TPL"
        ReplySource.LLM.key      -> Color(0xFF6A1B9A) to "LLM"
        ReplySource.TOOL.key     -> Color(0xFF00695C) to "TOOL"
        ReplySource.PROACTIVE.key-> Color(0xFFE65100) to "PRO"
        ReplySource.ERROR.key    -> Color(0xFFC62828) to "ERR"
        ReplySource.WAKE.key     -> Color(0xFF37474F) to "WAKE"
        else                     -> Color(0xFF424242) to "SYS"
    }
    Text(
        text = label,
        fontSize = 9.sp,
        color = Color.White,
        modifier = Modifier
            .background(bg, RoundedCornerShape(3.dp))
            .padding(horizontal = 4.dp, vertical = 1.dp)
    )
}
