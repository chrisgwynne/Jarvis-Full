package com.jarvis.assistant.tools.device

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.jarvis.assistant.runtime.FailurePhrases
import com.jarvis.assistant.tools.ContactLookup
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult
import com.jarvis.assistant.tools.framework.ToolSchema
import java.util.Calendar

/**
 * CallTool — places a voice or video call to a contact.
 *
 * Channel routing mirrors [com.jarvis.assistant.tools.device.MessageIntentParser]:
 *
 *   "call Mike"                  → PHONE   voice
 *   "call Mike on WhatsApp"      → WHATSAPP voice
 *   "WhatsApp Mike"              → (handled by messaging — not us)
 *   "WhatsApp call Mike"         → WHATSAPP voice
 *   "video call Mike"            → PHONE   video (declines)
 *   "WhatsApp video call Mike"   → WHATSAPP video
 *   "facetime Mike on WhatsApp"  → WHATSAPP video
 *
 * The recipient name is stripped of channel noise tokens before being
 * handed to [ContactLookup], so "Mike on WhatsApp" reaches the lookup as
 * "Mike" and the standard fuzzy-match path works unchanged.
 *
 * Risk class is HIGH — outgoing calls cannot be undone and carry real social
 * consequences (woken contacts, embarrassing mistaken dials).  An explicit
 * affirmative ("yes", "go ahead", "call them") is always required before
 * [execute] is reached.
 *
 * A quiet-hours gate (22:00–07:00) is enforced inside [execute] as a second
 * safety layer — even an explicit confirmation is blocked during those hours
 * so a late-night false positive cannot slip through.
 */
class CallTool(
    private val context: Context,
    private val contacts: ContactLookup,
) : Tool {

    override val name = "call_contact"
    override val description = "Make a phone or WhatsApp call to a contact by name"
    override val requiredPermissions = listOf(Manifest.permission.CALL_PHONE)
    override val riskClass = com.jarvis.assistant.tools.framework.RiskClass.HIGH

    companion object { private const val TAG = "CallTool" }

    private val whatsAppCall by lazy { WhatsAppCallAdapter(context) }

    override fun schema() = ToolSchema(
        name        = name,
        description = "Place a voice or video call to a contact. Specify the channel by saying \"on WhatsApp\" or \"WhatsApp call\" — defaults to the native phone otherwise.",
        parameters  = mapOf(
            "type" to "object",
            "properties" to mapOf(
                "name"    to mapOf("type" to "string", "description" to "Contact name to call, e.g. \"Mum\" or \"Chris\""),
                "channel" to mapOf("type" to "string", "enum" to listOf("PHONE", "WHATSAPP"), "description" to "Default PHONE."),
                "mode"    to mapOf("type" to "string", "enum" to listOf("VOICE", "VIDEO"), "description" to "Default VOICE.")
            ),
            "required" to listOf("name")
        )
    )

    override fun matches(transcript: String): ToolInput? {
        val intent = CallIntentParser.parse(transcript.trim()) ?: return null
        return ToolInput(
            transcript,
            mapOf(
                "name"    to intent.recipient,
                "channel" to intent.channel.name,
                "mode"    to intent.mode.name,
            )
        )
    }

    override suspend fun execute(input: ToolInput): ToolResult {
        // Quiet-hours gate: refuse calls between 22:00 and 07:00.
        // This fires even when the user has confirmed — it catches late-night
        // false positives that slipped through the HIGH-risk confirmation.
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        if (hour >= 22 || hour < 7) {
            Log.w(TAG, "[CALL_BLOCKED_QUIET_HOURS] hour=$hour")
            return ToolResult.Failure(
                "It's after 10 PM — I won't place calls this late. Try again in the morning."
            )
        }

        val name = input.param("name")
        val channel = runCatching {
            CallIntentParser.Channel.valueOf(input.param("channel"))
        }.getOrDefault(CallIntentParser.Channel.PHONE)
        val mode = runCatching {
            CallIntentParser.Mode.valueOf(input.param("mode"))
        }.getOrDefault(CallIntentParser.Mode.VOICE)

        val contact = contacts.find(name)
            ?: return ToolResult.Failure("No $name in your contacts that I can see.")

        Log.d(TAG, "[CALL_DISPATCH] to='${contact.displayName}' channel=$channel mode=$mode")

        return when (channel) {
            CallIntentParser.Channel.WHATSAPP -> {
                val waMode = if (mode == CallIntentParser.Mode.VIDEO)
                    WhatsAppCallAdapter.Mode.VIDEO
                else
                    WhatsAppCallAdapter.Mode.VOICE
                whatsAppCall.call(contact, waMode)
            }
            CallIntentParser.Channel.PHONE -> placeNativeCall(contact, mode)
        }
    }

    private fun placeNativeCall(
        contact: ContactLookup.Contact,
        mode: CallIntentParser.Mode,
    ): ToolResult {
        // Native dialer only supports voice via tel:.  Video on the native
        // dialer would need a carrier-specific intent; we surface the
        // mismatch rather than silently dropping it.
        if (mode == CallIntentParser.Mode.VIDEO) {
            return ToolResult.Failure(
                "I can only video-call ${contact.displayName} through WhatsApp — say \"video call them on WhatsApp\"."
            )
        }
        return try {
            context.startActivity(
                Intent(Intent.ACTION_CALL, Uri.parse("tel:${contact.number}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            ToolResult.Success("Calling ${contact.displayName}.")
        } catch (e: Exception) {
            ToolResult.Failure(FailurePhrases.CALL_FAILED)
        }
    }
}
