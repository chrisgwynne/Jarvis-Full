package com.jarvis.assistant.comm

import com.jarvis.assistant.remote.gateway.BrainGatewayWebSocketClient
import org.json.JSONObject
import java.util.UUID

/**
 * CommEventBroadcaster — sends comm.event.received and comm.event.resolved frames
 * to the daemon via BrainGatewayWebSocketClient.
 *
 * SECURITY: Raw phone numbers are never logged or transmitted.
 * All phone handles must be pre-masked (e.g. "****1234") before reaching this object.
 */
object CommEventBroadcaster {

    /**
     * Sends a comm.event.received frame to the daemon.
     *
     * @param gateway         Active WebSocket client (null-safe — no-op if null or disconnected)
     * @param channel         "phone" | "sms" | "whatsapp" | "whatsapp_business"
     * @param direction       "incoming" | "outgoing"
     * @param state           "missed" | "unread" | "received"
     * @param contactName     Display name or "Unknown"
     * @param contactHandle   MUST be masked: last 4 digits for phone (e.g. "****1234"), or "****"
     * @param sourceApp       Package name of the originating app
     * @param snippet         Optional message preview (truncated, null if privacy is off)
     * @return eventId        UUID for correlating with a future sendResolved() call
     */
    fun sendReceived(
        gateway: BrainGatewayWebSocketClient?,
        channel: String,
        direction: String,
        state: String,
        contactName: String,
        contactHandle: String,
        sourceApp: String,
        snippet: String? = null
    ): String {
        val eventId = UUID.randomUUID().toString()
        val frame = JSONObject().apply {
            put("type", "comm.event.received")
            put("eventId", eventId)
            put("channel", channel)
            put("direction", direction)
            put("state", state)
            put("contactName", contactName)
            put("contactHandle", contactHandle)   // never the full phone number
            put("sourceApp", sourceApp)
            put("timestamp", System.currentTimeMillis())
            snippet?.let { put("snippet", it) }
        }
        gateway?.sendTypedFrame(frame)
        return eventId
    }

    /**
     * Sends a comm.event.resolved frame to notify the daemon an event was actioned.
     *
     * @param gateway   Active WebSocket client
     * @param eventId   The UUID returned by [sendReceived]
     * @param state     "replied" | "called_back" | "dismissed"
     */
    fun sendResolved(
        gateway: BrainGatewayWebSocketClient?,
        eventId: String,
        state: String
    ) {
        val frame = JSONObject().apply {
            put("type", "comm.event.resolved")
            put("eventId", eventId)
            put("state", state)
            put("timestamp", System.currentTimeMillis())
        }
        gateway?.sendTypedFrame(frame)
    }
}
