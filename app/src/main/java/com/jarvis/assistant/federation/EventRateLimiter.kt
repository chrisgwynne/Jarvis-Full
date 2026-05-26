package com.jarvis.assistant.federation

import android.util.Log
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "EventRateLimiter"

/**
 * Configuration for a token-bucket rate limiter.
 *
 * @param maxTokens     Maximum burst capacity — the bucket starts full.
 * @param refillRatePerMinute  Tokens added per minute (fractional tokens are tracked).
 */
data class RateLimitConfig(
    val maxTokens: Int = 5,
    val refillRatePerMinute: Int = 2,
)

/** Default rate-limit configs keyed by message type simple name. */
object DefaultRateLimits {
    val BATTERY_EVENT      = RateLimitConfig(maxTokens = 3,  refillRatePerMinute = 1)
    val LOCATION_EVENT     = RateLimitConfig(maxTokens = 10, refillRatePerMinute = 4)
    val NOTIFICATION_EVENT = RateLimitConfig(maxTokens = 20, refillRatePerMinute = 10)
    val VOICE_TRANSCRIPT   = RateLimitConfig(maxTokens = 30, refillRatePerMinute = 20)
    val DEFAULT            = RateLimitConfig(maxTokens = 10, refillRatePerMinute = 5)
}

/**
 * Token-bucket rate limiter keyed by arbitrary string keys.
 *
 * Thread-safe: each [TokenBucket] guards its own state with [synchronized].
 * The map itself is a [ConcurrentHashMap] so key creation is also safe.
 *
 * Usage:
 * ```
 * val limiter = EventRateLimiter()
 * if (limiter.isAllowed("DeviceStateEvent", DefaultRateLimits.BATTERY_EVENT)) {
 *     // send event
 * }
 * ```
 */
class EventRateLimiter {

    private val buckets = ConcurrentHashMap<String, TokenBucket>()

    /**
     * Returns true if the event identified by [key] is within the rate limit
     * defined by [config], and consumes one token.  Returns false (and does NOT
     * consume a token) when the bucket is empty.
     */
    fun isAllowed(key: String, config: RateLimitConfig): Boolean {
        val bucket = buckets.getOrPut(key) { TokenBucket(config) }
        val allowed = bucket.tryConsume()
        if (!allowed) {
            Log.d(TAG, "isAllowed: rate-limited key='$key' (maxTokens=${config.maxTokens}, " +
                    "refill=${config.refillRatePerMinute}/min)")
        }
        return allowed
    }

    /** Reset the bucket for [key], restoring it to full capacity. */
    fun reset(key: String) {
        buckets.remove(key)
        Log.d(TAG, "reset: cleared bucket for key='$key'")
    }

    /** Reset all buckets. */
    fun resetAll() {
        buckets.clear()
        Log.d(TAG, "resetAll: all buckets cleared")
    }

    // ── TokenBucket ──────────────────────────────────────────────────────────

    private class TokenBucket(private val config: RateLimitConfig) {

        // Stored as a double so fractional refill accumulates correctly.
        private var tokens: Double = config.maxTokens.toDouble()
        private var lastRefillNanos: Long = System.nanoTime()

        /** Try to consume one token. Returns true on success, false if empty. */
        @Synchronized
        fun tryConsume(): Boolean {
            refill()
            return if (tokens >= 1.0) {
                tokens -= 1.0
                true
            } else {
                false
            }
        }

        private fun refill() {
            val now = System.nanoTime()
            val elapsedMs = (now - lastRefillNanos) / 1_000_000.0
            if (elapsedMs <= 0) return

            val refillRatePerMs = config.refillRatePerMinute / 60_000.0
            val newTokens = elapsedMs * refillRatePerMs
            tokens = minOf(tokens + newTokens, config.maxTokens.toDouble())
            lastRefillNanos = now
        }
    }
}
