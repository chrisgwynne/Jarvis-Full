package com.jarvis.assistant.tools.device

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for [MacCameraViewerTool] phrase matching.
 *
 * The regex is extracted here as a literal to keep tests context-free
 * (the tool needs Context, Settings, and BridgeSettings to construct).
 *
 * Acceptance criteria:
 *   - All listed voice phrases produce a match.
 *   - Unrelated phrases do NOT match.
 *   - Tool does NOT call Mac Brain (no assertion needed here — the tool
 *     simply has no Mac Brain dependency; confirmed by code review).
 */
class MacCameraViewerToolMatcherTest {

    private val PHRASES = Regex(
        """show\s+(?:me\s+)?(?:the\s+)?mac\s+(?:camera|webcam)""" +
        """|open\s+mac\s+camera""" +
        """|show\s+jarvis\s+camera""" +
        """|show\s+mac\s+webcam""" +
        """|let\s+me\s+see\s+(?:the\s+)?mac\s+camera""" +
        """|check\s+(?:the\s+)?mac\s+camera""" +
        """|view\s+mac\s+camera""" +
        """|open\s+(?:the\s+)?mac\s+webcam""" +
        """|show\s+the\s+mac\s+webcam""",
        RegexOption.IGNORE_CASE
    )

    // ── Positive: all target phrases match ───────────────────────────────────

    @Test
    fun `show me the Mac camera matches`() {
        assertNotNull(PHRASES.find("show me the Mac camera"))
    }

    @Test
    fun `open Mac camera matches`() {
        assertNotNull(PHRASES.find("open Mac camera"))
    }

    @Test
    fun `show Jarvis camera matches`() {
        assertNotNull(PHRASES.find("show Jarvis camera"))
    }

    @Test
    fun `show Mac webcam matches`() {
        assertNotNull(PHRASES.find("show Mac webcam"))
    }

    @Test
    fun `let me see the Mac camera matches`() {
        assertNotNull(PHRASES.find("let me see the Mac camera"))
    }

    @Test
    fun `let me see Mac camera matches without the`() {
        assertNotNull(PHRASES.find("let me see Mac camera"))
    }

    @Test
    fun `check the Mac camera matches`() {
        assertNotNull(PHRASES.find("check the Mac camera"))
    }

    @Test
    fun `check Mac camera matches without the`() {
        assertNotNull(PHRASES.find("check Mac camera"))
    }

    @Test
    fun `view Mac camera matches`() {
        assertNotNull(PHRASES.find("view Mac camera"))
    }

    @Test
    fun `open the Mac webcam matches`() {
        assertNotNull(PHRASES.find("open the Mac webcam"))
    }

    @Test
    fun `show the Mac webcam matches`() {
        assertNotNull(PHRASES.find("show the Mac webcam"))
    }

    @Test
    fun `show Mac camera matches without me`() {
        assertNotNull(PHRASES.find("show Mac camera"))
    }

    @Test
    fun `case insensitive matches`() {
        assertNotNull(PHRASES.find("SHOW ME THE MAC CAMERA"))
        assertNotNull(PHRASES.find("Open Mac Camera"))
    }

    // ── Negative: unrelated phrases must NOT match ───────────────────────────

    @Test
    fun `take a photo does NOT match`() {
        assertNull(PHRASES.find("take a photo"))
    }

    @Test
    fun `show me my selfie does NOT match`() {
        assertNull(PHRASES.find("show me my selfie"))
    }

    @Test
    fun `show me the camera without Mac does NOT match`() {
        assertNull(PHRASES.find("show me the camera"))
    }

    @Test
    fun `open the camera without Mac does NOT match`() {
        assertNull(PHRASES.find("open the camera"))
    }

    @Test
    fun `mac is not enough alone does NOT match`() {
        assertNull(PHRASES.find("mac"))
        assertNull(PHRASES.find("mac jarvis"))
    }
}
