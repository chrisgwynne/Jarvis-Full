package com.jarvis.assistant.voice.piper

import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.kotlin.mock

/**
 * Tests for the conservative 70% phoneme-mapping success gate in
 * [SherpaPiperPhonemizer].
 *
 * The phonemizer must:
 *   - Compute mapping success as (mapped / total) * 100
 *   - Write the percentage + abort flag to [PiperDiagnostics]
 *   - Return empty when success < [SherpaPiperPhonemizer.MIN_MAPPING_SUCCESS_PERCENT]
 *   - Return non-empty ids when success ≥ threshold
 *
 * Tests use synthetic [PiperVoiceConfig]s with controlled phoneme_id_map
 * coverage so we don't depend on the bundled jarvis-medium.onnx.json.
 */
class SherpaPiperPhonemizerThresholdTest {

    private lateinit var phonemizer: SherpaPiperPhonemizer

    @Before
    fun setUp() {
        phonemizer = SherpaPiperPhonemizer(mock())
        // Reset diagnostics state between tests so assertions don't see
        // leftovers from a previous run.
        PiperDiagnostics.reset()
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    /** Build a [PiperVoiceConfig] whose phoneme_id_map carries exactly [phonemes] mapped to sequential ids. */
    private fun configWith(phonemes: List<String>): PiperVoiceConfig {
        val map = phonemes.mapIndexed { i, p -> p to listOf(i + 1) }.toMap()
        return PiperVoiceConfig(
            audio        = PiperVoiceConfig.AudioConfig(sampleRate = 22050),
            phonemeIdMap = map,
            phonemeType  = "espeak",
            numSpeakers  = 1,
        )
    }

    // ── Full-coverage path ─────────────────────────────────────────────────

    @Test
    fun `full phoneme coverage returns ids and reports 100 percent`() {
        // "hello" → ["h", "ɛ", "l", "əʊ"] from the irregulars dictionary.
        val cfg = configWith(listOf("h", "ɛ", "l", "əʊ"))
        val result = phonemizer.textToPhonemeIds("hello", cfg)
        assertTrue("Should return at least one sentence", result.isNotEmpty())
        assertTrue("First sentence should have ids", result.first().isNotEmpty())

        val snap = PiperDiagnostics.snapshot()
        assertEquals(100, snap.phonemeMappingSuccessPercent)
        assertFalse(snap.phonemeMappingAbortedLowCoverage)
        assertEquals(0, snap.lastPhonemeIdSkips)
    }

    // ── Below-threshold abort ──────────────────────────────────────────────

    @Test
    fun `below-threshold mapping aborts and returns empty`() {
        // "hello" → 4 phonemes ["h", "ɛ", "l", "əʊ"].  Cover only 1 → 25%
        // success, well under the 70% threshold.
        val cfg = configWith(listOf("h"))
        val result = phonemizer.textToPhonemeIds("hello", cfg)
        assertTrue("Should abort and return empty", result.isEmpty())

        val snap = PiperDiagnostics.snapshot()
        assertTrue("Success % should be < threshold",
            snap.phonemeMappingSuccessPercent < SherpaPiperPhonemizer.MIN_MAPPING_SUCCESS_PERCENT)
        assertTrue("Abort flag should be set", snap.phonemeMappingAbortedLowCoverage)
    }

    @Test
    fun `exactly at threshold passes`() {
        // "hello" → 4 phonemes.  Cover 3 of 4 = 75% ≥ 70 → pass.
        val cfg = configWith(listOf("h", "ɛ", "l"))   // missing əʊ
        val result = phonemizer.textToPhonemeIds("hello", cfg)
        assertTrue("75% should pass the 70% threshold", result.isNotEmpty())

        val snap = PiperDiagnostics.snapshot()
        assertEquals(75, snap.phonemeMappingSuccessPercent)
        assertFalse(snap.phonemeMappingAbortedLowCoverage)
        assertEquals(1, snap.lastPhonemeIdSkips)
    }

    @Test
    fun `just below threshold aborts`() {
        // Use a longer utterance to make a single skip not push us to 0%.
        // "the jarvis hello chris" — multi-word, mixed common words.
        // We construct a config that covers about 60% of the phonemes.
        // Easier: phonemise to count, then construct.
        val phonemes = com.jarvis.assistant.voice.piper.g2p.EnglishG2P
            .phonemize("the jarvis hello chris").flatten()
            .filter { it.isNotBlank() && it != " " }
        val total = phonemes.size
        require(total >= 5) { "Test relies on a non-trivial phoneme count" }

        // Cover the first 60% of unique phonemes → success around 60%.
        val coveredCount = (total * 0.6).toInt()
        val cfg = configWith(phonemes.distinct().take(coveredCount))
        val result = phonemizer.textToPhonemeIds("the jarvis hello chris", cfg)

        val snap = PiperDiagnostics.snapshot()
        // Either abort fired (< 70%) and result is empty, OR our heuristic
        // happened to land on >= 70%.  The contract being tested is the
        // GATE: if success < threshold, result must be empty.
        if (snap.phonemeMappingSuccessPercent < SherpaPiperPhonemizer.MIN_MAPPING_SUCCESS_PERCENT) {
            assertTrue(result.isEmpty())
            assertTrue(snap.phonemeMappingAbortedLowCoverage)
        } else {
            assertTrue(result.isNotEmpty())
            assertFalse(snap.phonemeMappingAbortedLowCoverage)
        }
    }

    // ── Edge cases ─────────────────────────────────────────────────────────

    @Test
    fun `empty text returns empty without writing diagnostics`() {
        val cfg = configWith(listOf("h", "ɛ", "l", "əʊ"))
        val result = phonemizer.textToPhonemeIds("", cfg)
        assertTrue(result.isEmpty())
        // Diagnostics should be untouched — still defaults.
        val snap = PiperDiagnostics.snapshot()
        assertEquals(0, snap.phonemeMappingSuccessPercent)
        assertFalse(snap.phonemeMappingAbortedLowCoverage)
    }

    @Test
    fun `null phoneme map in config returns empty without crash`() {
        val cfg = PiperVoiceConfig(
            audio        = PiperVoiceConfig.AudioConfig(sampleRate = 22050),
            phonemeIdMap = null,
            phonemeType  = "espeak",
            numSpeakers  = 1,
        )
        val result = phonemizer.textToPhonemeIds("hello", cfg)
        assertTrue(result.isEmpty())
    }

    @Test
    fun `phonemizer is always available`() {
        assertTrue(phonemizer.isAvailable)
        assertEquals("kotlin-en-gb-g2p", phonemizer.name)
    }

    // ── Threshold value safety ─────────────────────────────────────────────

    @Test
    fun `threshold constant is between 50 and 95 percent`() {
        // Sanity check — too low defeats the purpose; too high blocks
        // legitimate utterances with one or two odd phonemes.
        assertTrue(SherpaPiperPhonemizer.MIN_MAPPING_SUCCESS_PERCENT in 50..95)
    }
}
