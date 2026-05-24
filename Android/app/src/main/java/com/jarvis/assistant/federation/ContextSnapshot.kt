package com.jarvis.assistant.federation

import java.util.UUID

data class ContextSnapshot(
    val transcriptWindow: List<String> = emptyList(),  // last N utterance pairs
    val currentIntent: String? = null,
    val activeAppPackage: String? = null,
    val activeAppLabel: String? = null,
    val locationLat: Double? = null,
    val locationLon: Double? = null,
    val locationLabel: String? = null,
    val attachedImagePath: String? = null,
    val homeAssistantSummary: String? = null,
    val pendingTaskCount: Int = 0,
    val navigationDestination: String? = null,
    val screenContentSummary: String? = null,
    val capturedAtMs: Long = System.currentTimeMillis(),
)

data class MacTaskRequest(
    val taskId: String = UUID.randomUUID().toString(),
    val taskType: MacTaskType,
    val title: String,
    val description: String,
    val payload: Map<String, String> = emptyMap(),
    val urgency: TaskUrgency = TaskUrgency.NORMAL,
    val returnPreference: ReturnPreference = ReturnPreference.SPOKEN_SUMMARY,
    val contextSnapshot: ContextSnapshot? = null,
    val createdAtMs: Long = System.currentTimeMillis(),
)

enum class MacTaskType {
    CODE_REVIEW, SUMMARISE, SEO_GENERATION, ADMIN_AUDIT, HA_INVESTIGATION,
    LOG_WATCH, IMAGE_PROCESSING, RESEARCH, DATA_ANALYSIS, CUSTOM
}

enum class TaskUrgency { LOW, NORMAL, HIGH, IMMEDIATE }

enum class ReturnPreference { SPOKEN_SUMMARY, FULL_RESPONSE, NOTIFICATION_ONLY, SILENT }
