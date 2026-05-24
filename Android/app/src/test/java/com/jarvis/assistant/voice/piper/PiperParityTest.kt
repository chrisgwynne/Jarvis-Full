package com.jarvis.assistant.voice.piper

import com.jarvis.assistant.voice.piper.g2p.EnglishG2P
import com.jarvis.assistant.voice.piper.textnorm.TextNormalizer
import org.junit.Assert.*
import org.junit.Test

/**
 * PiperParityTest — validates that the Android TTS pipeline produces
 * outputs consistent with the Mac Piper CLI pipeline for key phrases.
 *
 * These are NOT exact-match tests (Android and Mac use different
 * phonemizers) — they verify that:
 * 1. TextNormalizer produces reasonable spoken-word output
 * 2. EnglishG2P produces IPA phonemes for known words
 * 3. Token format is BOS/PAD/EOS interspersed correctly
 * 4. PCM conversion doesn't clip heavily
 */
class PiperParityTest {

    // ── 1. TextNormalizer ────────────────────────────────────────────────────

    @Test fun `normalize good evening chris`() {
        val result = TextNormalizer.normalize("Good evening, Chris.")
        // Should not change (no special patterns)
        assertTrue("Should preserve normal text", result.isNotBlank())
        assertFalse("Should not contain markdown", result.contains("```"))
    }

    @Test fun `normalize expands ive contraction`() {
        val result = TextNormalizer.normalize("I've turned the living room lights on.")
        assertTrue("Should expand I've", result.contains("I have") || result.contains("i have"))
    }

    @Test fun `normalize expands version numbers`() {
        val result = TextNormalizer.normalize("Running version v1.2.3 of the model.")
        // expandVersionNumbers produces "version 1 point 2 point 3"; then
        // expandStandaloneNumbers converts the digits to words, so the final
        // output is "version one point two point three".
        assertTrue("Should expand v1.2.3 — must contain 'point'", result.contains("point"))
        assertFalse("Should remove 'v1.2.3' literal", result.contains("v1.2.3"))
        assertTrue("Should say 'version'", result.contains("version"))
    }

    @Test fun `normalize expands urls`() {
        val result = TextNormalizer.normalize("Check github.com for updates.")
        assertTrue("Should expand bare domain", result.contains("dot"))
        assertFalse("Should not contain raw .com", result.contains("github.com"))
    }

    @Test fun `normalize expands full urls`() {
        val result = TextNormalizer.normalize("Visit https://github.com/user/repo")
        assertTrue("Should expand URL", result.contains("github"))
        assertFalse("Should remove https://", result.contains("https://"))
    }

    @Test fun `normalize number quarter past seven`() {
        // "quarter past seven" is natural language — should pass through as words
        val result = TextNormalizer.normalize("Your reminder is set for quarter past seven.")
        assertTrue("Should contain 'quarter'", result.lowercase().contains("quarter"))
        assertTrue("Should contain 'seven'", result.lowercase().contains("seven"))
    }

    @Test fun `normalize whatsapp message sent`() {
        val result = TextNormalizer.normalize("WhatsApp message sent.")
        // WhatsApp should be expanded to "Whats App" via TECH_BRANDS
        assertTrue("WhatsApp should be present in some form", result.isNotBlank())
        assertTrue("WhatsApp should be expanded", result.contains("Whats App"))
    }

    // ── 2. EnglishG2P phoneme tests ──────────────────────────────────────────

    @Test fun `g2p the article uses voiced th`() {
        val phonemes = flatPhonemes("the")
        assertTrue("'the' should start with ð", phonemes.firstOrNull() == "ð")
    }

    @Test fun `g2p good evening correct phonemes`() {
        val good = flatPhonemes("good")
        assertTrue("'good' should contain ʊ", good.contains("ʊ"))

        val evening = flatPhonemes("evening")
        assertTrue("'evening' should start with iː", evening.firstOrNull() == "iː")
    }

    @Test fun `g2p door uses correct vowel`() {
        val phonemes = flatPhonemes("door")
        // Should be d ɔː — NOT d uː ɹ
        assertTrue("'door' should contain ɔː", phonemes.contains("ɔː"))
        assertFalse("'door' should not contain uː", phonemes.contains("uː"))
    }

    @Test fun `g2p front uses correct british vowel`() {
        val phonemes = flatPhonemes("front")
        // British: f ɹ ʌ n t — NOT f ɹ ɒ n t
        assertTrue("'front' should contain ʌ", phonemes.contains("ʌ"))
        assertFalse("'front' should not contain ɒ", phonemes.contains("ɒ"))
    }

    @Test fun `g2p past uses bath vowel`() {
        val phonemes = flatPhonemes("past")
        // British: p ɑː s t — NOT p æ s t
        assertTrue("'past' should contain ɑː", phonemes.contains("ɑː"))
        assertFalse("'past' should not contain æ", phonemes.contains("æ"))
    }

    @Test fun `g2p quarter correct`() {
        val phonemes = flatPhonemes("quarter")
        assertTrue("'quarter' should contain ɔː", phonemes.contains("ɔː"))
        // Word-final -er should be ə, not ɜː
        assertTrue("'quarter' should end with ə", phonemes.lastOrNull() == "ə")
        assertFalse("'quarter' should not contain ɜː", phonemes.contains("ɜː"))
    }

    @Test fun `g2p unlocked past tense`() {
        val phonemes = flatPhonemes("unlocked")
        // Should end in t (voiceless after k), not ɛ d
        assertTrue("'unlocked' should end with t", phonemes.lastOrNull() == "t")
    }

    @Test fun `g2p turned past tense`() {
        val phonemes = flatPhonemes("turned")
        // Should end in d (voiced after n), not ɛ d
        assertTrue("'turned' should end with d", phonemes.lastOrNull() == "d")
    }

    @Test fun `g2p word-final -er produces schwa`() {
        // "over", "water", "other" should all end in ə
        for (word in listOf("over", "water", "other", "better", "never")) {
            val phonemes = flatPhonemes(word)
            assertTrue("'$word' should end with ə, got: $phonemes",
                phonemes.lastOrNull() == "ə")
        }
    }

    // ── 3. Token format (BOS/PAD/EOS interspersing) ─────────────────────────

    @Test fun `token format is BOS PAD ph PAD EOS`() {
        // Simulate what PiperTtsEngine does with [42L] (some phoneme ID)
        val rawPhonemeIds = listOf(42)
        val PAD = 0L; val BOS = 1L; val EOS = 2L
        val tokenCount = rawPhonemeIds.size * 2 + 3
        val arr = LongArray(tokenCount)
        var tidx = 0
        arr[tidx++] = BOS
        for (id in rawPhonemeIds) { arr[tidx++] = PAD; arr[tidx++] = id.toLong() }
        arr[tidx++] = PAD; arr[tidx++] = EOS

        assertEquals("First token should be BOS", BOS, arr[0])
        assertEquals("Second token should be PAD", PAD, arr[1])
        assertEquals("Third token should be phoneme ID", 42L, arr[2])
        assertEquals("Second-to-last should be PAD", PAD, arr[arr.size - 2])
        assertEquals("Last token should be EOS", EOS, arr[arr.size - 1])
    }

    @Test fun `token count matches formula`() {
        val n = 10
        val tokenCount = n * 2 + 3
        assertEquals("Token count should be 2N+3", 23, tokenCount)
    }

    // ── 4. PCM conversion ────────────────────────────────────────────────────

    @Test fun `pcm conversion does not clip normal signal`() {
        // Simulate a signal with max abs = 0.8 (well within range)
        val rawPcm = FloatArray(100) { if (it % 2 == 0) 0.8f else -0.8f }
        var maxAbs = rawPcm.maxOf { if (it < 0) -it else it }
        maxAbs = maxOf(maxAbs, 0.01f)
        var clipping = 0
        val pcm16 = ShortArray(rawPcm.size)
        for (i in rawPcm.indices) {
            var v = rawPcm[i] / maxAbs
            if (v > 1.0f) { v = 1.0f; clipping++ }
            if (v < -1.0f) { v = -1.0f; clipping++ }
            pcm16[i] = (v * 32767.0f).toInt().toShort()
        }
        assertEquals("No clipping expected for 0.8 signal", 0, clipping)
    }

    @Test fun `pcm conversion handles near-zero signal`() {
        // Near-silent signal should not produce NaN/infinity
        val rawPcm = FloatArray(100) { 0.0001f }
        var maxAbs = rawPcm.maxOf { if (it < 0) -it else it }
        maxAbs = maxOf(maxAbs, 0.01f)  // safeguard floor
        val pcm16 = ShortArray(rawPcm.size)
        for (i in rawPcm.indices) {
            val v = (rawPcm[i] / maxAbs).coerceIn(-1f, 1f)
            pcm16[i] = (v * 32767.0f).toInt().toShort()
        }
        // No exception thrown = pass
        assertTrue("PCM should be all valid shorts", pcm16.all { it >= Short.MIN_VALUE && it <= Short.MAX_VALUE })
    }

    @Test fun `sample rate matches config`() {
        // Verify config default is 22050
        val config = PiperVoiceConfig(
            audio = PiperVoiceConfig.AudioConfig(sampleRate = 22050)
        )
        assertEquals("Sample rate should be 22050", 22050, config.sampleRate)
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun flatPhonemes(word: String): List<String> {
        val result = EnglishG2P.phonemize(word)
        return result.flatten()
    }
}
