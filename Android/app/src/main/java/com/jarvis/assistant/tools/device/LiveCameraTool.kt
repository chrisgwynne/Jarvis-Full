package com.jarvis.assistant.tools.device

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.MediaStore
import android.util.Log
import com.jarvis.assistant.tools.framework.RiskClass
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema

/**
 * LiveCameraTool — #57: opens a LIVE front-facing camera view (a "mirror") so
 * the user can see their own face. Distinct from the snap-a-photo tools
 * (`CameraCaptureTool` / `SelfieCaptureTool`) — this opens a live viewfinder
 * and takes no picture.
 *
 * Implemented by launching the system camera app in selfie mode via intent
 * (best-effort front-camera hints — OEM camera apps honour these to varying
 * degrees). Registered as an LLM-reachable tool so it can run as the *action*
 * half of an empathy+action turn ([LlmResult.Composite], #51): the model speaks
 * an empathetic line while this opens the camera. NOT in the instant allowlist,
 * so it always flows through the composer rather than a bare regex.
 */
class LiveCameraTool(private val context: Context) : Tool {

    override val name        = "live_camera"
    override val description  = "Opens a live front-facing camera view (a mirror) so the user can see their own face."
    override val riskClass    = RiskClass.LOW
    // Launches the camera app via intent — the camera app owns the CAMERA
    // permission, so this tool needs none of its own.
    override val requiredPermissions: List<String> = emptyList()

    override fun schema() = ToolSchema(
        name        = name,
        description = "Open a live front-facing camera view (a mirror) so the user can see their face. " +
                      "Use for 'turn the camera on so I can see myself', 'show me my face', 'open a mirror'. " +
                      "This opens a live viewfinder; it does NOT take a photo.",
        parameters  = mapOf(
            "type" to "object",
            "properties" to emptyMap<String, Any>(),
            "required" to emptyList<String>()
        )
    )

    override fun matches(transcript: String): ToolInput? =
        if (TRIGGERS.containsMatchIn(transcript.trim())) ToolInput(transcript.trim()) else null

    override suspend fun execute(input: ToolInput): ToolResult {
        val intent = Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // Best-effort front-camera hints recognised by many OEM camera apps.
            putExtra("android.intent.extras.CAMERA_FACING", 1)
            putExtra("android.intent.extras.LENS_FACING_FRONT", 1)
            putExtra("android.intent.extra.USE_FRONT_CAMERA", true)
        }
        return try {
            context.startActivity(intent)
            ToolResult.Success("Camera's on — you can see yourself now.")
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "no camera app to open: ${e.message}")
            ToolResult.Failure("I couldn't find a camera app to open.")
        } catch (e: Exception) {
            Log.w(TAG, "live_camera launch failed: ${e.message}")
            ToolResult.Failure("I couldn't open the camera.")
        }
    }

    companion object {
        private const val TAG = "LiveCameraTool"

        // Deliberately scoped to the "see my face / mirror / front-camera-on"
        // intent — NOT generic "open the camera" (that's app-launch / capture).
        private val TRIGGERS = Regex(
            """(?:turn|switch|put)\s+(?:the\s+)?front\s+camera\s+on""" +
            """|camera\s+on\s+so\s+i\s+can\s+see""" +
            """|(?:see|show)\s+(?:me\s+)?my\s+face""" +
            """|let\s+me\s+see\s+(?:myself|my\s+face)""" +
            """|(?:open|start)\s+(?:a\s+|the\s+)?(?:front[\s-]?camera|mirror|selfie\s+(?:view|camera|cam))""",
            RegexOption.IGNORE_CASE
        )
    }
}
