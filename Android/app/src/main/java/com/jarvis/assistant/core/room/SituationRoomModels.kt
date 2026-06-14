package com.jarvis.assistant.core.room

import com.jarvis.assistant.core.goals.Goal
import com.jarvis.assistant.core.situations.Situation

/**
 * Situation Room — the live operational dashboard the user sees first.
 *
 * This file holds the *value types* the Situation Room is built from. The
 * assembly logic lives in [SituationRoomComposer]; the wiring to live stores
 * lives in [SituationRoomCoordinator].
 *
 * Design rules:
 *   - Everything here is an immutable, Android-free data class so the whole
 *     layer is unit-testable on the JVM with no device, no Room, no coroutines.
 *   - Inputs the rest of Jarvis already produces ([Goal], [Situation],
 *     cross-device health) are consumed directly. Inputs Jarvis does not yet
 *     model first-class ([Project], [Opportunity], [Win]) get a small value
 *     type here plus a provider seam in [SituationRoomCoordinator], so the
 *     dashboard renders today and richer systems plug in later without
 *     touching the composer.
 */

// ---------------------------------------------------------------------------
// Inputs that Jarvis does not yet model elsewhere
// ---------------------------------------------------------------------------

/** Lifecycle of a [Project] as far as the dashboard cares. */
enum class ProjectStatus { ACTIVE, BLOCKED, PAUSED, COMPLETED }

/**
 * Project — a first-class unit of work, per the Jarvis vision ("Not files.
 * Projects."). Persistence and editing are future work; this is the read
 * model the dashboard renders.
 *
 * @param progress 0..1 completion estimate.
 * @param blockers human-readable reasons the project can't currently advance.
 */
data class Project(
    val id: String,
    val title: String,
    val objective: String = "",
    val status: ProjectStatus = ProjectStatus.ACTIVE,
    val progress: Float = 0f,
    val blockers: List<String> = emptyList(),
    val updatedAtMs: Long = 0L,
) {
    val isBlocked: Boolean
        get() = status == ProjectStatus.BLOCKED || blockers.isNotEmpty()
}

/** What kind of opening the Opportunity Engine has spotted. */
enum class OpportunityKind { AUTOMATION, BUSINESS, GROWTH, SYSTEM, INTEGRATION }

/**
 * Opportunity — something Jarvis proactively believes is worth the user's
 * attention (an automation to build, a business lever, a missing system).
 *
 * @param score 0..1 — how strongly Jarvis rates this opportunity.
 */
data class Opportunity(
    val id: String,
    val title: String,
    val kind: OpportunityKind,
    val rationale: String = "",
    val score: Float = 0f,
)

/** Win — a recent positive outcome worth surfacing for momentum. */
data class Win(
    val title: String,
    val achievedAtMs: Long,
    val detail: String = "",
)

/** Coarse health classification for the dashboard's System Health panel. */
enum class HealthStatus { OK, DEGRADED, CRITICAL, UNKNOWN }

/**
 * SystemHealth — the dashboard's view of how the wider Jarvis system is doing.
 * Typically adapted from the reliability layer's cross-device snapshot.
 */
data class SystemHealth(
    val status: HealthStatus,
    val summary: String,
    val issues: List<String> = emptyList(),
) {
    companion object {
        val UNKNOWN = SystemHealth(HealthStatus.UNKNOWN, "Status unknown")
        val OK = SystemHealth(HealthStatus.OK, "All systems nominal")
    }
}

// ---------------------------------------------------------------------------
// Output: the assembled dashboard state
// ---------------------------------------------------------------------------

/** Where the user's [FocusItem] was derived from. */
enum class FocusSource { SYSTEM, SITUATION, PROJECT, GOAL, OPPORTUNITY, IDLE }

/** The single most important thing right now, rendered at the top of the room. */
data class FocusItem(
    val label: String,
    val source: FocusSource,
)

/** Which subsystem an [OpenIssue] came from. */
enum class IssueKind { SYSTEM, SITUATION, PROJECT_BLOCKER }

/** Something currently demanding attention, ordered by [urgency] (0..1). */
data class OpenIssue(
    val title: String,
    val urgency: Float,
    val kind: IssueKind,
    val detail: String = "",
)

/** How hard the recommended next action is pushing. */
enum class ActionPriority { CRITICAL, HIGH, MEDIUM, LOW }

/** The one thing Jarvis recommends doing next. */
data class NextAction(
    val label: String,
    val rationale: String,
    val priority: ActionPriority,
)

/**
 * SituationRoomState — the complete, immutable snapshot the home screen binds
 * to. Mirrors the panels named in the vision: Current Focus, Active Goals,
 * Active Projects, Open Issues, Opportunities, Recent Wins, System Health and
 * a single Recommended Next Action.
 */
data class SituationRoomState(
    val generatedAtMs: Long,
    val currentFocus: FocusItem,
    val activeGoals: List<Goal>,
    val activeProjects: List<Project>,
    val openIssues: List<OpenIssue>,
    val opportunities: List<Opportunity>,
    val recentWins: List<Win>,
    val systemHealth: SystemHealth,
    val recommendedNextAction: NextAction?,
)
