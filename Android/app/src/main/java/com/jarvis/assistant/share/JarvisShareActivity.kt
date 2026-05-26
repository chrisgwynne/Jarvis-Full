package com.jarvis.assistant.share

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import android.util.Log
import android.widget.Toast
import com.jarvis.assistant.JarvisApp

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.InputStream

/**
 * Share target activity: receives files/images shared from other apps and
 * forwards them to the Mac via the daemon file transfer endpoint.
 */
class JarvisShareActivity : Activity() {

    companion object {
        private const val TAG = "JarvisShare"
    }

    private val scope = CoroutineScope(Dispatchers.IO)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val action = intent.action
        val type = intent.type ?: ""

        when {
            action == Intent.ACTION_SEND && type.isNotBlank() -> {
                @Suppress("DEPRECATION")
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (uri != null) {
                    handleShare(uri, type)
                } else {
                    finish()
                }
            }
            else -> finish()
        }
    }

    private fun handleShare(uri: Uri, mimeType: String) {
        if (!JarvisApp.macBrainConnectionManager.settingsRepo.snapshot().isPaired) {
            Toast.makeText(this, "Mac bridge is not connected.", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        Toast.makeText(this, "Sending to the Mac…", Toast.LENGTH_SHORT).show()

        scope.launch {
            try {
                val filename = resolveFilename(uri) ?: "shared_file"
                val stream: InputStream = contentResolver.openInputStream(uri) ?: run {
                    runOnUiThread { Toast.makeText(this@JarvisShareActivity, "Could not read file.", Toast.LENGTH_LONG).show() }
                    finish()
                    return@launch
                }
                val bytes = stream.use { it.readBytes() }

                val uploader = FileTransferUploader(this@JarvisShareActivity)
                val result = uploader.upload(
                    filename = filename,
                    mimeType = mimeType,
                    data = bytes,
                    openOnMac = true,
                    suggestedAction = "view",
                    userVisibleName = filename
                )

                runOnUiThread {
                    if (result.success) {
                        Toast.makeText(this@JarvisShareActivity, "Sent to Mac.", Toast.LENGTH_SHORT).show()
                    } else {
                        Toast.makeText(this@JarvisShareActivity, result.errorMessage ?: "Upload failed.", Toast.LENGTH_LONG).show()
                    }
                    finish()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Share failed: ${e.message}")
                runOnUiThread {
                    Toast.makeText(this@JarvisShareActivity, "Could not send to Mac: ${e.message}", Toast.LENGTH_LONG).show()
                    finish()
                }
            }
        }
    }

    private fun resolveFilename(uri: Uri): String? {
        // Try content resolver display name first
        contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val name = c.getString(0)
                if (!name.isNullOrBlank()) return name
            }
        }
        // Fall back to URI last segment
        return uri.lastPathSegment
    }
}
