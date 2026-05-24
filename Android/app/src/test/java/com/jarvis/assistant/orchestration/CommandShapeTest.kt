package com.jarvis.assistant.orchestration

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CommandShapeTest {

    // ── Messaging imperatives — must be commands ────────────────────────────

    @Test fun `send a whatsapp to wifey i love you so much is a command`() =
        assertTrue(CommandShape.isImperativeCommand("Send a WhatsApp to wifey, I love you so much"))

    @Test fun `send whatsapp to wifey is a command`() =
        assertTrue(CommandShape.isImperativeCommand("send whatsapp to wifey I love you"))

    @Test fun `message wifey is a command`() =
        assertTrue(CommandShape.isImperativeCommand("message wifey"))

    @Test fun `text mike running late is a command`() =
        assertTrue(CommandShape.isImperativeCommand("text mike running late"))

    @Test fun `whatsapp mike is a command`() =
        assertTrue(CommandShape.isImperativeCommand("whatsapp mike"))

    @Test fun `email mike is a command`() =
        assertTrue(CommandShape.isImperativeCommand("email mike about the project"))

    @Test fun `reply to mike is a command`() =
        assertTrue(CommandShape.isImperativeCommand("reply to mike saying yes"))

    // ── Calls ───────────────────────────────────────────────────────────────

    @Test fun `call mike is a command`() =
        assertTrue(CommandShape.isImperativeCommand("call mike"))

    @Test fun `ring sarah is a command`() =
        assertTrue(CommandShape.isImperativeCommand("ring sarah on her mobile"))

    @Test fun `hang up is a command`() =
        assertTrue(CommandShape.isImperativeCommand("hang up"))

    // ── Apps ────────────────────────────────────────────────────────────────

    @Test fun `open spotify is a command`() =
        assertTrue(CommandShape.isImperativeCommand("open spotify"))

    @Test fun `close spotify is a command`() =
        assertTrue(CommandShape.isImperativeCommand("close spotify"))

    @Test fun `quit youtube is a command`() =
        assertTrue(CommandShape.isImperativeCommand("quit youtube"))

    // ── Media ───────────────────────────────────────────────────────────────

    @Test fun `play spotify is a command`() =
        assertTrue(CommandShape.isImperativeCommand("play spotify"))

    @Test fun `pause music is a command`() =
        assertTrue(CommandShape.isImperativeCommand("pause"))

    @Test fun `volume up is a command`() =
        assertTrue(CommandShape.isImperativeCommand("volume up"))

    @Test fun `mute is a command`() =
        assertTrue(CommandShape.isImperativeCommand("mute"))

    @Test fun `what is playing is a command`() =
        assertTrue(CommandShape.isImperativeCommand("what's playing"))

    // ── Smart home ──────────────────────────────────────────────────────────

    @Test fun `turn off bedroom light is a command`() =
        assertTrue(CommandShape.isImperativeCommand("turn off bedroom light"))

    @Test fun `turn on the lights is a command`() =
        assertTrue(CommandShape.isImperativeCommand("turn on the lights"))

    @Test fun `start vacuum is a command`() =
        assertTrue(CommandShape.isImperativeCommand("start vacuum"))

    @Test fun `dim the kitchen is a command`() =
        assertTrue(CommandShape.isImperativeCommand("dim the kitchen lights"))

    @Test fun `activate scene is a command`() =
        assertTrue(CommandShape.isImperativeCommand("activate scene movie night"))

    // ── Navigation ──────────────────────────────────────────────────────────

    @Test fun `give me directions to Sainsbury is a command`() =
        assertTrue(CommandShape.isImperativeCommand("Give me directions to Sainsbury's"))

    @Test fun `directions to Sainsbury is a command`() =
        assertTrue(CommandShape.isImperativeCommand("directions to Sainsbury's"))

    @Test fun `navigate to Sainsbury is a command`() =
        assertTrue(CommandShape.isImperativeCommand("navigate to Sainsbury's"))

    @Test fun `take me home is a command`() =
        assertTrue(CommandShape.isImperativeCommand("take me home"))

    @Test fun `drive to work is a command`() =
        assertTrue(CommandShape.isImperativeCommand("drive to work"))

    @Test fun `walk to gym is a command`() =
        assertTrue(CommandShape.isImperativeCommand("walk to the gym"))

    @Test fun `how long until home is a command`() =
        assertTrue(CommandShape.isImperativeCommand("how long until I'm home"))

    @Test fun `where am I is a command`() =
        assertTrue(CommandShape.isImperativeCommand("where am I"))

    // ── Tasks / reminders ───────────────────────────────────────────────────

    @Test fun `remind me to is a command`() =
        assertTrue(CommandShape.isImperativeCommand("remind me to call mike"))

    @Test fun `set a timer is a command`() =
        assertTrue(CommandShape.isImperativeCommand("set a timer for 10 minutes"))

    @Test fun `add a task is a command`() =
        assertTrue(CommandShape.isImperativeCommand("add a task to call mum"))

    // ── Memory / preference / chat — must NOT be commands ───────────────────

    @Test fun `i prefer brief weather is not a command`() =
        assertFalse(CommandShape.isImperativeCommand("I prefer brief weather"))

    @Test fun `my name is Chris is not a command`() =
        assertFalse(CommandShape.isImperativeCommand("my name is Chris"))

    @Test fun `i live in London is not a command`() =
        assertFalse(CommandShape.isImperativeCommand("I live in London"))

    @Test fun `i love you is not a command`() =
        assertFalse(CommandShape.isImperativeCommand("I love you"))

    @Test fun `hello jarvis is not a command`() =
        assertFalse(CommandShape.isImperativeCommand("hello jarvis"))

    @Test fun `what is the weather is not a command`() =
        assertFalse(CommandShape.isImperativeCommand("what's the weather like"))

    @Test fun `from now on tell me less detail is not a command`() =
        assertFalse(CommandShape.isImperativeCommand("from now on tell me less detail"))

    @Test fun `tell me just the temperature is not a command`() =
        assertFalse(CommandShape.isImperativeCommand("tell me just the temperature"))

    // ── Edge cases ──────────────────────────────────────────────────────────

    @Test fun `empty string is not a command`() =
        assertFalse(CommandShape.isImperativeCommand(""))

    @Test fun `blank is not a command`() =
        assertFalse(CommandShape.isImperativeCommand("   "))
}
