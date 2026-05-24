package com.jarvis.assistant.ui.tablet

/**
 * TabletEmailComposeState — complete state of the tablet email compose surface.
 *
 * Held in [TabletEmailComposeViewModel] which survives rotation.
 * Serialised to / from [TabletEmailDraftStore] on mutation for process-death
 * recovery.
 */
data class TabletEmailComposeState(
    val to          : String                   = "",
    val cc          : String                   = "",
    val bcc         : String                   = "",
    val subject     : String                   = "",
    val body        : String                   = "",
    val attachments : List<TabletSelectedFile> = emptyList(),
    /** True when any field has been edited since last clear/send. */
    val isDirty     : Boolean                  = false,
    /** When true, show CC/BCC fields. */
    val showCcBcc   : Boolean                  = false,
) {
    val hasRecipient   : Boolean get() = to.trim().isNotEmpty()
    val hasAttachments : Boolean get() = attachments.isNotEmpty()

    /** Build the mailto: URI query string (without attachments — those go via intent). */
    fun toMailtoQueryString(): String = buildString {
        if (cc.isNotBlank()) append("cc=${cc.trim()}&")
        if (bcc.isNotBlank()) append("bcc=${bcc.trim()}&")
        if (subject.isNotBlank()) append("subject=${subject}&")
        if (body.isNotBlank()) append("body=${body}")
    }.trimEnd('&')
}
