package com.jarvis.assistant.ui.tablet

/**
 * TabletEmailVoiceIntent — a voice-originated email compose command.
 *
 * Set by [com.jarvis.assistant.tools.device.EmailTool] (tablet mode) or
 * [TabletComposeVoiceTool] when a voice command targets the email compose workflow.
 * Consumed by [TabletEmailComposeViewModel] via [TabletEmailCommandStore].
 *
 * Fields are additive — only non-blank / non-default fields are applied, so
 * "set subject to X" can be modelled as `TabletEmailVoiceIntent(subject = "X")`
 * without overwriting the existing To/Body fields.
 */
data class TabletEmailVoiceIntent(
    /** Resolved email address (may be blank if contact lookup failed). */
    val to          : String  = "",
    /** Display name as spoken (e.g. "Cath"). */
    val toName      : String  = "",
    val subject     : String  = "",
    /** Replace the full body with this text. */
    val body        : String  = "",
    /** Append to the end of the existing body (preserves what's already there). */
    val appendBody  : String  = "",
    /** True → call [TabletEmailComposeViewModel.attachSelectedFile]. */
    val attachCurrentFile: Boolean = false,
    /** True → remove the last attachment from the compose state. */
    val removeLastAttachment: Boolean = false,
    /** True → trigger the send flow (builds intent + launches). */
    val send        : Boolean = false,
    /** True → persist the current draft to [TabletEmailDraftStore]. */
    val saveDraft   : Boolean = false,
    /** True → discard draft and reset compose state. */
    val clearDraft  : Boolean = false,
    /**
     * When non-null, [TabletShell] will navigate to this destination as a
     * side-effect (e.g. navigate to Email after "email this file").
     */
    val navigateTo  : TabletDestination? = null,
    /** Epoch milliseconds when this intent was issued — used to reject stale replay. */
    val issuedAtMs  : Long = System.currentTimeMillis(),
)
