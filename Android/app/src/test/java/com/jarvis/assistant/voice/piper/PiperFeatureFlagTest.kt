package com.jarvis.assistant.voice.piper

import com.jarvis.assistant.voice.VoiceFeatureFlags
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Tests for the [VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P] flag.
 *
 * The defining contract: the flag MUST default OFF so the experimental
 * Kotlin G2P never affects production Jarvis speech without an explicit
 * user opt-in.
 */
class PiperFeatureFlagTest {

    @Before
    fun setUp() {
        // Defensive — clear any override another test left behind.
        VoiceFeatureFlags.clearOverride(VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P)
    }

    @After
    fun tearDown() {
        VoiceFeatureFlags.clearOverride(VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P)
    }

    @Test
    fun `flag exists in the enum`() {
        val flag = VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P
        assertEquals("voice.experimental_kotlin_g2p", flag.key)
    }

    @Test
    fun `flag default is OFF`() {
        assertFalse(
            "USE_EXPERIMENTAL_KOTLIN_G2P must default to false so normal " +
                "Jarvis speech is never affected by an in-development voice path.",
            VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P.defaultEnabled,
        )
    }

    @Test
    fun `isEnabled returns false by default`() {
        assertFalse(
            VoiceFeatureFlags.isEnabled(
                VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P
            )
        )
    }

    @Test
    fun `setOverride true flips the flag on`() {
        VoiceFeatureFlags.setOverride(
            VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P, true,
        )
        assertTrue(
            VoiceFeatureFlags.isEnabled(
                VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P
            )
        )
    }

    @Test
    fun `clearOverride restores default`() {
        VoiceFeatureFlags.setOverride(
            VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P, true,
        )
        VoiceFeatureFlags.clearOverride(
            VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P
        )
        assertFalse(
            VoiceFeatureFlags.isEnabled(
                VoiceFeatureFlags.Flag.USE_EXPERIMENTAL_KOTLIN_G2P
            )
        )
    }
}
