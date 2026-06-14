# Situation Room

The Situation Room is Jarvis's **live operational dashboard** — the panel the
user is meant to see first. Per the vision it answers, at a glance:

> Current Focus · Active Goals · Active Projects · Open Issues · Opportunities
> · Recent Wins · System Health · Recommended Next Action

This document covers the domain layer that assembles that state. The Compose
home-screen surface that binds to it is the next step (see *Status* below).

## Layers

```
            ┌──────────────────────────────────────────────┐
 live       │ GoalStore.active        (StateFlow<Goal>)     │
 stores     │ SituationRegistry.snapshot (StateFlow<Sit.>)  │
            │ CrossDeviceHealthModel.snapshot()             │
            └───────────────┬──────────────────────────────┘
                            │  provider seams (default empty):
                            │  ProjectProvider / OpportunityProvider / WinProvider
                            ▼
            ┌──────────────────────────────────────────────┐
 coordinator│ SituationRoomCoordinator                      │
            │   snapshot(): SituationRoomState  (O(1) pull)  │
            │   state(scope): StateFlow<SituationRoomState>  │
            └───────────────┬──────────────────────────────┘
                            ▼
            ┌──────────────────────────────────────────────┐
 pure       │ SituationRoomComposer.compose(...)            │
 policy     │   deterministic, Android-free, fully tested    │
            └──────────────────────────────────────────────┘
```

- **`core/room/SituationRoomModels.kt`** — immutable value types. Inputs Jarvis
  already produces (`Goal`, `Situation`, cross-device health) are consumed
  directly; inputs it doesn't model first-class yet (`Project`, `Opportunity`,
  `Win`) get a small read model here.
- **`core/room/SituationRoomComposer.kt`** — pure assembly + prioritisation. No
  coroutines, no I/O, no Android, so the entire policy is JVM-unit-testable.
- **`core/room/SituationRoomCoordinator.kt`** — wires live stores to the
  composer; exposes both a point-in-time `snapshot()` (cf.
  `CrossDeviceHealthModel`) and a reactive `state(scope)` StateFlow.
- **`core/room/SituationRoomHealth.kt`** — adapts the reliability layer's
  cross-device snapshot into the dashboard's `SystemHealth` shape, kept out of
  the composer so the composer carries no reliability dependency.

## Priority order

**Current Focus** (the one thing to look at) and **Recommended Next Action**
(the one thing to do) are derived from a single order so they never disagree:

1. a `CRITICAL` system-health problem,
2. a high-urgency live situation (`urgency ≥ 0.6`),
3. a blocked project,
4. the nearest-deadline active goal,
5. the strongest opportunity,
6. nothing pressing → *All clear*.

**Open Issues** aggregate, ordered by urgency: degraded/critical system health,
high-urgency situations, and blocked projects.

## Provider seams

`Project`, `Opportunity` and `Win` don't have first-class engines yet, so the
coordinator takes `ProjectProvider` / `OpportunityProvider` / `WinProvider`,
each defaulting to `Empty`. The dashboard renders today with goals, situations
and health; those panels fill in as the engines land — no change to the
composer.

## Status

- [x] Domain models, composer, coordinator, health adapter
- [x] Unit tests (`SituationRoomComposerTest`, `SituationRoomHealthTest`)
- [ ] Compose `SituationRoomScreen` + `ViewModel`, wired as the home surface
- [ ] First-class `Project` store (persisted, editable) behind `ProjectProvider`
- [ ] `OpportunityProvider` backed by the proactive/reflection engines
- [ ] `WinProvider` backed by completed goals / outcome ledger
```
