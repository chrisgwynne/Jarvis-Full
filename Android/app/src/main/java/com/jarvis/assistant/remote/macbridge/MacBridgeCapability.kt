package com.jarvis.assistant.remote.macbridge

object MacBridgeCapability {
    const val CALL_CONTACT        = "call_contact"
    const val SEND_SMS            = "send_sms"
    const val SEND_WHATSAPP       = "send_whatsapp"
    const val FIND_CONTACT        = "find_contact"
    const val RING_PHONE          = "ring_phone"
    const val PHONE_LOCATION      = "phone_location"
    const val START_NAVIGATION    = "start_navigation"
    const val READ_NOTIFICATIONS  = "read_notifications"
    const val QUERY_NOTIFICATION  = "query_notification"
    const val CAPTURE_CAMERA      = "capture_camera"
    const val SPEAKER_ON          = "audio.speaker_on"
    const val SPEAKER_OFF         = "audio.speaker_off"
    const val TOGGLE_SPEAKER      = "audio.toggle_speaker"
    const val WHATSAPP_VOICE_CALL = "whatsapp.voice_call"
    const val WHATSAPP_VIDEO_CALL = "whatsapp.video_call"
    const val REPLY_TO_CONTACT    = "reply.to_contact"
    const val REPLY_LAST_MESSAGE  = "reply.last_message"

    val ALL: Set<String> = setOf(
        CALL_CONTACT, SEND_SMS, SEND_WHATSAPP, FIND_CONTACT, RING_PHONE,
        PHONE_LOCATION, START_NAVIGATION, READ_NOTIFICATIONS, QUERY_NOTIFICATION,
        CAPTURE_CAMERA, SPEAKER_ON, SPEAKER_OFF, TOGGLE_SPEAKER,
        WHATSAPP_VOICE_CALL, WHATSAPP_VIDEO_CALL,
        REPLY_TO_CONTACT, REPLY_LAST_MESSAGE,
    )

    val DISPLAY_NAMES: Map<String, String> = mapOf(
        CALL_CONTACT        to "Phone calls",
        SEND_SMS            to "Send SMS",
        SEND_WHATSAPP       to "WhatsApp messages",
        FIND_CONTACT        to "Contact search",
        RING_PHONE          to "Ring phone",
        PHONE_LOCATION      to "Share location",
        START_NAVIGATION    to "Navigation",
        READ_NOTIFICATIONS  to "Read notifications",
        QUERY_NOTIFICATION  to "Query notifications",
        CAPTURE_CAMERA      to "Camera capture",
        SPEAKER_ON          to "Speaker on",
        SPEAKER_OFF         to "Speaker off",
        TOGGLE_SPEAKER      to "Toggle speaker",
        WHATSAPP_VOICE_CALL to "WhatsApp voice call",
        WHATSAPP_VIDEO_CALL to "WhatsApp video call",
        REPLY_TO_CONTACT    to "Reply to contact",
        REPLY_LAST_MESSAGE  to "Reply to last message",
    )
}
