package com.jarvis.assistant.phrases.ui

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.jarvis.assistant.phrases.PhraseCategory
import com.jarvis.assistant.phrases.PhraseEntry
import com.jarvis.assistant.phrases.PhraseVariant
import kotlinx.coroutines.launch
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PhrasesSettingsScreen(
    viewModel: PhrasesSettingsViewModel = viewModel(),
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val scope   = rememberCoroutineScope()
    val state   by viewModel.uiState.collectAsStateWithLifecycle()

    // One-shot event consumption
    LaunchedEffect(Unit) {
        viewModel.events.collect { event ->
            when (event) {
                is PhrasesEvent.TestSpeak  -> {
                    Toast.makeText(context, "Speaking: ${event.text}", Toast.LENGTH_SHORT).show()
                    // Integrate with TtsEngine here if accessible via DI/singleton
                }
                is PhrasesEvent.ExportReady -> {
                    val shareIntent = Intent(Intent.ACTION_SEND).apply {
                        type    = "application/json"
                        putExtra(Intent.EXTRA_TEXT, event.json)
                        putExtra(Intent.EXTRA_SUBJECT, "Jarvis Phrase Pack")
                    }
                    context.startActivity(Intent.createChooser(shareIntent, "Export phrases"))
                }
                is PhrasesEvent.ShowToast  -> {
                    Toast.makeText(context, event.message, Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    // File picker for JSON import
    val importLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        try {
            val json = context.contentResolver.openInputStream(uri)
                ?.bufferedReader()
                ?.readText()
                ?: return@rememberLauncherForActivityResult
            viewModel.importJson(json)
        } catch (e: Exception) {
            Toast.makeText(context, "Failed to read file: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    // Sheet state
    var sheetEntry by remember { mutableStateOf<PhraseEntry?>(null) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text       = "Voice & Phrases",
                        fontWeight = FontWeight.SemiBold,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector        = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { importLauncher.launch(arrayOf("application/json", "*/*")) }) {
                        Icon(
                            imageVector        = Icons.Default.Add,
                            contentDescription = "Import phrases",
                        )
                    }
                    IconButton(onClick = { viewModel.exportJson() }) {
                        Icon(
                            imageVector        = Icons.Default.Share,
                            contentDescription = "Export phrases",
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            // ── Search bar ────────────────────────────────────────────────────
            OutlinedTextField(
                value         = state.searchQuery,
                onValueChange = viewModel::setSearch,
                placeholder   = { Text("Search phrases…") },
                singleLine    = true,
                trailingIcon  = {
                    if (state.searchQuery.isNotEmpty()) {
                        IconButton(onClick = { viewModel.setSearch("") }) {
                            Icon(Icons.Default.Clear, contentDescription = "Clear search")
                        }
                    }
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            )

            // ── Category chips ────────────────────────────────────────────────
            LazyRow(
                contentPadding    = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier          = Modifier.fillMaxWidth(),
            ) {
                item {
                    FilterChip(
                        selected = state.selectedCategory == null,
                        onClick  = { viewModel.setCategory(null) },
                        label    = { Text("All") },
                    )
                }
                items(PhraseCategory.values()) { cat ->
                    FilterChip(
                        selected = state.selectedCategory == cat,
                        onClick  = {
                            viewModel.setCategory(if (state.selectedCategory == cat) null else cat)
                        },
                        label = { Text(cat.displayName) },
                    )
                }
            }

            Spacer(Modifier.height(8.dp))

            // ── Main list ─────────────────────────────────────────────────────
            when {
                state.isLoading -> {
                    Box(
                        modifier          = Modifier.fillMaxSize(),
                        contentAlignment  = Alignment.Center,
                    ) {
                        CircularProgressIndicator()
                    }
                }

                state.phrases.isEmpty() -> {
                    Box(
                        modifier          = Modifier.fillMaxSize(),
                        contentAlignment  = Alignment.Center,
                    ) {
                        Text(
                            text  = "No phrases match your search",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }

                else -> {
                    val grouped = state.phrases.groupBy { it.category }

                    LazyColumn(
                        contentPadding = PaddingValues(bottom = 24.dp),
                        modifier       = Modifier.fillMaxSize(),
                    ) {
                        grouped.forEach { (category, entries) ->
                            item(key = "header_${category.name}") {
                                CategoryHeader(category)
                            }
                            items(entries, key = { it.key }) { entry ->
                                PhraseCard(
                                    entry       = entry,
                                    resolvedText = resolvePreview(entry),
                                    onEdit      = { sheetEntry = entry },
                                    onTestSpeak = { viewModel.testSpeak(entry.key) },
                                )
                                HorizontalDivider(
                                    modifier  = Modifier.padding(horizontal = 16.dp),
                                    thickness = 0.5.dp,
                                    color     = MaterialTheme.colorScheme.outlineVariant,
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Editor bottom sheet ───────────────────────────────────────────────────
    sheetEntry?.let { entry ->
        ModalBottomSheet(
            onDismissRequest = { sheetEntry = null },
            sheetState       = sheetState,
            dragHandle       = { BottomSheetDefaults.DragHandle() },
        ) {
            PhraseEditorSheet(
                entry         = entry,
                onSaveVariant = { variant ->
                    viewModel.saveVariant(entry.key, variant)
                },
                onDeleteVariant = { variantId ->
                    viewModel.deleteVariant(entry.key, variantId)
                },
                onReset       = {
                    viewModel.resetKey(entry.key)
                    scope.launch { sheetState.hide() }.invokeOnCompletion { sheetEntry = null }
                },
                onTestSpeak   = { key -> viewModel.testSpeak(key) },
                onClose       = {
                    scope.launch { sheetState.hide() }.invokeOnCompletion { sheetEntry = null }
                },
            )
        }
    }
}

// ── Category section header ───────────────────────────────────────────────────

@Composable
private fun CategoryHeader(category: PhraseCategory) {
    Text(
        text     = category.displayName.uppercase(),
        style    = MaterialTheme.typography.labelSmall,
        color    = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 4.dp),
    )
}

// ── Phrase card row ───────────────────────────────────────────────────────────

@Composable
private fun PhraseCard(
    entry:        PhraseEntry,
    resolvedText: String,
    onEdit:       () -> Unit,
    onTestSpeak:  () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onEdit)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment    = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text       = entry.key,
                style      = MaterialTheme.typography.labelMedium,
                color      = MaterialTheme.colorScheme.onSurfaceVariant,
                fontFamily = FontFamily.Monospace,
                fontSize   = 11.sp,
                maxLines   = 1,
                overflow   = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text     = resolvedText.ifBlank { "(empty)" },
                style    = MaterialTheme.typography.bodyMedium,
                color    = if (resolvedText.isBlank())
                               MaterialTheme.colorScheme.onSurfaceVariant
                           else
                               MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (entry.variants.isNotEmpty()) {
                val enabledCount = entry.variants.count { it.isEnabled }
                Spacer(Modifier.height(2.dp))
                Text(
                    text  = "$enabledCount custom variant${if (enabledCount != 1) "s" else ""}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            if (resolvedText.isNotBlank()) {
                IconButton(onClick = onTestSpeak) {
                    Icon(
                        imageVector        = Icons.Default.PlayArrow,
                        contentDescription = "Test speak",
                        tint               = MaterialTheme.colorScheme.primary,
                        modifier           = Modifier.size(20.dp),
                    )
                }
            }
            IconButton(onClick = onEdit) {
                Icon(
                    imageVector        = Icons.Default.Edit,
                    contentDescription = "Edit phrase",
                    tint               = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier           = Modifier.size(20.dp),
                )
            }
        }
    }
}

// ── Phrase editor sheet ───────────────────────────────────────────────────────

@Composable
private fun PhraseEditorSheet(
    entry:           PhraseEntry,
    onSaveVariant:   (PhraseVariant) -> Unit,
    onDeleteVariant: (variantId: String) -> Unit,
    onReset:         () -> Unit,
    onTestSpeak:     (key: String) -> Unit,
    onClose:         () -> Unit,
) {
    var showAddField     by rememberSaveable { mutableStateOf(false) }
    var newVariantText   by rememberSaveable { mutableStateOf("") }
    var showResetConfirm by rememberSaveable { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .padding(bottom = 32.dp),
    ) {
        // Sheet title
        Row(
            modifier             = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment    = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text       = entry.key,
                    style      = MaterialTheme.typography.labelSmall,
                    color      = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontFamily = FontFamily.Monospace,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    text       = entry.category.displayName,
                    style      = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            IconButton(onClick = onClose) {
                Icon(Icons.Default.Clear, contentDescription = "Close")
            }
        }

        // Description
        if (entry.description.isNotBlank()) {
            Spacer(Modifier.height(8.dp))
            Text(
                text  = entry.description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // Available variables
        if (entry.availableVars.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                entry.availableVars.forEach { varName ->
                    Box(
                        modifier = Modifier
                            .background(
                                MaterialTheme.colorScheme.secondaryContainer,
                                RoundedCornerShape(4.dp),
                            )
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    ) {
                        Text(
                            text       = "{$varName}",
                            style      = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                            color      = MaterialTheme.colorScheme.onSecondaryContainer,
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))
        HorizontalDivider()
        Spacer(Modifier.height(12.dp))

        // Default text
        Text(
            text       = "Default",
            style      = MaterialTheme.typography.labelMedium,
            color      = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text  = entry.defaultText.ifBlank { "(empty)" },
            style = MaterialTheme.typography.bodyMedium,
            color = if (entry.defaultText.isBlank())
                        MaterialTheme.colorScheme.onSurfaceVariant
                    else
                        MaterialTheme.colorScheme.onSurface,
        )

        // User variants
        if (entry.variants.isNotEmpty()) {
            Spacer(Modifier.height(16.dp))
            Text(
                text       = "Your variants",
                style      = MaterialTheme.typography.labelMedium,
                color      = MaterialTheme.colorScheme.onSurfaceVariant,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.height(8.dp))

            entry.variants.forEach { variant ->
                VariantRow(
                    variant         = variant,
                    onToggleEnabled = {
                        onSaveVariant(variant.copy(isEnabled = !variant.isEnabled))
                    },
                    onDelete        = { onDeleteVariant(variant.id) },
                    onTestSpeak     = {
                        // speak the variant text directly via a temporary entry
                        onSaveVariant(variant) // ensure saved, then test-speak will pick it up
                        onTestSpeak(entry.key)
                    },
                )
                Spacer(Modifier.height(4.dp))
            }
        }

        Spacer(Modifier.height(12.dp))

        // Add variant inline editor
        if (showAddField) {
            OutlinedTextField(
                value         = newVariantText,
                onValueChange = { newVariantText = it },
                label         = { Text("New variant text") },
                singleLine    = false,
                maxLines      = 4,
                modifier      = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick  = {
                        if (newVariantText.isNotBlank()) {
                            onSaveVariant(
                                PhraseVariant(
                                    id          = UUID.randomUUID().toString(),
                                    text        = newVariantText.trim(),
                                    isEnabled   = true,
                                    isDefault   = false,
                                    updatedAtMs = System.currentTimeMillis(),
                                )
                            )
                            newVariantText = ""
                            showAddField   = false
                        }
                    },
                    enabled  = newVariantText.isNotBlank(),
                ) {
                    Text("Save")
                }
                TextButton(onClick = {
                    showAddField   = false
                    newVariantText = ""
                }) {
                    Text("Cancel")
                }
            }
        } else {
            FilledTonalButton(
                onClick  = { showAddField = true },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.Add, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Add variant")
            }
        }

        Spacer(Modifier.height(8.dp))

        // Action row: test speak + reset
        Row(
            modifier              = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilledTonalButton(
                onClick  = { onTestSpeak(entry.key) },
                modifier = Modifier.weight(1f),
                colors   = ButtonDefaults.filledTonalButtonColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                ),
            ) {
                Icon(Icons.Default.PlayArrow, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Test speak")
            }

            if (entry.variants.isNotEmpty()) {
                if (showResetConfirm) {
                    Button(
                        onClick = {
                            onReset()
                            showResetConfirm = false
                        },
                        colors  = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error,
                        ),
                        modifier = Modifier.weight(1f),
                    ) {
                        Text("Confirm reset")
                    }
                } else {
                    FilledTonalButton(
                        onClick  = { showResetConfirm = true },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Default.Refresh, contentDescription = null)
                        Spacer(Modifier.width(6.dp))
                        Text("Reset to default")
                    }
                }
            }
        }

        Spacer(Modifier.height(8.dp))
    }
}

// ── Variant row ───────────────────────────────────────────────────────────────

@Composable
private fun VariantRow(
    variant:         PhraseVariant,
    onToggleEnabled: () -> Unit,
    onDelete:        () -> Unit,
    onTestSpeak:     () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                RoundedCornerShape(8.dp),
            )
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment    = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text     = variant.text.ifBlank { "(empty)" },
            style    = MaterialTheme.typography.bodySmall,
            color    = if (variant.isEnabled)
                           MaterialTheme.colorScheme.onSurface
                       else
                           MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )

        Row(verticalAlignment = Alignment.CenterVertically) {
            if (variant.text.isNotBlank()) {
                IconButton(
                    onClick  = onTestSpeak,
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(
                        imageVector        = Icons.Default.PlayArrow,
                        contentDescription = "Test speak variant",
                        modifier           = Modifier.size(16.dp),
                        tint               = MaterialTheme.colorScheme.primary,
                    )
                }
            }
            Switch(
                checked         = variant.isEnabled,
                onCheckedChange = { onToggleEnabled() },
                modifier        = Modifier.size(36.dp, 24.dp),
            )
            Spacer(Modifier.width(4.dp))
            IconButton(
                onClick  = onDelete,
                modifier = Modifier.size(36.dp),
            ) {
                Icon(
                    imageVector        = Icons.Default.Delete,
                    contentDescription = "Delete variant",
                    modifier           = Modifier.size(16.dp),
                    tint               = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

// ── Helper: resolve preview text from entry without a full PhraseResolver ────

private fun resolvePreview(entry: PhraseEntry): String {
    val enabledVariant = entry.variants.firstOrNull { it.isEnabled }
    return enabledVariant?.text ?: entry.defaultText
}
