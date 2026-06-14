package com.jarvis.assistant.core.room

import com.jarvis.assistant.core.goals.GoalStore
import com.jarvis.assistant.core.situations.SituationRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

/**
 * SituationRoomCoordinator — wires the live Jarvis stores into
 * [SituationRoomComposer] and exposes the assembled dashboard state.
 *
 * Sources:
 *   - [GoalStore.active]        — persisted active goals (StateFlow)
 *   - [SituationRegistry.snapshot] — ephemeral live situations (StateFlow)
 *   - [ProjectProvider] / [OpportunityProvider] / [WinProvider] — seams for
 *     systems Jarvis doesn't model first-class yet. They default to empty, so
 *     the room renders today and gets richer as those engines land.
 *   - [healthSupplier] — pulls a [SystemHealth] each time the room is rebuilt
 *     (typically adapting the reliability layer's cross-device snapshot).
 *
 * Two ways to read the room, mirroring the rest of the codebase:
 *   - [snapshot] — O(1) pull of the current state (cf. CrossDeviceHealthModel).
 *   - [state]    — a reactive [StateFlow] that re-composes whenever goals or
 *     situations change, for the dashboard to collect.
 */
class SituationRoomCoordinator(
    private val goalStore: GoalStore,
    private val situationRegistry: SituationRegistry,
    private val projects: ProjectProvider = ProjectProvider.Empty,
    private val opportunities: OpportunityProvider = OpportunityProvider.Empty,
    private val wins: WinProvider = WinProvider.Empty,
    private val healthSupplier: () -> SystemHealth = { SystemHealth.UNKNOWN },
    private val nowMs: () -> Long = System::currentTimeMillis,
) {

    /** Point-in-time assembly from whatever the stores currently hold. */
    fun snapshot(): SituationRoomState = SituationRoomComposer.compose(
        nowMs = nowMs(),
        goals = goalStore.active.value,
        situations = situationRegistry.snapshot.value,
        projects = projects.activeProjects(),
        opportunities = opportunities.opportunities(),
        recentWins = wins.recentWins(),
        health = healthSupplier(),
    )

    /**
     * Reactive dashboard state. Re-composes on every goal/situation change.
     * Project/opportunity/win/health inputs are pulled afresh on each
     * re-composition, so updates to those surface on the next goal or
     * situation tick (good enough for a status dashboard; no polling).
     */
    fun state(scope: CoroutineScope): StateFlow<SituationRoomState> =
        combine(goalStore.active, situationRegistry.snapshot) { _, _ -> snapshot() }
            .stateIn(scope, SharingStarted.Eagerly, snapshot())
}

/** Source of first-class projects for the Situation Room. */
fun interface ProjectProvider {
    fun activeProjects(): List<Project>

    companion object {
        val Empty = ProjectProvider { emptyList() }
    }
}

/** Source of proactively-surfaced opportunities for the Situation Room. */
fun interface OpportunityProvider {
    fun opportunities(): List<Opportunity>

    companion object {
        val Empty = OpportunityProvider { emptyList() }
    }
}

/** Source of recent wins for the Situation Room's momentum panel. */
fun interface WinProvider {
    fun recentWins(): List<Win>

    companion object {
        val Empty = WinProvider { emptyList() }
    }
}
