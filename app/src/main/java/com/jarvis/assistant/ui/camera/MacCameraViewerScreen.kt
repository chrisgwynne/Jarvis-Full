package com.jarvis.assistant.ui.camera

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import java.text.SimpleDateFormat
import java.util.*

private val BgDeep    = Color(0xFF060B14)   // deepest navy
private val Surface   = Color(0xFF0B1628)   // card surface
private val Cyan      = Color(0xFF3FA7FF)   // blueprint blue
private val Green     = Color(0xFF00E676)
private val Amber     = Color(0xFFFFAB40)
private val Red       = Color(0xFFFF5252)
private val TextPrimary = Color(0xFFE0E0E0)
private val TextMuted   = Color(0xFF7A8FAA)   // blue-grey secondary labels

@Composable
fun MacCameraViewerScreen(
    onClose: () -> Unit,
    vm: MacCameraViewModel = viewModel(),
) {
    val streamState  by vm.streamState.collectAsState()
    val currentFrame by vm.currentFrame.collectAsState()
    val timeFmt = remember { SimpleDateFormat("HH:mm:ss", Locale.getDefault()) }

    DisposableEffect(Unit) {
        vm.startStream()
        onDispose { vm.stopStream() }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BgDeep)
            .systemBarsPadding(),
    ) {
        // ── Header ──────────────────────────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                text       = "Mac Camera",
                color      = TextPrimary,
                fontSize   = 18.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusChip(streamState)
                Spacer(Modifier.width(8.dp))
                IconButton(onClick = { vm.retry() }) {
                    Icon(Icons.Default.Refresh, contentDescription = "Retry", tint = TextMuted)
                }
                IconButton(onClick = onClose) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = TextMuted)
                }
            }
        }

        // ── Frame area ──────────────────────────────────────────────────────
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .background(Surface),
            contentAlignment = Alignment.Center,
        ) {
            val frame = currentFrame
            if (frame != null) {
                androidx.compose.foundation.Image(
                    bitmap = frame.asImageBitmap(),
                    contentDescription = "Mac camera feed",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize(),
                )
            }

            when (streamState) {
                is StreamState.Connecting -> {
                    if (frame == null) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            CircularProgressIndicator(color = Cyan, modifier = Modifier.size(48.dp))
                            Spacer(Modifier.height(16.dp))
                            Text("Connecting…", color = TextMuted, fontSize = 14.sp)
                        }
                    }
                }
                is StreamState.Offline -> {
                    if (frame == null) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("Mac camera isn't available.", color = TextMuted, fontSize = 16.sp)
                            Spacer(Modifier.height(16.dp))
                            OutlinedButton(
                                onClick = { vm.retry() },
                                colors = ButtonDefaults.outlinedButtonColors(contentColor = Cyan)
                            ) {
                                Text("Retry")
                            }
                        }
                    }
                }
                is StreamState.Error -> {
                    if (frame == null) {
                        Text(
                            (streamState as StreamState.Error).message,
                            color = Red,
                            fontSize = 14.sp,
                        )
                    }
                }
                else -> {}
            }
        }

        // ── Footer info ─────────────────────────────────────────────────────
        val lastFrameMs = vm.lastFrameAtMs.get()
        if (lastFrameMs > 0L) {
            Text(
                text     = "Last frame: ${timeFmt.format(Date(lastFrameMs))}",
                color    = TextMuted,
                fontSize = 11.sp,
                modifier = Modifier
                    .align(Alignment.CenterHorizontally)
                    .padding(bottom = 8.dp),
            )
        }
    }
}

@Composable
private fun StatusChip(state: StreamState) {
    val (label, color) = when (state) {
        StreamState.Connecting             -> "Connecting" to Amber
        StreamState.Live                   -> "Live" to Green
        is StreamState.Snapshot            -> "Snapshot" to Amber
        StreamState.Offline                -> "Offline" to Red
        is StreamState.Error               -> "Error" to Red
    }
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = color.copy(alpha = 0.15f),
        modifier = Modifier.padding(end = 4.dp),
    ) {
        Text(
            text     = label,
            color    = color,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
        )
    }
}
