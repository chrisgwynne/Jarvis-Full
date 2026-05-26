package com.jarvis.assistant.remote.macbridge

/**
 * Snapshot of the role arbitrator's current decision.
 * Consumed by the Settings UI and by JarvisService to drive hot-swap role changes.
 */
data class ArbitratorState(
    val configuredRole      : AndroidRole    = AndroidRole.AUTO,
    val effectiveRole       : EffectiveRole  = EffectiveRole.FULL_ASSISTANT,
    val reason              : String         = "Starting…",
    val macReachable        : Boolean        = false,
    val macAssistantActive  : Boolean        = false,
    val lastActivityAgeMs   : Long           = -1L,
    val conversationalOwner : String         = "android",
)
