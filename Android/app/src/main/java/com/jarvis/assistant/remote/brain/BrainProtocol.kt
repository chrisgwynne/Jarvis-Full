package com.jarvis.assistant.remote.brain

import org.json.JSONObject

/**
 * BrainProtocol — the pure frame codec for the daemon WebSocket contract.
 *
 * This object is the single place where wire-frame field names live on the
 * Android side. It contains no I/O, no logging, and no Android dependencies,
 * so `BrainProtocolConformanceTest` can exercise it directly against
 * `shared/contracts/ws-frame-examples.json` — the executable form of
 * `shared/contracts/PROTOCOL.md`. If a field name here drifts from the
 * contract (or the daemon), the conformance test fails.
 *
 * `MacBrainConnectionManager` delegates frame construction and field
 * extraction here; connection lifecycle, retries, and side effects stay in
 * the manager.
 */
object BrainProtocol {

    // ── Outbound builders (client → daemon) ────────────────────────────────

    /** `transcript.final` — complete STT result for Mac brain processing. */
    fun transcriptFinal(
        text: String,
        routeId: String,
        deviceId: String,
        timestampMs: Long,
    ): JSONObject = JSONObject().apply {
        put("type",       "transcript.final")
        put("messageId",  routeId)
        put("transcript", text)
        put("deviceId",   deviceId)
        put("timestamp",  timestampMs)
    }

    // ── Inbound extraction (daemon → client) ───────────────────────────────

    /** Frame type discriminator. Empty string when absent. */
    fun frameType(json: JSONObject): String = json.optString("type")

    /**
     * Reply text from `reply.final` / `reply.partial` (and their `chat.`
     * aliases) and `orchestrate.speak`. Null when blank/absent — callers
     * drop such frames.
     */
    fun replyText(json: JSONObject): String? =
        json.optString("text").ifBlank { null }

    /**
     * Correlation id used to match a reply back to the originating
     * `transcript.final`: the daemon echoes either `correlationId` or the
     * original `messageId`.
     */
    fun replyCorrelationId(json: JSONObject): String? =
        json.optString("correlationId").ifBlank { null }
            ?: json.optString("messageId").ifBlank { null }

    /** `orchestrate.silent` reason; the contract default is "mac_responding". */
    fun silentReason(json: JSONObject): String =
        json.optString("reason", "mac_responding")

    /** `proactive.notify` → (title, body). Null when body is blank/absent. */
    fun proactiveNotification(json: JSONObject): Pair<String, String>? {
        val body = json.optString("body").ifBlank { return null }
        return json.optString("title", "Jarvis") to body
    }

    /**
     * Envelope-tolerant payload accessor. Daemon-routed frames
     * (`comm.action.execute`, `handoff.request`, `notification.forward`,
     * `remote.action.result`, …) wrap their content in a `payload` object;
     * legacy flat frames carry the fields at the top level. Both shapes are
     * accepted per the contract.
     */
    fun payloadOf(json: JSONObject): JSONObject =
        json.optJSONObject("payload") ?: json
}
