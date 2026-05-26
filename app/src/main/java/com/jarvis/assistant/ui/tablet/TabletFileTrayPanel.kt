package com.jarvis.assistant.ui.tablet

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.DateFormat
import java.util.Date

// ── Palette ───────────────────────────────────────────────────────────────────
private val PanelBg    = Color(0xFF060B14)   // deepest navy
private val RowBg      = Color(0xFF0B1628)   // row surface
private val SelBg      = Color(0xFF0A221A)   // selected row — green tint
private val SelBorder  = Color(0xFF00E676)   // selection border
private val TextPri    = Color(0xFFCCE0F0)   // blue-tinted body text
private val TextMuted  = Color(0xFF7A8FAA)   // blue-grey secondary labels
private val CyanHigh   = Color(0xFF3FA7FF)   // blueprint blue
private val GreenOk    = Color(0xFF00E676)   // status green
private val AmberHint  = Color(0xFFFFAB40)   // status amber
private val BorderC    = Color(0xFF0E1C33)   // divider

/**
 * TabletFileTrayPanel — file browser with active file context.
 *
 * Selecting a file persists it to [TabletFileContextStore] so the email
 * compose panel and voice commands can reference it.  A selected-file card
 * shows at the top with one-tap action buttons (open, share, email, WhatsApp,
 * copy URI).
 */
@Composable
internal fun TabletFileTrayPanel(vm: TabletViewModel) {
    val context      = LocalContext.current
    val files        by vm.files.collectAsState()
    val selectedFile by vm.selectedFile.collectAsState()

    LaunchedEffect(Unit) { vm.loadRecentFiles() }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(PanelBg),
    ) {
        // ── Header ──────────────────────────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            PanelHeader(label = "FILES", icon = Icons.Filled.Folder)
            TextButton(
                onClick = vm::loadRecentFiles,
                colors  = ButtonDefaults.textButtonColors(contentColor = CyanHigh),
            ) {
                Icon(Icons.Filled.Refresh, contentDescription = "Refresh", modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(4.dp))
                Text("Refresh", fontSize = 11.sp, fontFamily = FontFamily.Monospace)
            }
        }

        // ── Selected file card ───────────────────────────────────────────────
        if (selectedFile != null) {
            SelectedFileCard(
                file    = selectedFile!!,
                context = context,
                onClear = vm::clearSelectedFile,
                onNavigateEmail = { vm.navigate(TabletDestination.Email) },
            )
        }

        HorizontalDivider(color = BorderC)

        // ── File list ────────────────────────────────────────────────────────
        if (files.isEmpty()) {
            Box(
                modifier         = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "No files found. Storage permission may be needed.",
                    color      = TextMuted,
                    fontSize   = 12.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        } else {
            LazyColumn(
                modifier       = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(vertical = 4.dp),
            ) {
                items(files, key = { it.contentUri.toString() }) { file ->
                    FileRow(
                        entry      = file,
                        isSelected = selectedFile?.uri == file.contentUri,
                        onSelect   = {
                            vm.selectFile(
                                TabletSelectedFile(
                                    uri        = file.contentUri,
                                    name       = file.name,
                                    mimeType   = file.mimeType,
                                    sizeBytes  = file.sizeBytes,
                                    modifiedMs = file.modifiedMs,
                                )
                            )
                        },
                        onOpen = {
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(file.contentUri, file.mimeType)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            try { context.startActivity(intent) } catch (_: Exception) {}
                        },
                    )
                }
            }
        }
    }
}

// ── Selected file card ────────────────────────────────────────────────────────

@Composable
private fun SelectedFileCard(
    file            : TabletSelectedFile,
    context         : Context,
    onClear         : () -> Unit,
    onNavigateEmail : () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(SelBg)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // File info row
        Row(
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                imageVector        = iconForMime(file.mimeType),
                contentDescription = null,
                tint               = GreenOk,
                modifier           = Modifier.size(22.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    file.name,
                    color      = TextPri,
                    fontSize   = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                    maxLines   = 1,
                    overflow   = TextOverflow.Ellipsis,
                )
                Text(
                    "${file.sizeLabel}  ·  ${file.mimeType}",
                    color      = TextMuted,
                    fontSize   = 10.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
            // Clear selection
            IconButton(
                onClick  = onClear,
                modifier = Modifier.size(28.dp),
            ) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = "Clear selection",
                    tint               = TextMuted,
                    modifier           = Modifier.size(16.dp),
                )
            }
        }

        // Action row
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier              = Modifier.fillMaxWidth(),
        ) {
            FileActionChip(
                label = "Open",
                icon  = Icons.Filled.OpenInBrowser,
                color = CyanHigh,
                onClick = {
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(file.uri, file.mimeType)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try { context.startActivity(intent) } catch (_: Exception) {}
                },
            )
            FileActionChip(
                label = "Email",
                icon  = Icons.Filled.Email,
                color = AmberHint,
                onClick = {
                    onNavigateEmail()
                    // Auto-attach by selecting this file
                    TabletFileContextStore.select(file)
                },
            )
            FileActionChip(
                label = "Share",
                icon  = Icons.Filled.Share,
                color = GreenOk,
                onClick = {
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        type = file.mimeType
                        putExtra(Intent.EXTRA_STREAM, file.uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    context.startActivity(Intent.createChooser(intent, "Share ${file.name}")
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                },
            )
            FileActionChip(
                label = "WhatsApp",
                icon  = Icons.Filled.Chat,
                color = GreenOk,
                onClick = {
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        `package` = "com.whatsapp"
                        type      = file.mimeType
                        putExtra(Intent.EXTRA_STREAM, file.uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try { context.startActivity(intent) } catch (_: Exception) {
                        // WhatsApp not installed — fall through to generic share
                        val fallback = Intent(Intent.ACTION_SEND).apply {
                            type = file.mimeType
                            putExtra(Intent.EXTRA_STREAM, file.uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        context.startActivity(Intent.createChooser(fallback, "Share")
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                },
            )
            FileActionChip(
                label = "Copy URI",
                icon  = Icons.Filled.ContentCopy,
                color = TextMuted,
                onClick = {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("File URI", file.uri.toString()))
                },
            )
        }

        // Voice hint
        Text(
            "\"Jarvis, email this file to [name]\"  ·  \"Jarvis, share this on WhatsApp\"",
            color      = CyanHigh.copy(alpha = 0.5f),
            fontSize   = 9.sp,
            fontFamily = FontFamily.Monospace,
        )
    }
}

// ── File row ──────────────────────────────────────────────────────────────────

@Composable
private fun FileRow(
    entry      : TabletFileEntry,
    isSelected : Boolean,
    onSelect   : () -> Unit,
    onOpen     : () -> Unit,
) {
    val bg = if (isSelected) SelBg else RowBg

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(bg)
            .clickable(onClick = onSelect)
            .padding(horizontal = 20.dp, vertical = 11.dp),
        verticalAlignment     = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(
            imageVector        = iconForMime(entry.mimeType),
            contentDescription = null,
            tint               = if (isSelected) GreenOk else CyanHigh.copy(alpha = 0.6f),
            modifier           = Modifier.size(22.dp),
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                entry.name,
                color      = if (isSelected) TextPri else TextPri.copy(alpha = 0.85f),
                fontSize   = 13.sp,
                fontFamily = FontFamily.Monospace,
                maxLines   = 1,
                overflow   = TextOverflow.Ellipsis,
            )
            Text(
                buildString {
                    append(formatSize(entry.sizeBytes))
                    append("  ·  ")
                    append(
                        DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
                            .format(Date(entry.modifiedMs))
                    )
                },
                color      = TextMuted,
                fontSize   = 10.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
        if (isSelected) {
            Icon(
                Icons.Filled.CheckCircle,
                contentDescription = "Selected",
                tint               = GreenOk,
                modifier           = Modifier.size(18.dp),
            )
        }
        // Tap-to-open icon
        IconButton(
            onClick  = onOpen,
            modifier = Modifier.size(28.dp),
        ) {
            Icon(
                Icons.Filled.Launch,
                contentDescription = "Open",
                tint               = TextMuted,
                modifier           = Modifier.size(16.dp),
            )
        }
    }
    HorizontalDivider(color = BorderC, modifier = Modifier.padding(horizontal = 16.dp))
}

// ── Small action chip ─────────────────────────────────────────────────────────

@Composable
private fun FileActionChip(
    label   : String,
    icon    : ImageVector,
    color   : Color,
    onClick : () -> Unit,
) {
    OutlinedButton(
        onClick         = onClick,
        shape           = RoundedCornerShape(6.dp),
        colors          = ButtonDefaults.outlinedButtonColors(contentColor = color),
        border          = androidx.compose.foundation.BorderStroke(1.dp, color.copy(alpha = 0.4f)),
        contentPadding  = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
        modifier        = Modifier.height(32.dp),
    ) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(3.dp))
        Text(label, fontSize = 9.sp, fontFamily = FontFamily.Monospace)
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

private fun iconForMime(mime: String): ImageVector = when {
    mime.startsWith("image/")  -> Icons.Filled.Image
    mime.startsWith("video/")  -> Icons.Filled.PlayCircle
    mime.startsWith("audio/")  -> Icons.Filled.MusicNote
    mime == "application/pdf"  -> Icons.Filled.PictureAsPdf
    mime.startsWith("text/")   -> Icons.Filled.Article
    mime.contains("document")
        || mime.contains("word")   -> Icons.Filled.Description
    mime.contains("spreadsheet")
        || mime.contains("excel")  -> Icons.Filled.TableChart
    mime.contains("zip")
        || mime.contains("archive")-> Icons.Filled.Inventory2
    else                           -> Icons.Filled.InsertDriveFile
}

private fun formatSize(bytes: Long): String = when {
    bytes < 1_024L         -> "${bytes} B"
    bytes < 1_048_576L     -> "${"%.1f".format(bytes / 1_024.0)} KB"
    bytes < 1_073_741_824L -> "${"%.1f".format(bytes / 1_048_576.0)} MB"
    else                   -> "${"%.2f".format(bytes / 1_073_741_824.0)} GB"
}
