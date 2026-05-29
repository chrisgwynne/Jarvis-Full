package com.jarvis.assistant.auth

/**
 * Singleton that bridges MainActivity (receives the OAuth deep-link) to
 * SettingsViewModel (needs the auth code to exchange for a token).
 *
 * WHY A SINGLETON?
 * In a single-Activity Compose app the ViewModel survives config changes but
 * MainActivity does not. We can't inject the ViewModel into the Activity
 * easily without a DI framework. Instead, before launching the browser the
 * ViewModel registers a one-shot callback here; when MainActivity receives
 * the redirect it calls invoke() and clears the reference.
 *
 * The callback is intentionally nullable so a missed redirect (user backs out
 * of the browser without completing sign-in) doesn't leak any reference.
 */
object OAuthCallbackHolder {
    /** Called by MainActivity with the authorization code from the deep link. */
    var pendingCallback: ((code: String) -> Unit)? = null

    /**
     * Expected `state` nonce set by SettingsViewModel before launching the
     * browser. Validated in [invoke] to prevent auth-code injection (#50).
     */
    @Volatile var pendingState: String? = null

    /**
     * Called by MainActivity with both the authorization code and the state
     * nonce from the redirect URI.  Silently ignores the callback when the
     * state does not match the expected value (CSRF guard).
     */
    fun invoke(code: String, state: String) {
        val expected = pendingState
        pendingState = null
        if (expected == null || expected != state) return
        pendingCallback?.invoke(code)
        pendingCallback = null
    }
}
