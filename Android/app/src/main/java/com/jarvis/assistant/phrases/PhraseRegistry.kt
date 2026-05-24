package com.jarvis.assistant.phrases

/**
 * PhraseRegistry — compile-time default phrase map.
 *
 * Every key in PhraseKey is present here. The text values use {var} tokens
 * where runtime substitution is appropriate; PhraseResolver handles the
 * replacement. Variants on WAKE_ACKNOWLEDGED give the wake response some
 * natural variety without any user configuration required.
 */
object PhraseRegistry {

    val defaults: Map<String, PhraseEntry> = buildMap {

        // ── WAKE ─────────────────────────────────────────────────────────────

        put(
            PhraseKey.WAKE_ACKNOWLEDGED,
            PhraseEntry(
                key          = PhraseKey.WAKE_ACKNOWLEDGED,
                category     = PhraseCategory.WAKE,
                defaultText  = "Yeah?",
                description  = "Spoken immediately after the wake word is detected. No vars.",
                availableVars = emptyList(),
                variants     = listOf(
                    PhraseVariant(text = "Yeah?",       isDefault = true),
                    PhraseVariant(text = "Yes?"),
                    PhraseVariant(text = "Mm?"),
                    PhraseVariant(text = "Go ahead."),
                    PhraseVariant(text = "Listening."),
                ),
            )
        )

        put(
            PhraseKey.WAKE_NOT_FOR_ME,
            PhraseEntry(
                key          = PhraseKey.WAKE_NOT_FOR_ME,
                category     = PhraseCategory.WAKE,
                defaultText  = "",
                description  = "Played silently when the wake word fires but the utterance is " +
                               "directed at someone else. Empty by default (no speech).",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.WAKE_LISTENING,
            PhraseEntry(
                key          = PhraseKey.WAKE_LISTENING,
                category     = PhraseCategory.WAKE,
                defaultText  = "",
                description  = "Optional confirmation that Jarvis is actively listening. " +
                               "Empty by default — the UI orb handles this visually.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.WAKE_TIMEOUT,
            PhraseEntry(
                key          = PhraseKey.WAKE_TIMEOUT,
                category     = PhraseCategory.WAKE,
                defaultText  = "",
                description  = "Spoken when the wake session times out with no speech detected. " +
                               "Empty by default.",
                availableVars = emptyList(),
            )
        )

        // ── CONVERSATION ──────────────────────────────────────────────────────

        put(
            PhraseKey.CONV_CLARIFICATION,
            PhraseEntry(
                key          = PhraseKey.CONV_CLARIFICATION,
                category     = PhraseCategory.CONVERSATION,
                defaultText  = "What did you mean by that?",
                description  = "Spoken when Jarvis needs the user to clarify an ambiguous request.",
                availableVars = emptyList(),
                variants     = listOf(
                    PhraseVariant(text = "What did you mean by that?", isDefault = true),
                    PhraseVariant(text = "Could you be more specific?"),
                    PhraseVariant(text = "I'm not quite sure what you're after — can you rephrase?"),
                ),
            )
        )

        put(
            PhraseKey.CONV_DIDNT_CATCH,
            PhraseEntry(
                key          = PhraseKey.CONV_DIDNT_CATCH,
                category     = PhraseCategory.CONVERSATION,
                defaultText  = "Didn't catch that.",
                description  = "Spoken when speech recognition returns empty or low-confidence audio.",
                availableVars = emptyList(),
                variants     = listOf(
                    PhraseVariant(text = "Didn't catch that.", isDefault = true),
                    PhraseVariant(text = "Sorry, didn't get that."),
                    PhraseVariant(text = "Say that again?"),
                ),
            )
        )

        put(
            PhraseKey.CONV_THINKING,
            PhraseEntry(
                key          = PhraseKey.CONV_THINKING,
                category     = PhraseCategory.CONVERSATION,
                defaultText  = "",
                description  = "Optional filler spoken while waiting for the LLM response. " +
                               "Empty by default — latency is typically short enough.",
                availableVars = emptyList(),
                variants     = listOf(
                    PhraseVariant(text = "", isDefault = true, isEnabled = false),
                    PhraseVariant(text = "One sec.", isEnabled = false),
                    PhraseVariant(text = "Let me check.", isEnabled = false),
                ),
            )
        )

        put(
            PhraseKey.CONV_CONTINUE,
            PhraseEntry(
                key          = PhraseKey.CONV_CONTINUE,
                category     = PhraseCategory.CONVERSATION,
                defaultText  = "Go on.",
                description  = "Spoken to invite the user to continue speaking after a barge-in pause.",
                availableVars = emptyList(),
                variants     = listOf(
                    PhraseVariant(text = "Go on.",       isDefault = true),
                    PhraseVariant(text = "Continue."),
                    PhraseVariant(text = "I'm listening."),
                ),
            )
        )

        // ── CONFIRMATIONS ─────────────────────────────────────────────────────

        put(
            PhraseKey.CONFIRM_REQUIRED,
            PhraseEntry(
                key          = PhraseKey.CONFIRM_REQUIRED,
                category     = PhraseCategory.CONFIRMATIONS,
                defaultText  = "Just to confirm — {action}. Go ahead?",
                description  = "Spoken before executing a destructive or irreversible action. " +
                               "Vars: {action} — human description of what will happen.",
                availableVars = listOf("action"),
            )
        )

        put(
            PhraseKey.CONFIRM_COMPLETED,
            PhraseEntry(
                key          = PhraseKey.CONFIRM_COMPLETED,
                category     = PhraseCategory.CONFIRMATIONS,
                defaultText  = "Done.",
                description  = "Spoken after a command completes successfully. No vars.",
                availableVars = emptyList(),
                variants     = listOf(
                    PhraseVariant(text = "Done.",    isDefault = true),
                    PhraseVariant(text = "Got it."),
                    PhraseVariant(text = "All set."),
                ),
            )
        )

        put(
            PhraseKey.CONFIRM_FAILED,
            PhraseEntry(
                key          = PhraseKey.CONFIRM_FAILED,
                category     = PhraseCategory.CONFIRMATIONS,
                defaultText  = "That didn't work. {error}",
                description  = "Spoken when a command fails. Vars: {error} — brief error description.",
                availableVars = listOf("error"),
            )
        )

        put(
            PhraseKey.CONFIRM_CANCELLED,
            PhraseEntry(
                key          = PhraseKey.CONFIRM_CANCELLED,
                category     = PhraseCategory.CONFIRMATIONS,
                defaultText  = "Cancelled.",
                description  = "Spoken when the user cancels a pending action. No vars.",
                availableVars = emptyList(),
            )
        )

        // ── MESSAGING ─────────────────────────────────────────────────────────

        put(
            PhraseKey.WHATSAPP_ASK_RECIPIENT,
            PhraseEntry(
                key          = PhraseKey.WHATSAPP_ASK_RECIPIENT,
                category     = PhraseCategory.MESSAGING,
                defaultText  = "Who do you want to message?",
                description  = "Spoken when a WhatsApp send intent has no recipient. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.WHATSAPP_ASK_MESSAGE,
            PhraseEntry(
                key          = PhraseKey.WHATSAPP_ASK_MESSAGE,
                category     = PhraseCategory.MESSAGING,
                defaultText  = "What should I say to {contact}?",
                description  = "Spoken to ask for the message body. Vars: {contact}.",
                availableVars = listOf("contact"),
            )
        )

        put(
            PhraseKey.WHATSAPP_READY_TO_SEND,
            PhraseEntry(
                key          = PhraseKey.WHATSAPP_READY_TO_SEND,
                category     = PhraseCategory.MESSAGING,
                defaultText  = "Ready to send to {contact}: \"{message}\". Send it?",
                description  = "Spoken to confirm message content before sending. Vars: {contact}, {message}.",
                availableVars = listOf("contact", "message"),
            )
        )

        put(
            PhraseKey.WHATSAPP_SENT,
            PhraseEntry(
                key          = PhraseKey.WHATSAPP_SENT,
                category     = PhraseCategory.MESSAGING,
                defaultText  = "Sent to {contact}.",
                description  = "Spoken after a WhatsApp message is sent. Vars: {contact}.",
                availableVars = listOf("contact"),
            )
        )

        put(
            PhraseKey.WHATSAPP_NOT_INSTALLED,
            PhraseEntry(
                key          = PhraseKey.WHATSAPP_NOT_INSTALLED,
                category     = PhraseCategory.MESSAGING,
                defaultText  = "WhatsApp isn't installed.",
                description  = "Spoken when WhatsApp is not found on the device. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.SMS_SENT,
            PhraseEntry(
                key          = PhraseKey.SMS_SENT,
                category     = PhraseCategory.MESSAGING,
                defaultText  = "Text sent to {contact}.",
                description  = "Spoken after an SMS is dispatched. Vars: {contact}.",
                availableVars = listOf("contact"),
            )
        )

        put(
            PhraseKey.SMS_FAILED,
            PhraseEntry(
                key          = PhraseKey.SMS_FAILED,
                category     = PhraseCategory.MESSAGING,
                defaultText  = "Couldn't send the text. {error}",
                description  = "Spoken when SMS dispatch fails. Vars: {error}.",
                availableVars = listOf("error"),
            )
        )

        put(
            PhraseKey.REPLY_ASK_BODY,
            PhraseEntry(
                key          = PhraseKey.REPLY_ASK_BODY,
                category     = PhraseCategory.MESSAGING,
                defaultText  = "What do you want to say to {contact}?",
                description  = "Spoken to collect a reply body when replying to a message. Vars: {contact}.",
                availableVars = listOf("contact"),
            )
        )

        put(
            PhraseKey.REPLY_SENT,
            PhraseEntry(
                key          = PhraseKey.REPLY_SENT,
                category     = PhraseCategory.MESSAGING,
                defaultText  = "Reply sent.",
                description  = "Spoken after a reply is sent successfully. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.REPLY_NO_RECENT,
            PhraseEntry(
                key          = PhraseKey.REPLY_NO_RECENT,
                category     = PhraseCategory.MESSAGING,
                defaultText  = "No recent message to reply to.",
                description  = "Spoken when a reply is requested but no recent message is in context. No vars.",
                availableVars = emptyList(),
            )
        )

        // ── CALLS ─────────────────────────────────────────────────────────────

        put(
            PhraseKey.CALL_PLACING,
            PhraseEntry(
                key          = PhraseKey.CALL_PLACING,
                category     = PhraseCategory.CALLS,
                defaultText  = "Calling {contact}.",
                description  = "Spoken as a phone call is being placed. Vars: {contact}.",
                availableVars = listOf("contact"),
            )
        )

        put(
            PhraseKey.CALL_ENDED,
            PhraseEntry(
                key          = PhraseKey.CALL_ENDED,
                category     = PhraseCategory.CALLS,
                defaultText  = "Call ended.",
                description  = "Spoken after a call is terminated. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.CALL_INCOMING,
            PhraseEntry(
                key          = PhraseKey.CALL_INCOMING,
                category     = PhraseCategory.CALLS,
                defaultText  = "Incoming call from {contact}.",
                description  = "Spoken when an incoming call is detected. Vars: {contact}.",
                availableVars = listOf("contact"),
            )
        )

        put(
            PhraseKey.CALL_NO_CONTACT,
            PhraseEntry(
                key          = PhraseKey.CALL_NO_CONTACT,
                category     = PhraseCategory.CALLS,
                defaultText  = "I couldn't find a contact matching that.",
                description  = "Spoken when a call intent has no matching contact. No vars.",
                availableVars = emptyList(),
            )
        )

        // ── HOME ASSISTANT ────────────────────────────────────────────────────

        put(
            PhraseKey.HA_DEVICE_NOT_FOUND,
            PhraseEntry(
                key          = PhraseKey.HA_DEVICE_NOT_FOUND,
                category     = PhraseCategory.HOME_ASSISTANT,
                defaultText  = "I couldn't find a device called {device}.",
                description  = "Spoken when the requested HA entity cannot be matched. Vars: {device}.",
                availableVars = listOf("device"),
            )
        )

        put(
            PhraseKey.HA_ACTION_SUCCESS,
            PhraseEntry(
                key          = PhraseKey.HA_ACTION_SUCCESS,
                category     = PhraseCategory.HOME_ASSISTANT,
                defaultText  = "{action} — done.",
                description  = "Spoken after a Home Assistant action completes. Vars: {action}, {device}, {room}.",
                availableVars = listOf("action", "device", "room"),
                variants     = listOf(
                    PhraseVariant(text = "{action} — done.",  isDefault = true),
                    PhraseVariant(text = "Done."),
                    PhraseVariant(text = "{device} updated."),
                ),
            )
        )

        put(
            PhraseKey.HA_ACTION_FAILED,
            PhraseEntry(
                key          = PhraseKey.HA_ACTION_FAILED,
                category     = PhraseCategory.HOME_ASSISTANT,
                defaultText  = "That didn't work. Home Assistant returned an error.",
                description  = "Spoken when a HA action call fails. Vars: {error}, {device}.",
                availableVars = listOf("error", "device"),
            )
        )

        put(
            PhraseKey.HA_UNAVAILABLE,
            PhraseEntry(
                key          = PhraseKey.HA_UNAVAILABLE,
                category     = PhraseCategory.HOME_ASSISTANT,
                defaultText  = "Home Assistant isn't reachable right now.",
                description  = "Spoken when the HA instance cannot be reached. No vars.",
                availableVars = emptyList(),
            )
        )

        // ── NAVIGATION ────────────────────────────────────────────────────────

        put(
            PhraseKey.NAV_ROUTE_STARTED,
            PhraseEntry(
                key          = PhraseKey.NAV_ROUTE_STARTED,
                category     = PhraseCategory.NAVIGATION,
                defaultText  = "Navigation started to {destination}.",
                description  = "Spoken when Maps begins routing. Vars: {destination}.",
                availableVars = listOf("destination"),
            )
        )

        put(
            PhraseKey.NAV_NO_DESTINATION,
            PhraseEntry(
                key          = PhraseKey.NAV_NO_DESTINATION,
                category     = PhraseCategory.NAVIGATION,
                defaultText  = "Where do you want to go?",
                description  = "Spoken when a navigation intent has no destination. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.NAV_MAPS_NOT_AVAILABLE,
            PhraseEntry(
                key          = PhraseKey.NAV_MAPS_NOT_AVAILABLE,
                category     = PhraseCategory.NAVIGATION,
                defaultText  = "Maps isn't available on this device.",
                description  = "Spoken when no maps application can be launched. No vars.",
                availableVars = emptyList(),
            )
        )

        // ── CAMERA ────────────────────────────────────────────────────────────

        put(
            PhraseKey.CAMERA_PHOTO_TAKEN,
            PhraseEntry(
                key          = PhraseKey.CAMERA_PHOTO_TAKEN,
                category     = PhraseCategory.CAMERA,
                defaultText  = "Photo taken.",
                description  = "Spoken after a photo is captured. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.CAMERA_FAILED,
            PhraseEntry(
                key          = PhraseKey.CAMERA_FAILED,
                category     = PhraseCategory.CAMERA,
                defaultText  = "Couldn't take the photo. {error}",
                description  = "Spoken when the camera capture fails. Vars: {error}.",
                availableVars = listOf("error"),
            )
        )

        put(
            PhraseKey.CAMERA_NO_PERMISSION,
            PhraseEntry(
                key          = PhraseKey.CAMERA_NO_PERMISSION,
                category     = PhraseCategory.CAMERA,
                defaultText  = "Camera permission is needed for that.",
                description  = "Spoken when camera permission has not been granted. No vars.",
                availableVars = emptyList(),
            )
        )

        // ── CALENDAR ──────────────────────────────────────────────────────────

        put(
            PhraseKey.CAL_EVENT_CREATED,
            PhraseEntry(
                key          = PhraseKey.CAL_EVENT_CREATED,
                category     = PhraseCategory.CALENDAR,
                defaultText  = "Event added for {time}.",
                description  = "Spoken after a calendar event is created. Vars: {label}, {time}.",
                availableVars = listOf("label", "time"),
            )
        )

        put(
            PhraseKey.CAL_NO_EVENTS,
            PhraseEntry(
                key          = PhraseKey.CAL_NO_EVENTS,
                category     = PhraseCategory.CALENDAR,
                defaultText  = "Nothing on the calendar.",
                description  = "Spoken when a calendar query returns no events. No vars.",
                availableVars = emptyList(),
                variants     = listOf(
                    PhraseVariant(text = "Nothing on the calendar.",        isDefault = true),
                    PhraseVariant(text = "Your schedule is clear."),
                    PhraseVariant(text = "No events found."),
                ),
            )
        )

        put(
            PhraseKey.CAL_NEXT_EVENT,
            PhraseEntry(
                key          = PhraseKey.CAL_NEXT_EVENT,
                category     = PhraseCategory.CALENDAR,
                defaultText  = "Next up: {label} at {time}.",
                description  = "Spoken to describe the next upcoming calendar event. Vars: {label}, {time}.",
                availableVars = listOf("label", "time"),
            )
        )

        // ── REMINDERS ─────────────────────────────────────────────────────────

        put(
            PhraseKey.REMINDER_SET,
            PhraseEntry(
                key          = PhraseKey.REMINDER_SET,
                category     = PhraseCategory.REMINDERS,
                defaultText  = "Reminder set for {time}.",
                description  = "Spoken after a reminder is scheduled. Vars: {label}, {time}.",
                availableVars = listOf("label", "time"),
            )
        )

        put(
            PhraseKey.REMINDER_TRIGGERED,
            PhraseEntry(
                key          = PhraseKey.REMINDER_TRIGGERED,
                category     = PhraseCategory.REMINDERS,
                defaultText  = "{label}",
                description  = "Spoken when a reminder fires. Vars: {label} — the reminder text.",
                availableVars = listOf("label"),
            )
        )

        put(
            PhraseKey.REMINDER_CANCELLED,
            PhraseEntry(
                key          = PhraseKey.REMINDER_CANCELLED,
                category     = PhraseCategory.REMINDERS,
                defaultText  = "Reminder cancelled.",
                description  = "Spoken after a reminder is removed. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.REMINDER_LOCATION,
            PhraseEntry(
                key          = PhraseKey.REMINDER_LOCATION,
                category     = PhraseCategory.REMINDERS,
                defaultText  = "Reminder: {label}",
                description  = "Spoken when a location-based reminder triggers. Vars: {label}, {destination}.",
                availableVars = listOf("label", "destination"),
            )
        )

        // ── MAC HANDOFF ───────────────────────────────────────────────────────

        put(
            PhraseKey.MAC_HANDOFF_SENT,
            PhraseEntry(
                key          = PhraseKey.MAC_HANDOFF_SENT,
                category     = PhraseCategory.MAC_HANDOFF,
                defaultText  = "Sent to Mac.",
                description  = "Spoken after a handoff payload is transmitted to the Mac bridge. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.MAC_TASK_QUEUED,
            PhraseEntry(
                key          = PhraseKey.MAC_TASK_QUEUED,
                category     = PhraseCategory.MAC_HANDOFF,
                defaultText  = "Queued for the Mac. I'll let you know when it's done.",
                description  = "Spoken when a Mac task is queued because the Mac is offline. Vars: {task}.",
                availableVars = listOf("task"),
            )
        )

        put(
            PhraseKey.MAC_UNAVAILABLE,
            PhraseEntry(
                key          = PhraseKey.MAC_UNAVAILABLE,
                category     = PhraseCategory.MAC_HANDOFF,
                defaultText  = "Mac isn't reachable right now. I'll send it when it's back online.",
                description  = "Spoken when the Mac bridge cannot be contacted. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.MAC_RESPONSE_ARRIVED,
            PhraseEntry(
                key          = PhraseKey.MAC_RESPONSE_ARRIVED,
                category     = PhraseCategory.MAC_HANDOFF,
                defaultText  = "Response from Mac: {task}",
                description  = "Spoken when the Mac returns a result for a queued task. Vars: {task}.",
                availableVars = listOf("task"),
            )
        )

        put(
            PhraseKey.MAC_TASK_COMPLETED,
            PhraseEntry(
                key          = PhraseKey.MAC_TASK_COMPLETED,
                category     = PhraseCategory.MAC_HANDOFF,
                defaultText  = "Done on the Mac.",
                description  = "Spoken when the Mac confirms a task completed. No vars.",
                availableVars = emptyList(),
            )
        )

        // ── PROACTIVITY ───────────────────────────────────────────────────────

        put(
            PhraseKey.PROACTIVE_BATTERY_LOW,
            PhraseEntry(
                key          = PhraseKey.PROACTIVE_BATTERY_LOW,
                category     = PhraseCategory.PROACTIVITY,
                defaultText  = "Battery at {percent} percent.",
                description  = "Spoken proactively when battery drops below threshold. Vars: {percent}.",
                availableVars = listOf("percent"),
            )
        )

        put(
            PhraseKey.PROACTIVE_REMINDER,
            PhraseEntry(
                key          = PhraseKey.PROACTIVE_REMINDER,
                category     = PhraseCategory.PROACTIVITY,
                defaultText  = "Heads up — {label}",
                description  = "Spoken as a proactive reminder nudge. Vars: {label}, {time}.",
                availableVars = listOf("label", "time"),
            )
        )

        put(
            PhraseKey.PROACTIVE_MISSED_CALL,
            PhraseEntry(
                key          = PhraseKey.PROACTIVE_MISSED_CALL,
                category     = PhraseCategory.PROACTIVITY,
                defaultText  = "You missed a call from {contact}.",
                description  = "Spoken proactively when a missed call is detected. Vars: {contact}, {time}.",
                availableVars = listOf("contact", "time"),
            )
        )

        put(
            PhraseKey.PROACTIVE_NOTIFICATION,
            PhraseEntry(
                key          = PhraseKey.PROACTIVE_NOTIFICATION,
                category     = PhraseCategory.PROACTIVITY,
                defaultText  = "{app}: {label}",
                description  = "Spoken when surfacing a notification proactively. Vars: {app}, {label}.",
                availableVars = listOf("app", "label"),
            )
        )

        // ── ERRORS & FALLBACKS ────────────────────────────────────────────────

        put(
            PhraseKey.FALLBACK_UNKNOWN,
            PhraseEntry(
                key          = PhraseKey.FALLBACK_UNKNOWN,
                category     = PhraseCategory.ERRORS,
                defaultText  = "I'm not sure how to do that.",
                description  = "Spoken when no intent matches and no tool applies. No vars.",
                availableVars = emptyList(),
                variants     = listOf(
                    PhraseVariant(text = "I'm not sure how to do that.",           isDefault = true),
                    PhraseVariant(text = "Not something I can do right now."),
                    PhraseVariant(text = "That one's beyond me at the moment."),
                ),
            )
        )

        put(
            PhraseKey.FALLBACK_RETRY,
            PhraseEntry(
                key          = PhraseKey.FALLBACK_RETRY,
                category     = PhraseCategory.ERRORS,
                defaultText  = "Something went wrong — try again.",
                description  = "Spoken when a transient error occurs and the user should retry. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.FALLBACK_UNSUPPORTED,
            PhraseEntry(
                key          = PhraseKey.FALLBACK_UNSUPPORTED,
                category     = PhraseCategory.ERRORS,
                defaultText  = "That's not supported yet.",
                description  = "Spoken when the user requests a feature not yet implemented. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.FALLBACK_OFFLINE,
            PhraseEntry(
                key          = PhraseKey.FALLBACK_OFFLINE,
                category     = PhraseCategory.ERRORS,
                defaultText  = "I need a connection for that.",
                description  = "Spoken when a network-required action is attempted while offline. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.IDLE_TIMEOUT,
            PhraseEntry(
                key          = PhraseKey.IDLE_TIMEOUT,
                category     = PhraseCategory.ERRORS,
                defaultText  = "",
                description  = "Spoken when the session idles out with no activity. Empty by default.",
                availableVars = emptyList(),
            )
        )

        // ── DIAGNOSTICS ───────────────────────────────────────────────────────

        put(
            PhraseKey.DIAG_PERMISSION_REVOKED,
            PhraseEntry(
                key          = PhraseKey.DIAG_PERMISSION_REVOKED,
                category     = PhraseCategory.DIAGNOSTICS,
                defaultText  = "A required permission was revoked. Some features may not work.",
                description  = "Spoken when a runtime permission is detected as revoked. No vars.",
                availableVars = emptyList(),
            )
        )

        put(
            PhraseKey.DIAG_SERVICE_RESTARTED,
            PhraseEntry(
                key          = PhraseKey.DIAG_SERVICE_RESTARTED,
                category     = PhraseCategory.DIAGNOSTICS,
                defaultText  = "",
                description  = "Spoken after the Jarvis service restarts unexpectedly. Empty by default.",
                availableVars = emptyList(),
            )
        )
    }

    /** All keys that belong to [category], in insertion order. */
    fun categoryKeys(category: PhraseCategory): List<String> =
        defaults.values
            .filter { it.category == category }
            .map { it.key }

    /** All registered default keys. */
    fun allKeys(): Set<String> = defaults.keys
}
