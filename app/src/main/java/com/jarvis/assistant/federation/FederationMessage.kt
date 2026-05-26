package com.jarvis.assistant.federation

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

private const val TAG = "FederationMessage"

enum class MacResponseType { SHORT_RESPONSE, FULL_RESPONSE, ACTIONABLE_RESPONSE, NOTIFICATION_RESPONSE }
enum class NotificationPriority { LOW, NORMAL, HIGH, CRITICAL }

/**
 * Sealed hierarchy of all messages exchanged between Android and Mac over
 * the federation WebSocket channel.
 *
 * Each subtype serialises to/from JSON via [toJson] / [fromJson].
 * The discriminator field is `"type"` and equals the class simple name.
 */
sealed class FederationMessage {

    abstract val messageId: String
    abstract val timestampMs: Long
    abstract val sourceDeviceId: String
    abstract val correlationId: String

    // ── Subtypes ─────────────────────────────────────────────────────────────

    data class VoiceTranscriptEvent(
        val transcript: String,
        val sessionId: String,
        val language: String,
        val confidenceScore: Float,
        val isFinal: Boolean,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class ContextSnapshotEvent(
        val snapshot: ContextSnapshot,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class PhotoCapturedEvent(
        val filePath: String,
        val mimeType: String,
        val captureReason: String,
        val locationLat: Double?,
        val locationLon: Double?,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class ReminderRequest(
        val label: String,
        val isoDateTime: String,
        val repeatRule: String?,
        val notes: String?,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class WorkflowRequest(
        val workflowId: String,
        val title: String,
        val description: String,
        val payload: Map<String, String>,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class MemoryCaptureRequest(
        val content: String,
        val category: String,
        val source: String,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class ContinueOnMacRequest(
        val contextSnapshot: ContextSnapshot,
        val userPrompt: String,
        val displayHint: String,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class NavigationStateEvent(
        val destinationName: String,
        val destinationAddress: String?,
        val etaMinutes: Int?,
        val isNavigating: Boolean,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class HomeAssistantActionEvent(
        val entityId: String,
        val action: String,
        val attributesJson: String?,
        val success: Boolean,
        val errorMessage: String?,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class DeviceStateEvent(
        val batteryPercent: Int?,
        val isCharging: Boolean?,
        val networkType: String?,
        val isDoNotDisturb: Boolean?,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class MacResponseEvent(
        override val correlationId: String,
        val responseType: MacResponseType,
        val shortSummary: String,
        val fullContent: String?,
        val actionLabel: String?,
        val actionDeepLink: String?,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
    ) : FederationMessage()

    data class MacTaskCompletedEvent(
        val taskId: String,
        val title: String,
        val resultSummary: String,
        val success: Boolean,
        val errorMessage: String?,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    data class MacNotificationEvent(
        val title: String,
        val body: String,
        val priority: NotificationPriority,
        val deepLink: String?,
        override val sourceDeviceId: String,
        override val messageId: String = UUID.randomUUID().toString(),
        override val timestampMs: Long = System.currentTimeMillis(),
        override val correlationId: String = UUID.randomUUID().toString(),
    ) : FederationMessage()

    // ── Serialisation ─────────────────────────────────────────────────────────

    fun toJson(): JSONObject {
        val obj = JSONObject()
        // Common fields
        obj.put("type", this::class.simpleName)
        obj.put("messageId", messageId)
        obj.put("timestampMs", timestampMs)
        obj.put("sourceDeviceId", sourceDeviceId)
        obj.put("correlationId", correlationId)

        when (this) {
            is VoiceTranscriptEvent -> {
                obj.put("transcript", transcript)
                obj.put("sessionId", sessionId)
                obj.put("language", language)
                obj.put("confidenceScore", confidenceScore.toDouble())
                obj.put("isFinal", isFinal)
            }
            is ContextSnapshotEvent -> {
                obj.put("snapshot", snapshot.toJson())
            }
            is PhotoCapturedEvent -> {
                obj.put("filePath", filePath)
                obj.put("mimeType", mimeType)
                obj.put("captureReason", captureReason)
                locationLat?.let { obj.put("locationLat", it) }
                locationLon?.let { obj.put("locationLon", it) }
            }
            is ReminderRequest -> {
                obj.put("label", label)
                obj.put("isoDateTime", isoDateTime)
                repeatRule?.let { obj.put("repeatRule", it) }
                notes?.let { obj.put("notes", it) }
            }
            is WorkflowRequest -> {
                obj.put("workflowId", workflowId)
                obj.put("title", title)
                obj.put("description", description)
                obj.put("payload", mapToJsonObject(payload))
            }
            is MemoryCaptureRequest -> {
                obj.put("content", content)
                obj.put("category", category)
                obj.put("source", source)
            }
            is ContinueOnMacRequest -> {
                obj.put("contextSnapshot", contextSnapshot.toJson())
                obj.put("userPrompt", userPrompt)
                obj.put("displayHint", displayHint)
            }
            is NavigationStateEvent -> {
                obj.put("destinationName", destinationName)
                destinationAddress?.let { obj.put("destinationAddress", it) }
                etaMinutes?.let { obj.put("etaMinutes", it) }
                obj.put("isNavigating", isNavigating)
            }
            is HomeAssistantActionEvent -> {
                obj.put("entityId", entityId)
                obj.put("action", action)
                attributesJson?.let { obj.put("attributesJson", it) }
                obj.put("success", success)
                errorMessage?.let { obj.put("errorMessage", it) }
            }
            is DeviceStateEvent -> {
                batteryPercent?.let { obj.put("batteryPercent", it) }
                isCharging?.let { obj.put("isCharging", it) }
                networkType?.let { obj.put("networkType", it) }
                isDoNotDisturb?.let { obj.put("isDoNotDisturb", it) }
            }
            is MacResponseEvent -> {
                obj.put("responseType", responseType.name)
                obj.put("shortSummary", shortSummary)
                fullContent?.let { obj.put("fullContent", it) }
                actionLabel?.let { obj.put("actionLabel", it) }
                actionDeepLink?.let { obj.put("actionDeepLink", it) }
            }
            is MacTaskCompletedEvent -> {
                obj.put("taskId", taskId)
                obj.put("title", title)
                obj.put("resultSummary", resultSummary)
                obj.put("success", success)
                errorMessage?.let { obj.put("errorMessage", it) }
            }
            is MacNotificationEvent -> {
                obj.put("title", title)
                obj.put("body", body)
                obj.put("priority", priority.name)
                deepLink?.let { obj.put("deepLink", it) }
            }
        }
        return obj
    }

    companion object {
        fun fromJson(json: JSONObject): FederationMessage? {
            return try {
                val type = json.optString("type") ?: return null
                val messageId = json.optString("messageId", UUID.randomUUID().toString())
                val timestampMs = json.optLong("timestampMs", System.currentTimeMillis())
                val sourceDeviceId = json.optString("sourceDeviceId", "")
                val correlationId = json.optString("correlationId", UUID.randomUUID().toString())

                when (type) {
                    "VoiceTranscriptEvent" -> VoiceTranscriptEvent(
                        transcript = json.getString("transcript"),
                        sessionId = json.getString("sessionId"),
                        language = json.optString("language", "en"),
                        confidenceScore = json.optDouble("confidenceScore", 1.0).toFloat(),
                        isFinal = json.optBoolean("isFinal", true),
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "ContextSnapshotEvent" -> ContextSnapshotEvent(
                        snapshot = contextSnapshotFromJson(json.getJSONObject("snapshot")),
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "PhotoCapturedEvent" -> PhotoCapturedEvent(
                        filePath = json.getString("filePath"),
                        mimeType = json.optString("mimeType", "image/jpeg"),
                        captureReason = json.optString("captureReason", ""),
                        locationLat = if (json.has("locationLat")) json.getDouble("locationLat") else null,
                        locationLon = if (json.has("locationLon")) json.getDouble("locationLon") else null,
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "ReminderRequest" -> ReminderRequest(
                        label = json.getString("label"),
                        isoDateTime = json.getString("isoDateTime"),
                        repeatRule = json.optString("repeatRule").takeIf { it.isNotEmpty() },
                        notes = json.optString("notes").takeIf { it.isNotEmpty() },
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "WorkflowRequest" -> WorkflowRequest(
                        workflowId = json.getString("workflowId"),
                        title = json.getString("title"),
                        description = json.getString("description"),
                        payload = jsonObjectToMap(json.optJSONObject("payload")),
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "MemoryCaptureRequest" -> MemoryCaptureRequest(
                        content = json.getString("content"),
                        category = json.optString("category", "general"),
                        source = json.optString("source", "android"),
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "ContinueOnMacRequest" -> ContinueOnMacRequest(
                        contextSnapshot = contextSnapshotFromJson(json.getJSONObject("contextSnapshot")),
                        userPrompt = json.getString("userPrompt"),
                        displayHint = json.optString("displayHint", ""),
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "NavigationStateEvent" -> NavigationStateEvent(
                        destinationName = json.getString("destinationName"),
                        destinationAddress = json.optString("destinationAddress").takeIf { it.isNotEmpty() },
                        etaMinutes = if (json.has("etaMinutes")) json.getInt("etaMinutes") else null,
                        isNavigating = json.optBoolean("isNavigating", false),
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "HomeAssistantActionEvent" -> HomeAssistantActionEvent(
                        entityId = json.getString("entityId"),
                        action = json.getString("action"),
                        attributesJson = json.optString("attributesJson").takeIf { it.isNotEmpty() },
                        success = json.optBoolean("success", false),
                        errorMessage = json.optString("errorMessage").takeIf { it.isNotEmpty() },
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "DeviceStateEvent" -> DeviceStateEvent(
                        batteryPercent = if (json.has("batteryPercent")) json.getInt("batteryPercent") else null,
                        isCharging = if (json.has("isCharging")) json.getBoolean("isCharging") else null,
                        networkType = json.optString("networkType").takeIf { it.isNotEmpty() },
                        isDoNotDisturb = if (json.has("isDoNotDisturb")) json.getBoolean("isDoNotDisturb") else null,
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "MacResponseEvent" -> MacResponseEvent(
                        correlationId = correlationId,
                        responseType = MacResponseType.valueOf(json.optString("responseType", MacResponseType.SHORT_RESPONSE.name)),
                        shortSummary = json.getString("shortSummary"),
                        fullContent = json.optString("fullContent").takeIf { it.isNotEmpty() },
                        actionLabel = json.optString("actionLabel").takeIf { it.isNotEmpty() },
                        actionDeepLink = json.optString("actionDeepLink").takeIf { it.isNotEmpty() },
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                    )
                    "MacTaskCompletedEvent" -> MacTaskCompletedEvent(
                        taskId = json.getString("taskId"),
                        title = json.getString("title"),
                        resultSummary = json.getString("resultSummary"),
                        success = json.optBoolean("success", false),
                        errorMessage = json.optString("errorMessage").takeIf { it.isNotEmpty() },
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    "MacNotificationEvent" -> MacNotificationEvent(
                        title = json.getString("title"),
                        body = json.getString("body"),
                        priority = NotificationPriority.valueOf(json.optString("priority", NotificationPriority.NORMAL.name)),
                        deepLink = json.optString("deepLink").takeIf { it.isNotEmpty() },
                        sourceDeviceId = sourceDeviceId,
                        messageId = messageId,
                        timestampMs = timestampMs,
                        correlationId = correlationId,
                    )
                    else -> {
                        Log.w(TAG, "fromJson: unknown message type '$type' — ignoring")
                        null
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "fromJson: failed to parse message", e)
                null
            }
        }

        private fun jsonObjectToMap(obj: JSONObject?): Map<String, String> {
            if (obj == null) return emptyMap()
            val map = mutableMapOf<String, String>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                map[k] = obj.optString(k, "")
            }
            return map
        }
    }
}

// ── ContextSnapshot JSON helpers ──────────────────────────────────────────────

private fun ContextSnapshot.toJson(): JSONObject {
    val obj = JSONObject()
    val arr = JSONArray()
    transcriptWindow.forEach { arr.put(it) }
    obj.put("transcriptWindow", arr)
    currentIntent?.let { obj.put("currentIntent", it) }
    activeAppPackage?.let { obj.put("activeAppPackage", it) }
    activeAppLabel?.let { obj.put("activeAppLabel", it) }
    locationLat?.let { obj.put("locationLat", it) }
    locationLon?.let { obj.put("locationLon", it) }
    locationLabel?.let { obj.put("locationLabel", it) }
    attachedImagePath?.let { obj.put("attachedImagePath", it) }
    homeAssistantSummary?.let { obj.put("homeAssistantSummary", it) }
    obj.put("pendingTaskCount", pendingTaskCount)
    navigationDestination?.let { obj.put("navigationDestination", it) }
    screenContentSummary?.let { obj.put("screenContentSummary", it) }
    obj.put("capturedAtMs", capturedAtMs)
    return obj
}

internal fun contextSnapshotFromJson(obj: JSONObject): ContextSnapshot {
    val transcriptArr = obj.optJSONArray("transcriptWindow")
    val transcriptWindow = buildList {
        if (transcriptArr != null) {
            for (i in 0 until transcriptArr.length()) add(transcriptArr.getString(i))
        }
    }
    return ContextSnapshot(
        transcriptWindow = transcriptWindow,
        currentIntent = obj.optString("currentIntent").takeIf { it.isNotEmpty() },
        activeAppPackage = obj.optString("activeAppPackage").takeIf { it.isNotEmpty() },
        activeAppLabel = obj.optString("activeAppLabel").takeIf { it.isNotEmpty() },
        locationLat = if (obj.has("locationLat")) obj.getDouble("locationLat") else null,
        locationLon = if (obj.has("locationLon")) obj.getDouble("locationLon") else null,
        locationLabel = obj.optString("locationLabel").takeIf { it.isNotEmpty() },
        attachedImagePath = obj.optString("attachedImagePath").takeIf { it.isNotEmpty() },
        homeAssistantSummary = obj.optString("homeAssistantSummary").takeIf { it.isNotEmpty() },
        pendingTaskCount = obj.optInt("pendingTaskCount", 0),
        navigationDestination = obj.optString("navigationDestination").takeIf { it.isNotEmpty() },
        screenContentSummary = obj.optString("screenContentSummary").takeIf { it.isNotEmpty() },
        capturedAtMs = obj.optLong("capturedAtMs", System.currentTimeMillis()),
    )
}

private fun mapToJsonObject(map: Map<String, String>): JSONObject {
    val obj = JSONObject()
    map.forEach { (k, v) -> obj.put(k, v) }
    return obj
}
