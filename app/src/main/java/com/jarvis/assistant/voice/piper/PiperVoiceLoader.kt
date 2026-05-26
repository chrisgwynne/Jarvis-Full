package com.jarvis.assistant.voice.piper

import android.content.Context
import android.util.Log
import com.google.gson.Gson
import com.google.gson.JsonSyntaxException
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest

/**
 * PiperVoiceLoader — copies voice files from assets to internal storage and
 * parses the JSON config.
 *
 * Why we don't load ONNX from the asset stream directly: ONNX Runtime needs a
 * real seekable file path; reading a Piper model (50–100 MB) into a
 * `ByteArray` first wastes memory and is slow.  Internal-storage paths
 * also let us keep downloaded voices alongside bundled ones with a single
 * code path.
 *
 * Idempotency: [copyAssetsIfNeeded] hashes the existing copy and skips when
 * the asset is byte-identical to what's already on disk.  After an APK
 * update with a new model the hash differs, the old file is overwritten.
 */
class PiperVoiceLoader(private val context: Context) {

    companion object {
        private const val TAG = "PiperVoiceLoader"
        private const val VOICES_SUBDIR = "voices"
        /** Hash chunk size — keep tiny so we never hold the whole model in RAM. */
        private const val HASH_CHUNK = 64 * 1024
    }

    private val gson = Gson()

    /**
     * Resolve filesystem paths for [voice].  Copies from assets when needed.
     * Returns null when neither asset nor external paths are usable —
     * caller treats that as "voice not installed" and stays on system TTS.
     */
    fun resolveOrCopy(voice: VoiceDefinition): Resolved? {
        // Prefer external (downloaded / sideloaded) paths if both exist.
        if (voice.externalModelPath != null && voice.externalJsonPath != null) {
            val m = File(voice.externalModelPath)
            val j = File(voice.externalJsonPath)
            if (m.isFile && j.isFile) {
                Log.d(TAG, "[VOICE_FILES_EXTERNAL] model=${m.absolutePath} json=${j.absolutePath}")
                return Resolved(modelFile = m, jsonFile = j)
            }
            Log.w(TAG, "[VOICE_FILES_EXTERNAL_MISSING] expected at $voice.externalModelPath")
        }

        val modelAsset = voice.modelAssetPath ?: return null
        val jsonAsset  = voice.jsonAssetPath  ?: return null

        val voicesDir = File(context.filesDir, VOICES_SUBDIR).apply { mkdirs() }
        val modelFile = File(voicesDir, modelAsset.substringAfterLast('/'))
        val jsonFile  = File(voicesDir, jsonAsset.substringAfterLast('/'))

        // Copy each file if missing OR hash-differs.  Silently skip when the
        // asset is missing entirely — the caller logs once.
        val modelOk = copyAssetIfNeeded(modelAsset, modelFile)
        val jsonOk  = copyAssetIfNeeded(jsonAsset, jsonFile)
        if (!modelOk || !jsonOk) {
            Log.w(TAG, "[VOICE_ASSET_COPY_INCOMPLETE] modelOk=$modelOk jsonOk=$jsonOk")
            return null
        }
        Log.d(TAG, "[VOICE_FILES_RESOLVED] model=${modelFile.absolutePath} json=${jsonFile.absolutePath}")
        return Resolved(modelFile, jsonFile)
    }

    /**
     * Copy a single asset to [dest] when the destination doesn't exist or
     * differs by hash from the asset.  Returns false when the asset itself
     * isn't present in the APK (lets the caller skip the voice entirely
     * without surfacing an exception).
     */
    private fun copyAssetIfNeeded(assetPath: String, dest: File): Boolean {
        return try {
            val assetExists = try {
                context.assets.openFd(assetPath).close(); true
            } catch (_: Exception) {
                // Some assets (compressed) can't be openFd'd — fall back to
                // a stream-based existence check.
                try { context.assets.open(assetPath).close(); true }
                catch (_: FileNotFoundException) { false }
                catch (_: Exception) { false }
            }
            if (!assetExists) {
                Log.w(TAG, "[VOICE_ASSET_MISSING] path=$assetPath")
                return false
            }

            // If destination exists, compare hashes BEFORE re-copying.
            if (dest.isFile && dest.length() > 0L) {
                val destHash  = sha256(dest)
                val assetHash = sha256Asset(assetPath)
                if (destHash == assetHash) {
                    Log.d(TAG, "[VOICE_ASSET_UP_TO_DATE] path=$assetPath bytes=${dest.length()}")
                    return true
                }
                Log.d(TAG, "[VOICE_ASSET_REFRESH] path=$assetPath (hash mismatch)")
            }

            context.assets.open(assetPath).use { input ->
                dest.outputStream().use { output ->
                    input.copyTo(output, bufferSize = HASH_CHUNK)
                }
            }
            Log.d(TAG, "[VOICE_ASSET_COPIED] path=$assetPath bytes=${dest.length()}")
            true
        } catch (e: Exception) {
            Log.w(TAG, "[VOICE_ASSET_COPY_FAILED] path=$assetPath ${e.message}")
            try { dest.delete() } catch (_: Exception) {}
            false
        }
    }

    /**
     * Parse the JSON config.  Returns null on any failure — caller logs and
     * falls back.  Validation: at minimum the [PiperVoiceConfig.phonemeIdMap]
     * must be present and non-empty for the engine to ever produce phoneme
     * ids — that's the operator-meaningful precondition.
     */
    fun parseConfig(jsonFile: File): PiperVoiceConfig? {
        return try {
            val text = jsonFile.readText(Charsets.UTF_8)
            val cfg  = gson.fromJson(text, PiperVoiceConfig::class.java)
            if (cfg == null) {
                Log.w(TAG, "[VOICE_CONFIG_PARSE_NULL] path=${jsonFile.absolutePath}")
                return null
            }
            if (cfg.phonemeIdMap.isNullOrEmpty()) {
                Log.w(TAG, "[VOICE_CONFIG_VALIDATION_FAILED] reason=phoneme_id_map_missing")
                return null
            }
            Log.d(TAG, "[VOICE_CONFIG_PARSED] sampleRate=${cfg.sampleRate} " +
                "phonemes=${cfg.phonemeIdMap.size} speaker=${if (cfg.isSingleSpeaker) "single" else "multi"}")
            cfg
        } catch (e: JsonSyntaxException) {
            Log.w(TAG, "[VOICE_CONFIG_MALFORMED] ${e.message}")
            null
        } catch (e: Exception) {
            Log.w(TAG, "[VOICE_CONFIG_READ_FAILED] ${e.message}")
            null
        }
    }

    /** Delete all bundled voice files from internal storage. */
    fun clearCache() {
        val voicesDir = File(context.filesDir, VOICES_SUBDIR)
        if (!voicesDir.exists()) return
        voicesDir.listFiles()?.forEach { it.delete() }
        Log.d(TAG, "[VOICE_CACHE_CLEARED]")
    }

    // ── Hash helpers ────────────────────────────────────────────────────────

    private fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(HASH_CHUNK)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun sha256Asset(assetPath: String): String {
        val md = MessageDigest.getInstance("SHA-256")
        context.assets.open(assetPath).use { input ->
            val buf = ByteArray(HASH_CHUNK)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /** Resolved filesystem paths for a voice. */
    data class Resolved(
        val modelFile: File,
        val jsonFile: File,
    )
}
