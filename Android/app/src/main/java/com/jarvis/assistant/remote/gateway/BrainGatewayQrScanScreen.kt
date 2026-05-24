package com.jarvis.assistant.remote.gateway

import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.lifecycle.awaitInstance
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * QR scan screen for Brain Gateway pairing.
 *
 * Reads: `{ "url": "https://100.91.42.7:8765", "code": "JARVIS-XXXX" }`
 *
 * On a valid scan, calls [onResult] with the gateway URL and pairing code.
 * The caller is responsible for calling [BrainGatewayPairingClient.pair].
 */
@Composable
internal fun BrainGatewayQrScanScreen(
    onResult: (gatewayUrl: String, pairingCode: String) -> Unit,
    onCancel: () -> Unit,
) {
    val context        = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var error   by remember { mutableStateOf<String?>(null) }
    var scanned by remember { mutableStateOf(false) }

    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    val previewView      = remember { PreviewView(context) }
    val scanner          = remember { BarcodeScanning.getClient() }

    DisposableEffect(Unit) {
        onDispose {
            analysisExecutor.shutdown()
            scanner.close()
        }
    }

    LaunchedEffect(Unit) {
        try {
            val provider = ProcessCameraProvider.awaitInstance(context)

            val preview = Preview.Builder().build()
                .also { it.surfaceProvider = previewView.surfaceProvider }

            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(analysisExecutor) { imageProxy ->
                processFrame(imageProxy, scanner) { raw ->
                    if (!scanned) {
                        scanned = true
                        parseGatewayQr(raw)?.let { (url, code) ->
                            onResult(url, code)
                        } ?: run {
                            scanned = false
                            error = "QR not recognised — expected Mac Brain Gateway format"
                        }
                    }
                }
            }

            provider.unbindAll()
            provider.bindToLifecycle(
                lifecycleOwner,
                CameraSelector.DEFAULT_BACK_CAMERA,
                preview,
                analysis,
            )
        } catch (e: Exception) {
            Log.w("GatewayQrScan", "CameraX setup failed: ${e.message}")
            error = "Camera error: ${e.message}"
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {

        AndroidView(
            factory  = { previewView },
            modifier = Modifier.fillMaxSize(),
        )

        Box(
            Modifier
                .size(240.dp)
                .align(Alignment.Center)
                .border(2.dp, Color.White, RoundedCornerShape(12.dp))
        )

        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .clip(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
                .background(Color.Black.copy(alpha = 0.7f))
                .padding(horizontal = 24.dp, vertical = 20.dp)
        ) {
            Text(
                text  = error ?: "Point the camera at the Mac Brain Gateway QR code",
                color = if (error != null) Color(0xFFFF6B6B) else Color.White,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
private fun processFrame(
    imageProxy: ImageProxy,
    scanner: com.google.mlkit.vision.barcode.BarcodeScanner,
    onRaw: (String) -> Unit,
) {
    val mediaImage = imageProxy.image ?: run { imageProxy.close(); return }
    val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
    scanner.process(image)
        .addOnSuccessListener { barcodes ->
            barcodes.firstOrNull { it.format == Barcode.FORMAT_QR_CODE }
                ?.rawValue
                ?.let(onRaw)
        }
        .addOnCompleteListener { imageProxy.close() }
}

/**
 * Parses a Brain Gateway QR payload.
 *
 * Expected: `{ "url": "https://...", "code": "JARVIS-XXXX" }`
 *
 * Returns null if the payload is not in the expected format.
 */
internal fun parseGatewayQr(raw: String): Pair<String, String>? =
    runCatching {
        val json = JSONObject(raw)
        val url  = json.optString("url").ifBlank { return null }
        val code = json.optString("code").ifBlank { return null }
        if (!url.startsWith("http://", ignoreCase = true) &&
            !url.startsWith("https://", ignoreCase = true)) return null
        Pair(url, code)
    }.getOrNull()
