package com.jarvis.assistant.remote.actions

import org.junit.Assert.*
import org.junit.Test

class RemoteActionIntentTest {

    @Test
    fun `open notes on the mac routes to MAC open_app`() {
        val result = RemoteActionIntent.detect("open notes on the mac")!!
        assertEquals(RemoteActionIntent.Routing.MAC, result.routing)
        assertEquals("open_app", result.action)
        assertEquals("Notes", result.parameters["appName"])
    }

    @Test
    fun `open news routes to MAC open_app (mac-only app)`() {
        val result = RemoteActionIntent.detect("open news")!!
        assertEquals(RemoteActionIntent.Routing.MAC, result.routing)
        assertEquals("open_app", result.action)
    }

    @Test
    fun `open safari routes to MAC open_app (mac-only app)`() {
        val result = RemoteActionIntent.detect("open safari")!!
        assertEquals(RemoteActionIntent.Routing.MAC, result.routing)
        assertEquals("open_app", result.action)
    }

    @Test
    fun `open notes without mac phrase is AMBIGUOUS`() {
        val result = RemoteActionIntent.detect("open notes")
        // Notes is in ambiguousApps set
        assertTrue(result == null || result.routing == RemoteActionIntent.Routing.AMBIGUOUS)
    }

    @Test
    fun `create a note called shopping list on the mac`() {
        val result = RemoteActionIntent.detect("create a note called shopping list on the mac")!!
        assertEquals(RemoteActionIntent.Routing.MAC, result.routing)
        assertEquals("create_note", result.action)
        assertEquals("shopping list", result.parameters["title"])
    }

    @Test
    fun `show mac camera`() {
        val result = RemoteActionIntent.detect("show me the mac camera")!!
        assertEquals(RemoteActionIntent.Routing.MAC, result.routing)
        assertEquals("show_camera", result.action)
    }

    @Test
    fun `open jarvis on the mac`() {
        val result = RemoteActionIntent.detect("open jarvis on the mac")!!
        assertEquals(RemoteActionIntent.Routing.MAC, result.routing)
        assertEquals("open_jarvis", result.action)
    }

    @Test
    fun `send this to the mac triggers file transfer`() {
        val result = RemoteActionIntent.detect("send this to the mac")!!
        assertEquals(RemoteActionIntent.Routing.MAC, result.routing)
        assertEquals("file_transfer", result.action)
    }

    @Test
    fun `local android command not stolen`() {
        val result = RemoteActionIntent.detect("what is the weather today")
        assertNull(result)
    }

    @Test
    fun `call mum is not stolen`() {
        val result = RemoteActionIntent.detect("call mum")
        assertNull(result)
    }
}
