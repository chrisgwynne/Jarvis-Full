package com.jarvis.assistant.tools.device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Tests for the comma-as-body-separator extension to MessageIntentParser.
 *
 * The original parser required a "saying" connector; this enhancement adds
 * support for the natural "send a whatsapp to <name>, <body>" form which is
 * how most users actually phrase the command.
 */
class MessageIntentParserCommaBodyTest {

    @Test
    fun `send a whatsapp to wifey comma body extracts both`() {
        val intent = MessageIntentParser.parse("send a whatsapp to wifey, I love you so much")
        assertNotNull(intent)
        assertEquals(MessageIntentParser.Channel.WHATSAPP, intent!!.channel)
        assertEquals("wifey", intent.recipient)
        assertEquals("I love you so much", intent.body)
    }

    @Test
    fun `send whatsapp to mike comma body extracts both`() {
        val intent = MessageIntentParser.parse("send whatsapp to mike, running late")
        assertNotNull(intent)
        assertEquals(MessageIntentParser.Channel.WHATSAPP, intent!!.channel)
        assertEquals("mike", intent.recipient)
        assertEquals("running late", intent.body)
    }

    @Test
    fun `text mike comma body extracts both`() {
        val intent = MessageIntentParser.parse("text mike, on my way")
        assertNotNull(intent)
        assertEquals(MessageIntentParser.Channel.SMS, intent!!.channel)
        assertEquals("mike", intent.recipient)
        assertEquals("on my way", intent.body)
    }

    @Test
    fun `message sarah comma body extracts both`() {
        val intent = MessageIntentParser.parse("message sarah, see you at 8")
        assertNotNull(intent)
        assertEquals("sarah", intent!!.recipient)
        assertEquals("see you at 8", intent.body)
    }

    @Test
    fun `whatsapp mike comma body extracts both`() {
        val intent = MessageIntentParser.parse("whatsapp mike, dinner tonight?")
        assertNotNull(intent)
        assertEquals(MessageIntentParser.Channel.WHATSAPP, intent!!.channel)
        assertEquals("mike", intent.recipient)
        assertEquals("dinner tonight?", intent.body)
    }

    @Test
    fun `multi-word recipient with comma body`() {
        val intent = MessageIntentParser.parse("text john smith, are you home")
        assertNotNull(intent)
        assertEquals("john smith", intent!!.recipient)
        assertEquals("are you home", intent.body)
    }

    @Test
    fun `connector form still works alongside comma form`() {
        val intent = MessageIntentParser.parse("send mike a whatsapp saying running late")
        assertNotNull(intent)
        assertEquals(MessageIntentParser.Channel.WHATSAPP, intent!!.channel)
        assertEquals("mike", intent.recipient)
        assertEquals("running late", intent.body)
    }

    @Test
    fun `channel preservation - WhatsApp stays WhatsApp with comma form`() {
        val intent = MessageIntentParser.parse(
            "send a whatsapp message to mike, see you soon"
        )
        assertEquals(MessageIntentParser.Channel.WHATSAPP, intent?.channel)
    }

    @Test
    fun `recipient is not punctuated`() {
        val intent = MessageIntentParser.parse("send a whatsapp to wifey, hi")
        // Recipient must not carry a trailing comma into ContactLookup.
        assertEquals("wifey", intent?.recipient)
    }
}
