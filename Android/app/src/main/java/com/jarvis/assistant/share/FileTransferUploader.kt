package com.jarvis.assistant.share

import android.content.Context
import android.util.Log
import com.jarvis.assistant.JarvisApp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.DataOutputStream
import java.net.HttpURLConnection
import java.net.URL

data class UploadResult(
    val success: Boolean,
    val transferId: String? = null,
    val errorMessage: String? = null
)

class FileTransferUploader(private val context: Context) {

    companion object {
        private const val TAG = "FileTransferUploader"
        private const val BOUNDARY = "JarvisFileBoundary"
    }

    suspend fun upload(
        filename: String,
        mimeType: String,
        data: ByteArray,
        openOnMac: Boolean = false,
        suggestedAction: String = "save",
        userVisibleName: String = filename
    ): UploadResult = withContext(Dispatchers.IO) {
        val cfg = JarvisApp.macBrainConnectionManager.settingsRepo.snapshot()
        val token = cfg.deviceToken ?: run {
            return@withContext UploadResult(false, errorMessage = "Not paired with daemon.")
        }
        val baseUrl = cfg.baseUrl.trimEnd('/')
        val uploadUrl = "$baseUrl/v1/files/upload"

        try {
            val url = URL(uploadUrl)
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.setRequestProperty("Authorization", "Bearer $token")
            conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=$BOUNDARY")
            conn.setRequestProperty("X-Device-Id", "android")
            conn.doOutput = true
            conn.connectTimeout = 10_000
            conn.readTimeout = 60_000

            DataOutputStream(conn.outputStream).use { dos ->
                // File part
                dos.writeBytes("--$BOUNDARY\r\n")
                dos.writeBytes("Content-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\n")
                dos.writeBytes("Content-Type: $mimeType\r\n\r\n")
                dos.write(data)
                dos.writeBytes("\r\n")

                // Metadata fields
                fun writeField(name: String, value: String) {
                    dos.writeBytes("--$BOUNDARY\r\n")
                    dos.writeBytes("Content-Disposition: form-data; name=\"$name\"\r\n\r\n")
                    dos.writeBytes(value)
                    dos.writeBytes("\r\n")
                }
                writeField("targetPlatform", "mac")
                writeField("openOnMac", openOnMac.toString())
                writeField("suggestedAction", suggestedAction)
                writeField("userVisibleName", userVisibleName)
                dos.writeBytes("--$BOUNDARY--\r\n")
            }

            val code = conn.responseCode
            if (code == 200) {
                val body = conn.inputStream.bufferedReader().readText()
                val json = JSONObject(body)
                val transferId = json.optString("transferId")
                Log.d(TAG, "Upload success: transferId=$transferId filename=$filename size=${data.size}")
                UploadResult(success = true, transferId = transferId)
            } else {
                val err = conn.errorStream?.bufferedReader()?.readText() ?: "HTTP $code"
                Log.w(TAG, "Upload failed: HTTP $code $err")
                UploadResult(false, errorMessage = "Upload failed: $err")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Upload exception: ${e.message}")
            UploadResult(false, errorMessage = e.message)
        }
    }
}
