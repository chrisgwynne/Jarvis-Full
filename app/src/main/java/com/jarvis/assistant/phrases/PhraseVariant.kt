package com.jarvis.assistant.phrases

data class PhraseVariant(
    val id: String = java.util.UUID.randomUUID().toString(),
    val text: String,
    val isEnabled: Boolean = true,
    val condition: String? = null,   // optional: "driving", "night", "brief" — future use
    val isDefault: Boolean = false,
    val updatedAtMs: Long = System.currentTimeMillis(),
)
