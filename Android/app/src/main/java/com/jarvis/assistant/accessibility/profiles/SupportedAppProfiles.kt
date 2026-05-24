package com.jarvis.assistant.accessibility.profiles

/**
 * SupportedAppProfiles — registry of app-specific [AppProfile] handlers.
 *
 * Resolution order:
 *   1. Exact package match against a known profile.
 *   2. [GenericAndroidProfile] as the universal fallback.
 *
 * [AppControlService] calls [forPackage] with the foreground package and
 * dispatches to the result.  If the profile returns [AppActionResult.NotSupported],
 * the service falls through to [GenericAndroidProfile] directly.
 */
object SupportedAppProfiles {

    private val all: List<AppProfile> = listOf(
        GoogleMapsProfile,
        WhatsAppProfile,
    )

    fun forPackage(packageName: String?): AppProfile {
        if (!packageName.isNullOrBlank()) {
            val match = all.firstOrNull { packageName in it.packages }
            if (match != null) return match
        }
        return GenericAndroidProfile
    }
}
