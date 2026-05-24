package com.jarvis.assistant.voice.piper.g2p

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EnglishG2PTest {

    // ── Sentence segmentation ───────────────────────────────────────────────

    @Test fun `single sentence produces one segment`() {
        val r = EnglishG2P.phonemize("hello chris")
        assertEquals(1, r.size)
        assertTrue(r[0].isNotEmpty())
    }

    @Test fun `two sentences produce two segments`() {
        val r = EnglishG2P.phonemize("hello chris. systems are online.")
        assertEquals(2, r.size)
    }

    @Test fun `empty input returns empty`() {
        assertTrue(EnglishG2P.phonemize("").isEmpty())
        assertTrue(EnglishG2P.phonemize("   ").isEmpty())
    }

    // ── Irregular dictionary hits — high-confidence assertions ──────────────

    @Test fun `the is mapped via irregulars`() {
        val r = EnglishG2P.phonemize("the").flatten()
        // "the" → "ð ə"
        assertTrue("Should contain ð", r.any { it == "ð" })
        assertTrue("Should contain ə", r.any { it == "ə" })
    }

    @Test fun `jarvis recognised as a named word`() {
        val r = EnglishG2P.phonemize("jarvis").flatten()
        // The dictionary entry produces dʒ ɑː v ɪ s
        assertTrue("Should produce phonemes", r.isNotEmpty())
        assertTrue("Should contain dʒ", r.any { it == "dʒ" })
    }

    @Test fun `chris recognised as a name`() {
        val r = EnglishG2P.phonemize("chris").flatten()
        // "chris" → "k r ɪ s"
        assertTrue(r.any { it == "k" })
        assertTrue(r.any { it == "r" })
        assertTrue(r.any { it == "s" })
    }

    @Test fun `hello produces multi-phoneme output`() {
        val r = EnglishG2P.phonemize("hello").flatten()
        assertTrue("hello should produce > 2 phonemes", r.size >= 3)
    }

    // ── Word boundaries ─────────────────────────────────────────────────────

    @Test fun `inter-word space emitted between words`() {
        val r = EnglishG2P.phonemize("hello chris").flatten()
        assertTrue("Should contain a space boundary", r.contains(" "))
    }

    @Test fun `single word has no trailing space`() {
        val r = EnglishG2P.phonemize("hello").flatten()
        assertFalse("Single word should not emit a trailing space", r.contains(" "))
    }

    // ── Letter rules fallback (unknown words) ───────────────────────────────

    @Test fun `unknown word produces some phonemes`() {
        // "zorbo" isn't in the dictionary — must still produce something.
        val r = EnglishG2P.phonemize("zorbo").flatten()
        assertTrue("Letter rules should produce phonemes", r.isNotEmpty())
    }

    @Test fun `digraph th mapped to single phoneme`() {
        val r = EnglishG2P.phonemize("thump").flatten()
        // Should produce θ + vowel + m + p — at minimum θ appears.
        assertTrue("Digraph th → θ", r.contains("θ"))
    }

    @Test fun `digraph sh mapped to ʃ`() {
        val r = EnglishG2P.phonemize("shrub").flatten()
        assertTrue(r.contains("ʃ"))
    }

    @Test fun `silent kn handled`() {
        val r = EnglishG2P.phonemize("knack").flatten()
        // Should NOT contain k at the start (digraph kn → n).
        assertEquals("n", r.first())
    }

    // ── Punctuation pass-through ───────────────────────────────────────────

    @Test fun `terminal period emitted as its own phoneme`() {
        val r = EnglishG2P.phonemize("hello.").flatten()
        assertEquals(".", r.last())
    }

    @Test fun `comma inside sentence`() {
        val r = EnglishG2P.phonemize("hello, chris").flatten()
        assertTrue(r.contains(","))
    }

    // ── Sanity: the target test phrase ──────────────────────────────────────

    @Test fun `test phrase produces non-trivial phoneme sequence`() {
        val r = EnglishG2P.phonemize("Hello Chris. Systems are online.")
        assertEquals(2, r.size)
        val flat = r.flatten()
        assertTrue("Total phonemes should be reasonable", flat.size > 8)
        // The test phrase's contained words all have dictionary entries —
        // confidence that the most-spoken Jarvis line synthesises cleanly.
    }
}
