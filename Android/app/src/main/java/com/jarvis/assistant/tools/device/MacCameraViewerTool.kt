package com.jarvis.assistant.tools.device

import android.content.Context
import android.content.Intent
import android.util.Log
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema
import com.jarvis.assistant.ui.camera.MacCameraViewerActivity
import com.jarvis.assistant.util.SettingsStore

/**
 * MacCameraViewerTool — opens the live Mac camera viewer without involving Mac Brain or the LLM.
 *
 * Matched by an exact phrase regex; falls through to the LLM for anything not covered.
 * Does NOT call Mac Brain, does NOT route through the LLM for clear camera phrases.
 * After opening the viewer, Jarvis returns to its normal listening state.
 */
class MacCameraViewerTool(
    private val context: Context,
    private val settings: SettingsStore,
) : Tool {

    override val name        = "mac_camera_viewer"
    override val description = "Opens the live Mac webcam viewer"
    override val requiresNetwork = true
    override fun schema(): ToolSchema? = null

    companion object {
        private const val TAG = "MacCameraViewerTool"

        private val PHRASES = Regex(
            """show\s+(?:me\s+)?(?:the\s+)?mac\s+(?:camera|webcam)""" +
            """|open\s+mac\s+camera""" +
            """|show\s+jarvis\s+camera""" +
            """|show\s+mac\s+webcam""" +
            """|let\s+me\s+see\s+(?:the\s+)?mac\s+camera""" +
            """|check\s+(?:the\s+)?mac\s+camera""" +
            """|view\s+mac\s+camera""" +
            """|open\s+(?:the\s+)?mac\s+webcam""" +
            """|show\s+the\s+mac\s+webcam""",
            RegexOption.IGNORE_CASE
        )
    }

    override fun matches(transcript: String): ToolInput? =
        if (PHRASES.containsMatchIn(transcript.trim())) ToolInput(transcript.trim()) else null

    override suspend fun execute(input: ToolInput): ToolResult {
        Log.i(TAG, "MAC_CAMERA_OPEN_REQUESTED")

        if (!settings.macCameraEnabled) {
            Log.w(TAG, "MAC_CAMERA_ERROR: feature disabled in settings")
            return ToolResult.Failure("Mac camera viewer is disabled in Settings.")
        }

        Log.i(TAG, "MAC_CAMERA_VIEWER_OPENED")
        val intent = Intent(context, MacCameraViewerActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)

        Log.i(TAG, "LISTENING_RESTARTED_AFTER_CAMERA_VIEWER")
        return ToolResult.Success(spokenFeedback = "", silent = true)
    }
}
