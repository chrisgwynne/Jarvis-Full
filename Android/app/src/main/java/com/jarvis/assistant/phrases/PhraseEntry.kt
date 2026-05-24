package com.jarvis.assistant.phrases

data class PhraseEntry(
    val key: String,
    val category: PhraseCategory,
    val defaultText: String,
    val description: String,          // describes where it's used, what vars are available
    val availableVars: List<String>,  // e.g. ["contact", "app"]
    val variants: List<PhraseVariant> = emptyList(),
    val isEnabled: Boolean = true,
    val packId: String = "default",
    val updatedAtMs: Long = System.currentTimeMillis(),
)
