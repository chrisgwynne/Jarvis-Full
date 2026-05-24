package com.jarvis.assistant.voice.piper

import com.google.gson.Gson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [PiperVoiceConfig] JSON parsing.
 *
 * The JSON shape mirrors the standard Piper voice config layout — these
 * test fixtures are minimal, hand-written examples (not actual Piper voice
 * data) used purely to exercise the data-class deserialisation paths.
 */
class PiperVoiceConfigTest {

    private val gson = Gson()

    @Test
    fun `minimal config parses defaults`() {
        val json = """
            {
              "audio": { "sample_rate": 22050 },
              "phoneme_id_map": { "_": [0], "a": [1] }
            }
        """.trimIndent()
        val cfg = gson.fromJson(json, PiperVoiceConfig::class.java)
        assertNotNull(cfg)
        assertEquals(22050, cfg.sampleRate)
        assertEquals(0.667f, cfg.noiseScale, 0.0001f)
        assertEquals(1.0f, cfg.lengthScale, 0.0001f)
        assertEquals(0.8f, cfg.noiseW, 0.0001f)
        assertTrue(cfg.isSingleSpeaker)
        assertNull(cfg.espeakVoice)
    }

    @Test
    fun `full config parses every field`() {
        val json = """
            {
              "audio": { "sample_rate": 16000 },
              "espeak": { "voice": "en-gb" },
              "inference": {
                "noise_scale": 0.5,
                "length_scale": 1.2,
                "noise_w": 0.7
              },
              "phoneme_id_map": { "_": [0], "p": [55], "ɪ": [12] },
              "phoneme_map": {},
              "phoneme_type": "espeak",
              "num_speakers": 1,
              "language": { "code": "en_GB" }
            }
        """.trimIndent()
        val cfg = gson.fromJson(json, PiperVoiceConfig::class.java)
        assertEquals(16000, cfg.sampleRate)
        assertEquals(0.5f, cfg.noiseScale, 0.0001f)
        assertEquals(1.2f, cfg.lengthScale, 0.0001f)
        assertEquals(0.7f, cfg.noiseW, 0.0001f)
        assertEquals("en-gb", cfg.espeakVoice)
        assertEquals("en_GB", cfg.languageCode)
        assertEquals(3, cfg.phonemeIdMap?.size)
        assertTrue(cfg.isSingleSpeaker)
    }

    @Test
    fun `multi-speaker config flags isSingleSpeaker false`() {
        val json = """
            {
              "audio": { "sample_rate": 22050 },
              "phoneme_id_map": { "_": [0] },
              "num_speakers": 4,
              "speaker_id_map": { "a": 0, "b": 1, "c": 2, "d": 3 }
            }
        """.trimIndent()
        val cfg = gson.fromJson(json, PiperVoiceConfig::class.java)
        assertEquals(4, cfg.numSpeakers)
        assertEquals(false, cfg.isSingleSpeaker)
        assertEquals(4, cfg.speakerIdMap?.size)
    }

    @Test
    fun `missing audio block falls through to default sample rate`() {
        val json = """{ "phoneme_id_map": { "_": [0] } }"""
        val cfg = gson.fromJson(json, PiperVoiceConfig::class.java)
        assertEquals(22050, cfg.sampleRate)
    }

    @Test
    fun `unknown extra fields do not break parsing`() {
        val json = """
            {
              "audio": { "sample_rate": 22050 },
              "phoneme_id_map": { "_": [0] },
              "future_field_that_does_not_exist": 42,
              "another_extra": "hello"
            }
        """.trimIndent()
        val cfg = gson.fromJson(json, PiperVoiceConfig::class.java)
        assertNotNull(cfg)
        assertEquals(22050, cfg.sampleRate)
    }
}
