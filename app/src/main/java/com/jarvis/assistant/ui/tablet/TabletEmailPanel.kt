package com.jarvis.assistant.ui.tablet

import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel

// ── Palette ───────────────────────────────────────────────────────────────────
private val PanelBg    = Color(0xFF060B14)   // deepest navy
private val CardBg     = Color(0xFF0B1628)   // card surface
private val FieldBg    = Color(0xFF11203A)   // input field surface
private val AttachBg   = Color(0xFF0A221A)   // attachment success bg (green tint)
private val TextPri    = Color(0xFFCCE0F0)   // blue-tinted body text
private val TextMuted  = Color(0xFF7A8FAA)   // blue-grey secondary labels
private val CyanHigh   = Color(0xFF3FA7FF)   // blueprint blue
private val AmberHint  = Color(0xFFFFAB40)   // status amber
private val GreenOk    = Color(0xFF00E676)   // status green
private val RedBad     = Color(0xFFFF5252)   // status red
private val BorderC    = Color(0xFF0E1C33)   // divider

/**
 * TabletEmailPanel — full compose surface for the tablet email destination.
 *
 * Features:
 *  - To / CC / BCC / Subject / Body fields
 *  - Attachments from [TabletFileContextStore]
 *  - Draft auto-save (via [TabletEmailComposeViewModel])
 *  - Send via Android email intent (ACTION_SEND / ACTION_SENDTO)
 *  - Draft recovery badge when a saved draft exists
 *  - Voice command hints
 */
@Composable
internal fun TabletEmailPanel(
    vm         : TabletViewModel              = viewModel(),
    composeVm  : TabletEmailComposeViewModel  = viewModel(),
) {
    val context      = LocalContext.current
    val state       by composeVm.state.collectAsState()
    val selectedFile by composeVm.selectedFile.collectAsState()
    val scrollState  = rememberScrollState()
    var showSendError by remember { mutableStateOf(false) }

    // ── Voice send trigger ────────────────────────────────────────────────────
    // Observed here (on the Composition thread) so startActivity runs on main.
    LaunchedEffect(Unit) {
        composeVm.sendTrigger.collect {
            val sendIntent = composeVm.buildSendIntent()
            if (sendIntent != null) {
                context.startActivity(sendIntent)
            } else {
                showSendError = true
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(PanelBg),
    ) {
        // ── Toolbar ─────────────────────────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            PanelHeader(label = "EMAIL", icon = Icons.Filled.Email, tint = AmberHint)

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                // Draft recovery badge
                if (composeVm.hasSavedDraft && !state.isDirty) {
                    TextButton(
                        onClick = { /* no-op — draft is already loaded */ },
                        colors  = ButtonDefaults.textButtonColors(contentColor = AmberHint),
                    ) {
                        Icon(Icons.Filled.Drafts, contentDescription = null, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("Draft restored", fontSize = 10.sp, fontFamily = FontFamily.Monospace)
                    }
                }
                // Clear / new button
                if (state.isDirty) {
                    TextButton(
                        onClick = composeVm::clearDraft,
                        colors  = ButtonDefaults.textButtonColors(contentColor = RedBad),
                    ) {
                        Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("Clear", fontSize = 10.sp, fontFamily = FontFamily.Monospace)
                    }
                }
            }
        }

        HorizontalDivider(color = BorderC)

        // ── Compose form ─────────────────────────────────────────────────────
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(scrollState)
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // ── To field ──────────────────────────────────────────────────────
            ComposeFieldRow(
                label       = "To",
                value       = state.to,
                onValueChange = composeVm::updateTo,
                placeholder = "recipient@example.com",
                required    = true,
                trailingContent = {
                    IconButton(
                        onClick  = composeVm::toggleCcBcc,
                        modifier = Modifier.size(20.dp),
                    ) {
                        Icon(
                            if (state.showCcBcc) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                            contentDescription = "Show CC/BCC",
                            tint               = TextMuted,
                            modifier           = Modifier.size(16.dp),
                        )
                    }
                }
            )

            // ── CC / BCC (expandable) ──────────────────────────────────────────
            AnimatedVisibility(
                visible = state.showCcBcc,
                enter   = expandVertically(),
                exit    = shrinkVertically(),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    ComposeFieldRow("CC",  state.cc,  composeVm::updateCc,  "cc@example.com")
                    ComposeFieldRow("BCC", state.bcc, composeVm::updateBcc, "bcc@example.com")
                }
            }

            HorizontalDivider(color = BorderC)

            // ── Subject ────────────────────────────────────────────────────────
            ComposeFieldRow(
                label         = "Subject",
                value         = state.subject,
                onValueChange = composeVm::updateSubject,
                placeholder   = "Email subject",
            )

            HorizontalDivider(color = BorderC)

            // ── Body ───────────────────────────────────────────────────────────
            ComposeBodyField(
                value         = state.body,
                onValueChange = composeVm::updateBody,
            )

            // ── Attachments ────────────────────────────────────────────────────
            if (state.hasAttachments || selectedFile != null) {
                AttachmentsSection(
                    attachments  = state.attachments,
                    selectedFile = selectedFile,
                    onAttach     = composeVm::attachSelectedFile,
                    onRemove     = composeVm::removeAttachment,
                )
            } else {
                // Show an "attach selected file" chip if one is selected
                if (selectedFile != null) {
                    AttachSelectedFileChip(
                        file    = selectedFile!!,
                        onAttach = composeVm::attachSelectedFile,
                    )
                }
            }

            // ── Attach prompt when file context present ───────────────────────
            if (selectedFile != null && !state.attachments.any { it.uri == selectedFile!!.uri }) {
                AttachSelectedFileChip(
                    file     = selectedFile!!,
                    onAttach = composeVm::attachSelectedFile,
                )
            }

            // ── Voice hints ────────────────────────────────────────────────────
            VoiceHints(
                hints = listOf(
                    "\"Jarvis, change subject to…\"",
                    "\"Jarvis, attach the selected file\"",
                    "\"Jarvis, send email\"",
                    "\"Jarvis, draft this\"",
                )
            )
        }

        // ── Send bar ─────────────────────────────────────────────────────────
        HorizontalDivider(color = BorderC)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(PanelBg)
                .padding(horizontal = 20.dp, vertical = 10.dp),
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            // Left: open in Gmail
            OutlinedButton(
                onClick = {
                    context.startActivity(
                        context.packageManager
                            .getLaunchIntentForPackage("com.google.android.gm")
                            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            ?: Intent(Intent.ACTION_MAIN)
                                .addCategory(Intent.CATEGORY_APP_EMAIL)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                },
                shape  = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = AmberHint),
                border = androidx.compose.foundation.BorderStroke(1.dp, AmberHint.copy(alpha = 0.35f)),
            ) {
                Icon(Icons.Filled.Email, contentDescription = null, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(6.dp))
                Text("Open Gmail", fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }

            // Right: send
            Button(
                onClick = {
                    val intent = composeVm.buildSendIntent()
                    if (intent != null) {
                        context.startActivity(intent)
                    } else {
                        showSendError = true
                    }
                },
                enabled  = state.hasRecipient,
                shape    = RoundedCornerShape(8.dp),
                colors   = ButtonDefaults.buttonColors(
                    containerColor = CyanHigh,
                    contentColor   = Color(0xFF001529),
                    disabledContainerColor = CyanHigh.copy(alpha = 0.25f),
                    disabledContentColor   = TextMuted,
                ),
            ) {
                Icon(Icons.Filled.Send, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text(
                    if (state.hasAttachments) "Send with attachment" else "Send",
                    fontSize   = 13.sp,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                )
            }
        }

        if (showSendError) {
            LaunchedEffect(Unit) {
                kotlinx.coroutines.delay(3000)
                showSendError = false
            }
            Text(
                "Add a recipient first.",
                color    = RedBad,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
            )
        }
    }
}

// ── Sub-composables ───────────────────────────────────────────────────────────

@Composable
private fun ComposeFieldRow(
    label          : String,
    value          : String,
    onValueChange  : (String) -> Unit,
    placeholder    : String,
    required       : Boolean  = false,
    trailingContent: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier          = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            color      = if (required && value.isBlank()) AmberHint else TextMuted,
            fontSize   = 12.sp,
            fontFamily = FontFamily.Monospace,
            modifier   = Modifier.width(60.dp),
        )
        BasicTextField(
            value         = value,
            onValueChange = onValueChange,
            textStyle     = TextStyle(
                color      = TextPri,
                fontSize   = 13.sp,
                fontFamily = FontFamily.Monospace,
            ),
            cursorBrush   = SolidColor(CyanHigh),
            singleLine    = true,
            decorationBox = { inner ->
                Box(modifier = Modifier.fillMaxWidth()) {
                    if (value.isEmpty()) {
                        Text(
                            placeholder,
                            color      = TextMuted,
                            fontSize   = 13.sp,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                    inner()
                }
            },
            modifier = Modifier.weight(1f),
        )
        trailingContent?.invoke()
    }
}

@Composable
private fun ComposeBodyField(
    value         : String,
    onValueChange : (String) -> Unit,
) {
    BasicTextField(
        value         = value,
        onValueChange = onValueChange,
        textStyle     = TextStyle(
            color      = TextPri,
            fontSize   = 13.sp,
            fontFamily = FontFamily.Monospace,
            lineHeight  = 20.sp,
        ),
        cursorBrush   = SolidColor(CyanHigh),
        minLines      = 8,
        decorationBox = { inner ->
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = 160.dp),
                contentAlignment = Alignment.TopStart,
            ) {
                if (value.isEmpty()) {
                    Text(
                        "Email body…",
                        color      = TextMuted,
                        fontSize   = 13.sp,
                        fontFamily = FontFamily.Monospace,
                    )
                }
                inner()
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun AttachmentsSection(
    attachments  : List<TabletSelectedFile>,
    selectedFile : TabletSelectedFile?,
    onAttach     : () -> Unit,
    onRemove     : (TabletSelectedFile) -> Unit,
) {
    Column(
        modifier            = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(AttachBg)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            "ATTACHMENTS",
            color        = GreenOk.copy(alpha = 0.7f),
            fontSize     = 8.sp,
            fontFamily   = FontFamily.Monospace,
            letterSpacing = 2.sp,
        )
        attachments.forEach { file ->
            Row(
                modifier              = Modifier.fillMaxWidth(),
                verticalAlignment     = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Filled.AttachFile,
                    contentDescription = null,
                    tint               = GreenOk,
                    modifier           = Modifier.size(14.dp),
                )
                Text(
                    file.name,
                    color      = TextPri,
                    fontSize   = 12.sp,
                    fontFamily = FontFamily.Monospace,
                    modifier   = Modifier.weight(1f),
                    maxLines   = 1,
                    overflow   = TextOverflow.Ellipsis,
                )
                Text(
                    file.sizeLabel,
                    color      = TextMuted,
                    fontSize   = 10.sp,
                    fontFamily = FontFamily.Monospace,
                )
                IconButton(
                    onClick  = { onRemove(file) },
                    modifier = Modifier.size(20.dp),
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = "Remove",
                        tint               = RedBad,
                        modifier           = Modifier.size(14.dp),
                    )
                }
            }
        }
        // Attach context file if not already added
        if (selectedFile != null && attachments.none { it.uri == selectedFile.uri }) {
            AttachSelectedFileChip(file = selectedFile, onAttach = onAttach)
        }
    }
}

@Composable
private fun AttachSelectedFileChip(
    file    : TabletSelectedFile,
    onAttach: () -> Unit,
) {
    OutlinedButton(
        onClick         = onAttach,
        shape           = RoundedCornerShape(8.dp),
        colors          = ButtonDefaults.outlinedButtonColors(contentColor = GreenOk),
        border          = androidx.compose.foundation.BorderStroke(1.dp, GreenOk.copy(alpha = 0.4f)),
        contentPadding  = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
    ) {
        Icon(Icons.Filled.AttachFile, contentDescription = null, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(6.dp))
        Text(
            "Attach: ${file.name.take(30)}",
            fontSize   = 11.sp,
            fontFamily = FontFamily.Monospace,
            maxLines   = 1,
            overflow   = TextOverflow.Ellipsis,
        )
    }
}
