package com.jarvis.assistant.voice.piper.textnorm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TextNormalizerTest {

    // ── Contractions ────────────────────────────────────────────────────────

    @Test fun `expand I'm`() {
        assertEquals("I am home", TextNormalizer.normalize("I'm home"))
    }

    @Test fun `expand do not contraction`() {
        assertEquals("do not do that", TextNormalizer.normalize("don't do that"))
    }

    @Test fun `expand will not`() {
        assertEquals("I will not go", TextNormalizer.normalize("I won't go"))
    }

    @Test fun `expand cannot`() {
        assertEquals("I can not see", TextNormalizer.normalize("I can't see"))
    }

    @Test fun `expand it is`() {
        assertEquals("it is fine", TextNormalizer.normalize("it's fine"))
    }

    @Test fun `expand we will`() {
        assertEquals("we will go", TextNormalizer.normalize("we'll go"))
    }

    @Test fun `expand they have`() {
        assertEquals("they have left", TextNormalizer.normalize("they've left"))
    }

    // ── Symbols ─────────────────────────────────────────────────────────────

    @Test fun `expand percent symbol with following number expansion`() {
        // % → " percent " runs FIRST, then standalone-number expansion turns
        // 50 → fifty.  Net result is "fifty percent done".
        assertEquals("fifty percent done", TextNormalizer.normalize("50% done"))
        val n = TextNormalizer.normalize("you are at 50%")
        assertTrue(n.contains("percent"))
        assertTrue(n.contains("fifty"))
    }

    @Test fun `expand ampersand`() {
        assertTrue(TextNormalizer.normalize("rock & roll").contains(" and "))
    }

    @Test fun `expand at sign`() {
        assertTrue(TextNormalizer.normalize("meet @ 9").contains(" at "))
    }

    // ── Abbreviations ──────────────────────────────────────────────────────

    @Test fun `expand Dr abbreviation`() {
        assertEquals("doctor Smith", TextNormalizer.normalize("Dr. Smith"))
    }

    @Test fun `expand Mr abbreviation`() {
        assertEquals("mister Jones", TextNormalizer.normalize("Mr. Jones"))
    }

    @Test fun `expand etc abbreviation`() {
        assertTrue(TextNormalizer.normalize("apples etc.").contains("etcetera"))
    }

    @Test fun `does not over-expand common words like st`() {
        // "stop" must not become "saintop".  The expander checks whole tokens.
        val n = TextNormalizer.normalize("stop")
        assertEquals("stop", n)
    }

    // ── Numbers ─────────────────────────────────────────────────────────────

    @Test fun `expand single digit`() {
        assertEquals("five", TextNormalizer.normalize("5"))
    }

    @Test fun `expand two-digit number`() {
        assertEquals("forty two", TextNormalizer.normalize("42"))
    }

    @Test fun `expand teens`() {
        assertEquals("fourteen", TextNormalizer.normalize("14"))
    }

    @Test fun `expand round hundred`() {
        assertEquals("three hundred", TextNormalizer.normalize("300"))
    }

    @Test fun `expand hundreds with ones`() {
        assertEquals("three hundred forty two", TextNormalizer.normalize("342"))
    }

    @Test fun `expand thousands`() {
        assertEquals("one thousand five hundred", TextNormalizer.normalize("1500"))
    }

    // ── Years ───────────────────────────────────────────────────────────────

    @Test fun `expand year as twenty twenty six`() {
        val n = TextNormalizer.normalize("2026")
        // Year-mode: "twenty twenty six"
        assertEquals("twenty twenty six", n)
    }

    @Test fun `expand year 1995`() {
        assertEquals("nineteen ninety five", TextNormalizer.normalize("1995"))
    }

    @Test fun `expand round millennium year`() {
        // 2000 is a round millennium — "two thousand" is correct English.
        assertEquals("two thousand", TextNormalizer.normalize("2000"))
    }

    @Test fun `expand early 2000s year`() {
        // Years 2001-2009 use the "two thousand and N" form per natural
        // British English.
        assertEquals("two thousand and seven", TextNormalizer.normalize("2007"))
    }

    // ── Time of day ─────────────────────────────────────────────────────────

    @Test fun `expand time at o'clock`() {
        // 9:00 → "nine o clock"
        assertEquals("nine o clock", TextNormalizer.normalize("9:00"))
    }

    @Test fun `expand time nine thirty`() {
        assertEquals("nine thirty", TextNormalizer.normalize("9:30"))
    }

    @Test fun `expand time nine oh five`() {
        assertEquals("nine oh five", TextNormalizer.normalize("9:05"))
    }

    // ── Blank / edge ────────────────────────────────────────────────────────

    @Test fun `empty input returns empty`() {
        assertEquals("", TextNormalizer.normalize(""))
        assertEquals("", TextNormalizer.normalize("   "))
    }

    @Test fun `preserves punctuation for downstream G2P`() {
        // Punctuation must survive — G2P uses it for sentence boundaries.
        val n = TextNormalizer.normalize("Hello, Chris.")
        assertTrue(n.contains(","))
        assertTrue(n.endsWith("."))
    }

    @Test fun `collapses repeated whitespace`() {
        assertEquals("hello world", TextNormalizer.normalize("hello    world"))
    }

    // ── Sanity: composed sentence ───────────────────────────────────────────

    @Test fun `mixed contraction abbreviation and number`() {
        val n = TextNormalizer.normalize("I'm meeting Dr. Smith at 9:30 in 2026.")
        // Each component normalised.
        assertTrue(n.startsWith("I am meeting doctor Smith"))
        assertTrue(n.contains("nine thirty"))
        assertTrue(n.contains("twenty twenty six"))
        assertTrue(n.endsWith("."))
    }
}
