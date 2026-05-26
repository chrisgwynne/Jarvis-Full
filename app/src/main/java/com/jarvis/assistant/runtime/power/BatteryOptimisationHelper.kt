package com.jarvis.assistant.runtime.power

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

/**
 * BatteryOptimisationHelper — surfaces whether the app is on the system's
 * "do not optimise" list, and opens the right Settings page so the user
 * can opt in.
 *
 * # Why this matters for always-listening
 *
 * Even with `WAKE_LOCK` + a microphone foreground service, three things
 * can still pause the wake-word loop on stock Android:
 *
 *   - Doze mode (when the device is unplugged + screen-off + still).
 *   - App Standby (when an app hasn't been opened for several days).
 *   - Adaptive Battery (Pixel-specific machine-learnt restriction).
 *
 * Asking the user to whitelist the app from battery optimisation removes
 * the first two.  Adaptive Battery is per-OEM and cannot be defeated
 * programmatically — the user must disable it manually in system Settings.
 *
 * # OEM-specific aggression (NOT solvable in code)
 *
 *   Samsung   — "Device care" → "Battery" → "Sleeping apps" must NOT
 *               contain Jarvis.  Also disable "Auto-disable unused apps".
 *   Xiaomi    — "Security" → "Battery & performance" → "App battery saver"
 *               must set Jarvis to "No restrictions".  Also enable
 *               "Autostart" for the app.
 *   Huawei    — "Battery" → "App launch" → set Jarvis to manual + enable
 *               all three sub-toggles (Auto-launch, Secondary launch,
 *               Run in background).
 *   OnePlus   — "Battery" → "Battery optimization" set to "Don't optimize".
 *
 * These per-OEM lists are not addressable from app code.  The UI should
 * document them so the user can opt out manually.
 */
object BatteryOptimisationHelper {

    private const val TAG = "BatteryOptimisationHelper"

    /**
     * True when the OS reports our package is on the "ignore battery
     * optimisation" list.  Returns true on API < 23 where the concept
     * doesn't exist (so callers don't show a spurious warning).
     */
    fun isIgnoringBatteryOptimisations(context: Context): Boolean {
        return try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                ?: return true
            pm.isIgnoringBatteryOptimizations(context.packageName)
        } catch (e: Exception) {
            Log.w(TAG, "[BATTERY_OPT_QUERY_FAILED] ${e.message}")
            true   // assume best-case so we don't nag on a failed query
        }
    }

    /**
     * Open the system Settings page where the user can whitelist Jarvis
     * from battery optimisation.  We DELIBERATELY do not call the
     * `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` intent action directly —
     * Google Play has flagged that path as policy-violating for apps
     * outside a narrow allow-list, and the user-driven Settings page
     * achieves the same outcome without policy risk.
     *
     * Falls back to the general system settings if the dedicated page
     * isn't available (rare; happens on heavily customised AOSP forks).
     */
    fun openBatteryOptimisationSettings(context: Context) {
        val attempts = listOf(
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
            // Per-app page — works on Pixel and most AOSP devices.
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            ),
        )
        for (intent in attempts) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                Log.d(TAG, "[BATTERY_OPT_SETTINGS_OPENED] action=${intent.action}")
                return
            } catch (e: Exception) {
                Log.d(TAG, "[BATTERY_OPT_SETTINGS_OPEN_FAILED] action=${intent.action} ${e.message}")
            }
        }
        Log.w(TAG, "[BATTERY_OPT_SETTINGS_UNAVAILABLE] no settings page accepted the intent")
    }
}
