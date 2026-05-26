package com.jarvis.assistant.voice.piper

/**
 * VoiceDefinition — metadata about an installable Piper voice.
 *
 * Used by [PiperVoiceRegistry] to enumerate every voice the app knows about
 * (bundled in assets, downloaded later, or symlinked from external storage).
 *
 * Fields:
 *   id           Stable machine identifier ("en_GB-jarvis-medium").  Used as
 *                the SharedPreferences key for the active-voice setting.
 *   displayName  Human-facing label for the Settings UI ("Jarvis (medium)").
 *   modelAssetPath
 *                Path inside `app/src/main/assets/` for the .onnx file, or
 *                null when the voice ships outside the APK.
 *   jsonAssetPath
 *                Path inside `app/src/main/assets/` for the .onnx.json file.
 *   externalModelPath / externalJsonPath
 *                Absolute filesystem paths used when the voice is downloaded
 *                or sideloaded.  The loader prefers these over the asset
 *                versions when present.
 *   sampleRate   Pre-known sample rate for AudioTrack setup.  The loader
 *                also reads it from the JSON; this field is a hint that
 *                lets the registry surface a quality summary without
 *                opening the model.
 *   quality      Free-text quality tier ("low" / "medium" / "high") —
 *                taken from the Piper distribution naming convention.
 *   gender       "male" / "female" / "neutral" / "unknown".
 *   locale       BCP-47 locale tag, e.g. "en-GB".
 */
data class VoiceDefinition(
    val id: String,
    val displayName: String,
    val modelAssetPath: String? = null,
    val jsonAssetPath: String? = null,
    val externalModelPath: String? = null,
    val externalJsonPath: String? = null,
    val sampleRate: Int = 22_050,
    val quality: String = "medium",
    val gender: String = "unknown",
    val locale: String = "en-GB",
)
