package com.jarvis.assistant.phrases

enum class PhraseCategory(val displayName: String) {
    WAKE("Wake"),
    CONVERSATION("Conversation"),
    CONFIRMATIONS("Confirmations"),
    MESSAGING("Messaging"),
    CALLS("Calls"),
    HOME_ASSISTANT("Home Assistant"),
    NAVIGATION("Navigation"),
    CAMERA("Camera"),
    CALENDAR("Calendar"),
    REMINDERS("Reminders"),
    MAC_HANDOFF("Mac Handoff"),
    PROACTIVITY("Proactivity"),
    ERRORS("Errors & Fallbacks"),
    DIAGNOSTICS("Debug / Diagnostics"),
}
