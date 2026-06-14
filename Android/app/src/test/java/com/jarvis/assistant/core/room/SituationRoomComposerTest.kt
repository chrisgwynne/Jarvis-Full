package com.jarvis.assistant.core.room

import com.jarvis.assistant.core.goals.Goal
import com.jarvis.assistant.core.goals.GoalType
import com.jarvis.assistant.core.situations.Situation
import com.jarvis.assistant.core.situations.SituationType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SituationRoomComposerTest {

    private val now = 1_714_000_000_000L

    private fun goal(
        title: String,
        expiresInMs: Long,
        type: GoalType = GoalType.AD_HOC,
        status: String = Goal.STATUS_ACTIVE,
    ) = Goal(
        type = type,
        title = title,
        status = status,
        rootDedupeKey = "k:$title",
        createdAtMs = now,
        updatedAtMs = now,
        expiresAtMs = now + expiresInMs,
    )

    private fun situation(
        summary: String,
        urgency: Float,
        confidence: Float = 0.8f,
        expiresInMs: Long = 60_000L,
        type: SituationType = SituationType.LEAVING_HOME_SOON,
    ) = Situation(
        type = type,
        confidence = confidence,
        urgency = urgency,
        createdAtMs = now,
        expiresAtMs = now + expiresInMs,
        evidence = listOf("because $summary"),
        sourceSignals = emptyList(),
        summary = summary,
    )

    @Test
    fun `empty inputs yield all-clear focus and no action`() {
        val state = SituationRoomComposer.compose(
            nowMs = now,
            goals = emptyList(),
            situations = emptyList(),
        )
        assertEquals(FocusSource.IDLE, state.currentFocus.source)
        assertEquals("All clear", state.currentFocus.label)
        assertNull(state.recommendedNextAction)
        assertTrue(state.openIssues.isEmpty())
        assertTrue(state.activeGoals.isEmpty())
    }

    @Test
    fun `critical health dominates focus and next action`() {
        val state = SituationRoomComposer.compose(
            nowMs = now,
            goals = listOf(goal("leave", 10_000L)),
            situations = listOf(situation("about to leave", urgency = 0.9f)),
            health = SystemHealth(HealthStatus.CRITICAL, "Wake detection is down", listOf("detector off")),
        )
        assertEquals(FocusSource.SYSTEM, state.currentFocus.source)
        assertEquals(ActionPriority.CRITICAL, state.recommendedNextAction?.priority)
        // System issue ranks first among open issues.
        assertEquals(IssueKind.SYSTEM, state.openIssues.first().kind)
    }

    @Test
    fun `high-urgency situation drives focus and a high-priority action`() {
        val state = SituationRoomComposer.compose(
            nowMs = now,
            goals = listOf(goal("leave", 10_000L)),
            situations = listOf(situation("about to miss the train", urgency = 0.85f)),
            health = SystemHealth.OK,
        )
        assertEquals(FocusSource.SITUATION, state.currentFocus.source)
        assertEquals("about to miss the train", state.currentFocus.label)
        assertEquals(ActionPriority.HIGH, state.recommendedNextAction?.priority)
        assertTrue(state.openIssues.any { it.kind == IssueKind.SITUATION })
    }

    @Test
    fun `low-urgency situation is not an open issue but still focus`() {
        val state = SituationRoomComposer.compose(
            nowMs = now,
            goals = emptyList(),
            situations = listOf(situation("mild context", urgency = 0.2f)),
            health = SystemHealth.OK,
        )
        assertEquals(FocusSource.SITUATION, state.currentFocus.source)
        // Below HIGH_URGENCY → not surfaced as an issue, and not the next action.
        assertTrue(state.openIssues.none { it.kind == IssueKind.SITUATION })
        assertNull(state.recommendedNextAction)
    }

    @Test
    fun `goals are filtered by expiry and sorted nearest-deadline first`() {
        val state = SituationRoomComposer.compose(
            nowMs = now,
            goals = listOf(
                goal("far", 90_000L),
                goal("expired", -1_000L),
                goal("soon", 5_000L),
            ),
            situations = emptyList(),
            health = SystemHealth.OK,
        )
        assertEquals(listOf("soon", "far"), state.activeGoals.map { it.title })
        assertEquals(FocusSource.GOAL, state.currentFocus.source)
        assertEquals("soon", state.currentFocus.label)
        assertEquals(ActionPriority.MEDIUM, state.recommendedNextAction?.priority)
    }

    @Test
    fun `blocked project surfaces as issue and high-priority unblock action`() {
        val project = Project(
            id = "p1",
            title = "Launch store",
            status = ProjectStatus.BLOCKED,
            blockers = listOf("Waiting on photos"),
            updatedAtMs = now,
        )
        val state = SituationRoomComposer.compose(
            nowMs = now,
            goals = emptyList(),
            situations = emptyList(),
            projects = listOf(project),
            health = SystemHealth.OK,
        )
        assertEquals(FocusSource.PROJECT, state.currentFocus.source)
        assertEquals("Unblock Launch store", state.recommendedNextAction?.label)
        assertEquals(ActionPriority.HIGH, state.recommendedNextAction?.priority)
        assertTrue(state.openIssues.any { it.kind == IssueKind.PROJECT_BLOCKER })
    }

    @Test
    fun `paused and completed projects are excluded from active list`() {
        val state = SituationRoomComposer.compose(
            nowMs = now,
            goals = emptyList(),
            situations = emptyList(),
            projects = listOf(
                Project(id = "a", title = "Active", status = ProjectStatus.ACTIVE, updatedAtMs = now),
                Project(id = "b", title = "Paused", status = ProjectStatus.PAUSED, updatedAtMs = now),
                Project(id = "c", title = "Done", status = ProjectStatus.COMPLETED, updatedAtMs = now),
            ),
            health = SystemHealth.OK,
        )
        assertEquals(listOf("Active"), state.activeProjects.map { it.title })
    }

    @Test
    fun `opportunity is the lowest-priority fallback action and sorted by score`() {
        val state = SituationRoomComposer.compose(
            nowMs = now,
            goals = emptyList(),
            situations = emptyList(),
            opportunities = listOf(
                Opportunity(id = "o1", title = "Automate invoices", kind = OpportunityKind.AUTOMATION, score = 0.4f),
                Opportunity(id = "o2", title = "Add GA4", kind = OpportunityKind.INTEGRATION, score = 0.9f),
            ),
            health = SystemHealth.OK,
        )
        assertEquals(listOf("Add GA4", "Automate invoices"), state.opportunities.map { it.title })
        assertEquals(ActionPriority.LOW, state.recommendedNextAction?.priority)
        assertEquals("Consider: Add GA4", state.recommendedNextAction?.label)
        assertEquals(FocusSource.OPPORTUNITY, state.currentFocus.source)
    }

    @Test
    fun `recent wins are sorted newest-first and capped`() {
        val wins = (1..8).map { Win(title = "win$it", achievedAtMs = now + it * 1000L) }
        val state = SituationRoomComposer.compose(
            nowMs = now,
            goals = emptyList(),
            situations = emptyList(),
            recentWins = wins,
            health = SystemHealth.OK,
        )
        assertEquals(SituationRoomComposer.RECENT_WINS_CAP, state.recentWins.size)
        assertEquals("win8", state.recentWins.first().title)
        assertEquals("win4", state.recentWins.last().title)
    }

    @Test
    fun `expired situations are excluded entirely`() {
        val state = SituationRoomComposer.compose(
            nowMs = now,
            goals = emptyList(),
            situations = listOf(situation("stale", urgency = 0.9f, expiresInMs = -1L)),
            health = SystemHealth.OK,
        )
        assertEquals(FocusSource.IDLE, state.currentFocus.source)
        assertTrue(state.openIssues.isEmpty())
    }
}
