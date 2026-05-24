package com.jarvis.assistant.runtime.power

import android.content.Context
import android.os.PowerManager
import android.util.Log

/**
 * ListeningWakeLockGuard — partial-wake-lock owner used by [JarvisRuntime]
 * while the wake-word detector is actively listening.
 *
 * # Why this exists
 *
 * The foreground microphone service contract (FGS_TYPE=microphone) is meant
 * to keep the CPU active while `AudioRecord` is reading.  In practice three
 * paths can still pause the wake-word loop:
 *
 *   1. The gap between `AudioRecord.stop()` (after wake detection / barge-in)
 *      and the next `start()` — no audio capture means no CPU guarantee.
 *   2. Doze maintenance windows on stock Android — the platform pauses
 *      services briefly even with FGS_TYPE=microphone.
 *   3. OEM battery-savers (Samsung "Sleeping apps", Xiaomi MIUI optimisation,
 *      Huawei "Protected apps") ignore the AOSP rule entirely.
 *
 * Holding a partial wake-lock for the duration of "Jarvis should be
 * listening" closes all three holes.  The lock is released as soon as the
 * user asks Jarvis to stop listening, or another app takes audio focus.
 *
 * # Contract
 *
 *   acquire()   — idempotent.  After it returns, [isHeld] is true.
 *   release()   — idempotent.  After it returns, [isHeld] is false.
 *
 *   The implementation uses [PowerManager.PARTIAL_WAKE_LOCK] which is the
 *   cheapest lock that keeps the CPU running.  It does NOT keep the screen
 *   on, does NOT keep WiFi awake, does NOT prevent the user's phone from
 *   locking.  It costs ~1–2 %/hour on a modern device — far less than a
 *   constantly-failing voice assistant costs the user in patience.
 *
 * # Tag
 *
 *   The tag string is read by `dumpsys power` and `adb shell dumpsys power`
 *   — keep it human-readable so leaked locks are easy to spot during
 *   debugging.  Android Studio's Power Profiler also surfaces it.
 *
 * # Timeout safety
 *
 *   We never specify a timeout when acquiring.  An always-listening
 *   assistant has no natural deadline — the only correct release moment is
 *   when the user explicitly asks Jarvis to stop, or the service is torn
 *   down.  [release] is wired into both lifecycle paths in [JarvisRuntime].
 */
class ListeningWakeLockGuard(context: Context) {

    companion object {
        private const val TAG = "ListeningWakeLockGuard"
        /** Visible in `dumpsys power` — keep recognisable. */
        const val LOCK_TAG: String = "Jarvis::WakeWordListening"
    }

    private val powerManager: PowerManager =
        context.applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager

    @Volatile private var lock: PowerManager.WakeLock? = null

    /** True while a wake-lock is currently held by this guard. */
    val isHeld: Boolean
        get() = lock?.isHeld == true

    /**
     * Acquire the lock if not already held.  Safe to call repeatedly — only
     * the first call has an effect.  Returns true if a lock is now held
     * (whether newly acquired or already in place).
     */
    @Synchronized
    fun acquire(): Boolean {
        val existing = lock
        if (existing != null && existing.isHeld) return true
        return try {
            val newLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                LOCK_TAG,
            ).apply {
                // setReferenceCounted(false) so a stray double-acquire never
                // creates a balance that needs an equal number of releases.
                setReferenceCounted(false)
                acquire()
            }
            lock = newLock
            Log.d(TAG, "[WAKE_LOCK_ACQUIRED] tag=$LOCK_TAG")
            true
        } catch (e: Exception) {
            Log.w(TAG, "[WAKE_LOCK_ACQUIRE_FAILED] ${e.message}")
            false
        }
    }

    /**
     * Release the lock if currently held.  Safe to call repeatedly and from
     * any thread.  Catches any exception so a misbehaving PowerManager
     * implementation can never crash the runtime tear-down path.
     */
    @Synchronized
    fun release() {
        val existing = lock ?: return
        lock = null
        try {
            if (existing.isHeld) {
                existing.release()
                Log.d(TAG, "[WAKE_LOCK_RELEASED] tag=$LOCK_TAG")
            }
        } catch (e: Exception) {
            // Already-released wake-locks throw on second release on some
            // OEM builds.  Swallow — we just want the lock gone.
            Log.w(TAG, "[WAKE_LOCK_RELEASE_THREW] ${e.message}")
        }
    }
}
