package com.jarvis.assistant.voice.piper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PiperVoiceRegistryTest {

    @Test
    fun `default registry contains the bundled voice`() {
        val voice = PiperVoiceRegistry.byId(PiperVoiceRegistry.DEFAULT_VOICE_ID)
        assertNotNull(voice)
        assertEquals(PiperVoiceRegistry.DEFAULT_VOICE_ID, voice!!.id)
        assertEquals("voices/jarvis-medium.onnx", voice.modelAssetPath)
        assertEquals("voices/jarvis-medium.onnx.json", voice.jsonAssetPath)
    }

    @Test
    fun `default returns the bundled voice as the default`() {
        assertEquals(PiperVoiceRegistry.DEFAULT_VOICE_ID, PiperVoiceRegistry.default().id)
    }

    @Test
    fun `byId returns null for unknown voice`() {
        assertNull(PiperVoiceRegistry.byId("not-a-real-voice-id"))
    }

    @Test
    fun `register adds a new voice`() {
        val newVoice = VoiceDefinition(
            id            = "test-newvoice-${System.currentTimeMillis()}",
            displayName   = "Test Voice",
            externalModelPath = "/tmp/test.onnx",
            externalJsonPath  = "/tmp/test.onnx.json",
        )
        PiperVoiceRegistry.register(newVoice)
        assertNotNull(PiperVoiceRegistry.byId(newVoice.id))
        assertTrue(PiperVoiceRegistry.all().any { it.id == newVoice.id })
    }

    @Test
    fun `register replaces an existing voice with the same id`() {
        val id = "test-replace-${System.currentTimeMillis()}"
        PiperVoiceRegistry.register(VoiceDefinition(id = id, displayName = "v1"))
        PiperVoiceRegistry.register(VoiceDefinition(id = id, displayName = "v2"))
        assertEquals("v2", PiperVoiceRegistry.byId(id)?.displayName)
    }

    @Test
    fun `default voice has expected metadata`() {
        val v = PiperVoiceRegistry.default()
        assertEquals("Jarvis (medium)", v.displayName)
        assertEquals(22050, v.sampleRate)
        assertEquals("medium", v.quality)
        assertEquals("en-GB", v.locale)
    }
}
