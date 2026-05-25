package com.jarvis.assistant.phrases

object PhraseKey {
    // WAKE
    const val WAKE_ACKNOWLEDGED         = "wake.acknowledged"
    const val WAKE_NOT_FOR_ME           = "wake.not_for_me"
    const val WAKE_LISTENING            = "wake.listening"
    const val WAKE_TIMEOUT              = "wake.timeout"

    // CONVERSATION
    const val CONV_CLARIFICATION        = "conversation.clarification"
    const val CONV_DIDNT_CATCH          = "conversation.didnt_catch"
    const val CONV_THINKING             = "conversation.thinking"
    const val CONV_CONTINUE             = "conversation.continue"

    // CONFIRMATIONS
    const val CONFIRM_REQUIRED          = "command.confirmation_required"
    const val CONFIRM_COMPLETED         = "command.completed"
    const val CONFIRM_FAILED            = "command.failed"
    const val CONFIRM_CANCELLED         = "command.cancelled"

    // MESSAGING
    const val WHATSAPP_ASK_RECIPIENT    = "whatsapp.ask_recipient"
    const val WHATSAPP_ASK_MESSAGE      = "whatsapp.ask_message"
    const val WHATSAPP_READY_TO_SEND    = "whatsapp.ready_to_send"
    const val WHATSAPP_SENT             = "whatsapp.sent"
    const val WHATSAPP_NOT_INSTALLED    = "whatsapp.not_installed"
    const val SMS_SENT                  = "sms.sent"
    const val SMS_FAILED                = "sms.failed"
    const val REPLY_ASK_BODY            = "reply.ask_body"
    const val REPLY_SENT                = "reply.sent"
    const val REPLY_NO_RECENT           = "reply.no_recent_message"

    // CALLS
    const val CALL_PLACING              = "call.placing"
    const val CALL_ENDED                = "call.ended"
    const val CALL_INCOMING             = "call.incoming"
    const val CALL_NO_CONTACT           = "call.no_contact"

    // HOME ASSISTANT
    const val HA_DEVICE_NOT_FOUND       = "homeassistant.device_not_found"
    const val HA_ACTION_SUCCESS         = "homeassistant.action_success"
    const val HA_ACTION_FAILED          = "homeassistant.action_failed"
    const val HA_UNAVAILABLE            = "homeassistant.unavailable"

    // NAVIGATION
    const val NAV_ROUTE_STARTED         = "navigation.route_started"
    const val NAV_NO_DESTINATION        = "navigation.no_destination"
    const val NAV_MAPS_NOT_AVAILABLE    = "navigation.maps_not_available"

    // CAMERA
    const val CAMERA_PHOTO_TAKEN        = "camera.photo_taken"
    const val CAMERA_FAILED             = "camera.failed"
    const val CAMERA_NO_PERMISSION      = "camera.no_permission"

    // CALENDAR
    const val CAL_EVENT_CREATED         = "calendar.event_created"
    const val CAL_NO_EVENTS             = "calendar.no_events"
    const val CAL_NEXT_EVENT            = "calendar.next_event"

    // REMINDERS
    const val REMINDER_SET              = "reminder.set"
    const val REMINDER_TRIGGERED        = "reminder.triggered"
    const val REMINDER_CANCELLED        = "reminder.cancelled"
    const val REMINDER_LOCATION         = "reminder.location"

    // MAC HANDOFF
    const val MAC_HANDOFF_SENT          = "mac.handoff_sent"
    const val MAC_TASK_QUEUED           = "mac.task_queued"
    const val MAC_UNAVAILABLE           = "mac.unavailable"
    const val MAC_RESPONSE_ARRIVED      = "mac.response_arrived"
    const val MAC_TASK_COMPLETED        = "mac.task_completed"

    // PROACTIVITY
    const val PROACTIVE_BATTERY_LOW     = "proactive.battery_low"
    const val PROACTIVE_REMINDER        = "proactive.reminder"
    const val PROACTIVE_MISSED_CALL     = "proactive.missed_call"
    const val PROACTIVE_NOTIFICATION    = "proactive.notification"

    // ERRORS & FALLBACKS
    const val FALLBACK_UNKNOWN          = "fallback.unknown"
    const val FALLBACK_RETRY            = "fallback.retry"
    const val FALLBACK_UNSUPPORTED      = "fallback.unsupported"
    const val FALLBACK_OFFLINE          = "fallback.offline"
    const val IDLE_TIMEOUT              = "idle.timeout"

    // DIAGNOSTICS
    const val DIAG_PERMISSION_REVOKED   = "diagnostics.permission_revoked"
    const val DIAG_SERVICE_RESTARTED    = "diagnostics.service_restarted"

    // FAILURES — these mirror FailurePhrases.kt and are now in the editable registry
    const val FAILURE_GENERIC                   = "failure.generic"
    const val FAILURE_SOMETHING_WENT_WRONG      = "failure.something_went_wrong"
    const val FAILURE_AUDIO_UNAVAILABLE         = "failure.audio_unavailable"
    const val FAILURE_CAMERA_UNAVAILABLE        = "failure.camera_unavailable"
    const val FAILURE_NO_FLASH                  = "failure.no_flash"
    const val FAILURE_MEDIA_CONTROL             = "failure.media_control"
    const val FAILURE_FLASHLIGHT                = "failure.flashlight"
    const val FAILURE_RECORDING                 = "failure.recording"
    const val FAILURE_TRANSCRIPTION             = "failure.transcription"
    const val FAILURE_IMAGE_ANALYSIS            = "failure.image_analysis"
    const val FAILURE_IMAGE_GENERATION          = "failure.image_generation"
    const val FAILURE_CAMERA_CAPTURE            = "failure.camera_capture"
    const val FAILURE_EXPORT                    = "failure.export"
    const val FAILURE_EMAIL_APP                 = "failure.email_app"
    const val FAILURE_TIMER                     = "failure.timer"
    const val FAILURE_TIMER_DURATION            = "failure.timer_duration"
    const val FAILURE_ALARM                     = "failure.alarm"
    const val FAILURE_CALL                      = "failure.call"
    const val FAILURE_SMS                       = "failure.sms"
    const val FAILURE_FIND_PHONE_RINGER         = "failure.find_phone_ringer"
    const val FAILURE_APP_NOT_INSTALLED         = "failure.app_not_installed"
}
