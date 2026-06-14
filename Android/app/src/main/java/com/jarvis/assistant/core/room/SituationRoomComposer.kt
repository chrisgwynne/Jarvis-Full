package com.jarvis.assistant.core.room

import com.jarvis.assistant.core.goals.Goal
import com.jarvis.assistant.core.situations.Situation

/**
 * SituationRoomComposer — pure assembly of a [SituationRoomState].
 *
 * Takes point-in-time snapshots of every contributing system and folds them
 * into the single immutable state the dashboard renders. No coroutines, no
 * I/O, no Android — deterministic given its inputs and a clock, so the whole
 * prioritisation policy is exercised by ordinary JVM unit tests.
 *
 * The two judgement calls the room makes — **Current Focus** (the one thing to
 * look at) and **Recommended Next Action** (the one thing to do) — are derived
 * here from a single priority order so they never disagree about what matters:
 *
 *   1. a CRITICAL system-health problem,
 *   2. a high-urgency live situation,
 *   3. a blocked project,
 *   4. the nearest-deadline active goal,
 *   5. the strongest opportunity,
 *   6. nothing pressing → "all clear".
 */
object SituationRoomComposer {

    /** A situation at or above this urgency is treated as an open issue and
     *  can claim Current Focus / the next action. */
    const val HIGH_URGENCY = 0.6f

    /** Most recent wins to surface for momentum. */
    const val RECENT_WINS_CAP = 5

    fun compose(
        nowMs: Long,
        goals: List<Goal>,
        situations: List<Situation>,
        projects: List<Project> = emptyList(),
        opportunities: List<Opportunity> = emptyList(),
        recentWins: List<Win> = emptyList(),
        health: SystemHealth = SystemHealth.UNKNOWN,
    ): SituationRoomState {
        // Active goals, nearest deadline first — that's the one most likely to
        // need a nudge.
        val activeGoals = goals
            .filter { it.isActive(nowMs) }
            .sortedBy { it.expiresAtMs }

        // Live situations, most pressing first.
        val liveSituations = situations
            .filterNot { it.isExpired(nowMs) }
            .sortedByDescending { it.weight }

        // Projects worth showing: anything in flight or stuck, freshest first.
        val activeProjects = projects
            .filter { it.status == ProjectStatus.ACTIVE || it.status == ProjectStatus.BLOCKED }
            .sortedByDescending { it.updatedAtMs }
        val blockedProject = activeProjects.firstOrNull { it.isBlocked }

        val sortedOpportunities = opportunities.sortedByDescending { it.score }
        val topOpportunity = sortedOpportunities.firstOrNull()

        val wins = recentWins
            .sortedByDescending { it.achievedAtMs }
            .take(RECENT_WINS_CAP)

        val openIssues = buildOpenIssues(health, liveSituations, activeProjects)
        val topSituation = liveSituations.firstOrNull()
        val pressingSituation = liveSituations.firstOrNull { it.urgency >= HIGH_URGENCY }
        val nearestGoal = activeGoals.firstOrNull()

        val focus = chooseFocus(
            health = health,
            topSituation = topSituation,
            blockedProject = blockedProject,
            nearestGoal = nearestGoal,
            topProject = activeProjects.firstOrNull(),
            topOpportunity = topOpportunity,
        )

        val nextAction = chooseNextAction(
            health = health,
            pressingSituation = pressingSituation,
            blockedProject = blockedProject,
            nearestGoal = nearestGoal,
            topOpportunity = topOpportunity,
        )

        return SituationRoomState(
            generatedAtMs = nowMs,
            currentFocus = focus,
            activeGoals = activeGoals,
            activeProjects = activeProjects,
            openIssues = openIssues,
            opportunities = sortedOpportunities,
            recentWins = wins,
            systemHealth = health,
            recommendedNextAction = nextAction,
        )
    }

    private fun buildOpenIssues(
        health: SystemHealth,
        liveSituations: List<Situation>,
        activeProjects: List<Project>,
    ): List<OpenIssue> {
        val issues = mutableListOf<OpenIssue>()

        if (health.status == HealthStatus.CRITICAL || health.status == HealthStatus.DEGRADED) {
            val urgency = if (health.status == HealthStatus.CRITICAL) 1f else 0.7f
            issues += OpenIssue(
                title = health.summary,
                urgency = urgency,
                kind = IssueKind.SYSTEM,
                detail = health.issues.joinToString("; "),
            )
        }

        liveSituations
            .filter { it.urgency >= HIGH_URGENCY }
            .forEach { s ->
                issues += OpenIssue(
                    title = s.summary,
                    urgency = s.urgency,
                    kind = IssueKind.SITUATION,
                    detail = s.evidence.joinToString("; "),
                )
            }

        activeProjects
            .filter { it.isBlocked }
            .forEach { p ->
                issues += OpenIssue(
                    title = "${p.title} is blocked",
                    urgency = 0.65f,
                    kind = IssueKind.PROJECT_BLOCKER,
                    detail = p.blockers.joinToString("; "),
                )
            }

        return issues.sortedByDescending { it.urgency }
    }

    private fun chooseFocus(
        health: SystemHealth,
        topSituation: Situation?,
        blockedProject: Project?,
        nearestGoal: Goal?,
        topProject: Project?,
        topOpportunity: Opportunity?,
    ): FocusItem = when {
        health.status == HealthStatus.CRITICAL ->
            FocusItem(health.summary, FocusSource.SYSTEM)
        topSituation != null ->
            FocusItem(topSituation.summary, FocusSource.SITUATION)
        blockedProject != null ->
            FocusItem("Unblock ${blockedProject.title}", FocusSource.PROJECT)
        nearestGoal != null ->
            FocusItem(nearestGoal.title, FocusSource.GOAL)
        topProject != null ->
            FocusItem(topProject.title, FocusSource.PROJECT)
        topOpportunity != null ->
            FocusItem(topOpportunity.title, FocusSource.OPPORTUNITY)
        else ->
            FocusItem("All clear", FocusSource.IDLE)
    }

    private fun chooseNextAction(
        health: SystemHealth,
        pressingSituation: Situation?,
        blockedProject: Project?,
        nearestGoal: Goal?,
        topOpportunity: Opportunity?,
    ): NextAction? = when {
        health.status == HealthStatus.CRITICAL -> NextAction(
            label = "Resolve: ${health.summary}",
            rationale = health.issues.firstOrNull() ?: "System is in a critical state.",
            priority = ActionPriority.CRITICAL,
        )
        pressingSituation != null -> NextAction(
            label = pressingSituation.summary,
            rationale = pressingSituation.evidence.firstOrNull() ?: "A pressing situation is active.",
            priority = ActionPriority.HIGH,
        )
        blockedProject != null -> NextAction(
            label = "Unblock ${blockedProject.title}",
            rationale = blockedProject.blockers.firstOrNull() ?: "Project is blocked.",
            priority = ActionPriority.HIGH,
        )
        nearestGoal != null -> NextAction(
            label = "Advance: ${nearestGoal.title}",
            rationale = nearestGoal.evidence.firstOrNull() ?: "Active goal with the nearest deadline.",
            priority = ActionPriority.MEDIUM,
        )
        topOpportunity != null -> NextAction(
            label = "Consider: ${topOpportunity.title}",
            rationale = topOpportunity.rationale.ifBlank { "Opportunity worth a look." },
            priority = ActionPriority.LOW,
        )
        else -> null
    }
}
