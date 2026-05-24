# Jarvis Nervous System Completion Sprint — Final Report
*Sprint date: 2026-05-22*  
*Build result: ✅ SUCCEEDED — 0 errors, 0 warnings*

---

## Executive Summary

This sprint closed 4 critical wiring gaps identified in the Platform Maturity Audit, added longitudinal work-session persistence to TaskThreadEngine, and fixed every silent failure path in the LLM fallback layer. The platform moved from **"strong subsystems with missing final wires"** to a coherent, connected runtime.

**8 files changed, 309 insertions, 10 deletions.**

---

## 1. Critical Gap Fixes

### Gap 1 — EventStore startup ordering
**Previous problem:** `EventStore.shared.start()` was called *after* `state = .running` in `SystemRuntime.start()`, meaning events published during the rest of bootstrap were missed by the ring buffer.

**File changed:** `JarvisMac/Core/RuntimeRegistry.swift`  
**Fix:** Reordered to call `EventStore.shared.start()` before setting `state = .running`. Added comment explaining the ordering requirement and documenting that the call is idempotent (EventStore guards against double-subscription with a `busToken` check).  
**Result:** EventStore ring buffer now captures all events from bootstrap onward. RuntimeDiagnosticsOverlay throughput chart is live.  
**Remaining risk:** None. The idempotency guard makes recovery restarts safe.

---

### Gap 2 — LLM fallback silence
**Previous problem:** 6 distinct code paths in `tryLLMFallback()` exited silently — the user heard nothing after a valid wake/listen cycle.

**Files changed:** `JarvisMac/Responses/ResponseTemplate.swift`, `JarvisMac/Responses/ResponsePlaybook.swift`, `JarvisMac/Core/JarvisController.swift`

**New ResponseKeys added:**
| Key | String value | Trigger condition |
|---|---|---|
| `llmUnknownFallback` | `llm.unknown_fallback` | LLM returned `.unknown` intent with no speak text |
| `llmUnavailableFallback` | `llm.unavailable_fallback` | All circuits open / not configured / network error |
| `llmTimeoutFallback` | `llm.timeout_fallback` | LLM request timed out |
| `llmMalformedFallback` | `llm.malformed_fallback` | Response JSON unparseable / bridge parse failed |

**Paths fixed in JarvisController.swift:**
| Line | Path | Fix |
|---|---|---|
| ~6969 | `allCircuitsOpen` guard | speaks `llmUnavailableFallback` |
| ~7091 | catch `LLMError.timeout` | switched to `llmTimeoutFallback` |
| ~7093 | catch `LLMError.notConfigured`/circuit | switched to `llmUnavailableFallback` |
| ~7096 | **NEW** catch all-other-errors (network/auth/500) | speaks `llmUnavailableFallback` |
| ~7112 | `LLMIntentBridge.parse()` returned nil | speaks `llmMalformedFallback` |
| ~7200 | `.unmapped` with empty `speakText` | speaks `llmUnknownFallback` |
| ~7205 | `.parseFailed` bridge-level error | speaks `llmMalformedFallback` |

**Result:** Jarvis never fails with silence after a completed listen cycle. Every LLM failure has a spoken response.  
**Remaining risk:** Responses are not adaptive (same phrase regardless of what the user asked). Future sprint: personalise fallback phrasing using request context.

---

### Gap 3 — VisionModule threat escalation never fires
**Previous problem:** `VisionModule.onThreatEscalated` was wired in JarvisController (lines 1319–1332) but nothing inside VisionModule ever called `onThreatEscalated?()`. Threats were detected but alerts were silently dropped.

**File changed:** `JarvisMac/Vision/VisionModule.swift`

**What was added:**
- 3 new stored properties: `lastCommittedThreatLevel`, `lastThreatEscalationTime`, `threatEscalationCooldown` (30s)
- Call to `maybeTriggerThreatEscalation(feedID:)` in `handleDetectionFrame()` after `threatClassifier.classify()` returns
- New private method `maybeTriggerThreatEscalation(feedID:)` that:
  - Only fires when `currentLevel >= .suspicious`
  - Only fires on a level **increase** (not on sustained same level)
  - Resets on `.normal` so future rises trigger again
  - Respects 30s cooldown to prevent frame-by-frame spam
  - Builds description from `threatClassifier.threatReason` + camera feed name

**Result:** Surveillance threat detection now surfaces to ProactivityEngine and the user.  
**Remaining risk:** `ThreatLevel` comparison uses `Int` backing (`normal=0, suspicious=1, alert=2`). If new levels are added between existing values, ordering could break — document this invariant.

---

### Gap 4 — GitHub code review runs heuristic-only
**Previous problem:** `GitHubModule` was initialized without `llmRouter`, so `GitHubCodeReviewEngine.llmRouter` was permanently nil. All code review used static heuristics.

**Files changed:** `JarvisMac/LLM/LLMRouter.swift`, `JarvisMac/Core/JarvisController.swift`

**What was added:**
- `extension LLMRouter: GHLLMCapable` in `LLMRouter.swift` — thin adapter wrapping `complete(_ request:)` → `complete(prompt:maxTokens:)`
- JarvisController line ~1036: `GitHubModule(token: githubToken)` → `GitHubModule(token: githubToken, llmRouter: llmRouter)`

**Result:** GitHub code review now uses LLM for analysis when a provider is configured. Falls back to heuristics gracefully when LLM is unavailable (existing `if let llm = llmRouter` guard).  
**Remaining risk:** Code review quality depends on LLM context window. Long diffs may be truncated by `maxTokens` limit in `GHLLMCapable.complete(prompt:maxTokens:)`. Future sprint: chunk large diffs.

---

## 2. TaskThread Continuity

**Previous state:** TaskThreadEngine tracked work sessions in memory only. All context lost on every launch.

**File changed:** `JarvisMac/Ambient/TaskThreadEngine.swift` (+178 lines)

### Persistence model
**Dual-layer:**
1. **JSON ring-buffer** at `~/Library/Application Support/JarvisMac/task_threads.json` — primary structural store for reload. Written on `ioQueue` (never blocks main thread). `TaskThread` made `Codable`.
2. **ConversationMemoryStore.shared** — searchable secondary store. Used because `JarvisDatabase` has no `shared` singleton. High-confidence completed threads saved as `.projectProgress` items for LLM retrieval.

### When threads are persisted
- `startNewThread()`: saves `thread_start` phase if `confidence >= 0.6`
- `closeCurrentThread()`: saves `thread_end` + rich memory candidate if `duration >= 2min && confidence >= 0.4`
- Low-confidence transient switches (e.g., Cmd-Tab to check something) do not generate noise

### Startup loading
`loadRecentThreads()` called automatically from `start()`. Merges threads from JSON file, filtering out entries older than 14 days and capping at 50 entries. Does not clobber any threads already started in-session.

### Pruning
14-day age threshold, 50-entry cap. `pruneOldThreads()` is public for manual triggers.

### Query phrases wired in JarvisController
- `.whatAmIWorkingOn`: now uses `taskThreadEngine.lastWorkSummary` when ambient context is unavailable
- `.whatWasIDoingEarlier`: now prepends thread summary to search-based recent activity

### New public API
```swift
var lastWorkSummary: String        // "Last time you were working on Xcode with Terminal."
func threadForQuery(_ query: String) -> TaskThread?   // keyword search on title/apps
func pruneOldThreads()             // manual prune
func loadRecentThreads()           // also called automatically from start()
```

---

## 3. JarvisController Reduction

**Lines before sprint:** ~8,398  
**Lines after sprint:** ~8,436 (+38 — the net of 7 path fixes, 1 GitHub init fix, 2 intent enrichments)

**Note:** This sprint was intentionally NOT a decomposition sprint — the scope was wiring fixes only. A dedicated decomposition sprint is the recommended next step. See Section 8.

---

## 4. Diagnostics Improvements

**EventStore** is now live from bootstrap. All 28+ SystemBus event types are captured in the 1000-event ring buffer from app start.

**RuntimeDiagnosticsOverlay** throughput chart now shows real data.

**New SystemBus events surfaced:**
- Threat escalation signals now flow through ProactivityEngine and are visible in the NotificationTray
- LLM fallback failures now produce ProactivitySignal-adjacent log entries via ExecutionTrace

---

## 5. Help Docs

Updated `Docs/JarvisFeatureHelpAudit.md` — the following features moved from ⚠️ Partial to ✅ Implemented:
- EventStore / RuntimeDiagnosticsOverlay (throughput now real)
- GitHub code review (now LLM-assisted when configured)
- Vision threat escalation (now surfaced to user)
- Work session continuity ("what was I working on last time?")

---

## 6. Build + Test

| Metric | Result |
|---|---|
| Build | ✅ SUCCEEDED |
| Errors | 0 |
| New warnings | 0 |
| Files changed | 8 |
| Lines added | 309 |
| Lines removed | 10 |

**Smoke checklist:**
- [x] Voice pipeline: not touched — no regression risk
- [x] LLM unknown → speaks fallback (was silent)
- [x] EventStore: starts before `state = .running`
- [x] GitHub: `llmRouter` injected — code review uses LLM
- [x] Vision: threat escalation fires on level increase with 30s cooldown
- [x] TaskThread: persists to JSON + ConversationMemoryStore on close
- [x] Intent `.whatAmIWorkingOn`: uses taskThreadEngine.lastWorkSummary
- [x] All existing overlay behaviour: unchanged
- [x] All proactivity providers: unchanged
- [x] Android bridge: unchanged

---

## 7. Risks

| Risk | Severity | Notes |
|---|---|---|
| LLM fallback phrases not personalised | Low | Same response regardless of request. Acceptable for MVP. |
| ThreatLevel Int ordering invariant | Low | Document that new levels must be inserted at end |
| GitHub large-diff truncation | Low | `maxTokens` in GHLLMCapable limits review depth on large PRs |
| TaskThread low-confidence threshold | Low | `0.6` may filter too aggressively on brief sessions — tune after observation |
| JarvisDatabase still not singleton | Info | TaskThread uses ConversationMemoryStore as workaround — acceptable but creates two persistence paths |

---

## 8. Next Sprint Recommendations

In priority order after this sprint:

### Sprint M — Security + Token Hardening
- Move MiniMax/Gemini API keys to Keychain (migration pattern already exists for 5 other tokens)
- Add structural delimiters for Obsidian RAG injection (prompt injection guard)
- Gate `llmSendsScreenContext` default to `false`

### Sprint N — JarvisController Decomposition (First Pass)
- Extract `LLMFallbackHandler` (~200 lines) from `tryLLMFallback`
- Extract `VisionEventBridge` (~80 lines) from vision callback wiring block
- Extract `GitHubIntegrationBootstrapper` (~60 lines) from GitHub bootstrap
- Target: bring JarvisController below 7,500 lines without behaviour change

### Sprint O — Email + Notes Integration
- Apple Mail AppleScript (A2) — `AppleScriptRunner.swift` already exists
- Apple Notes (A12) — single `tell application "Notes"` call
- Email proactivity provider (VIP/keyword based)

### Sprint P — Web Search Provider
- Replace `NoopWebSearchProvider` with DDG or Brave API
- Transforms LLM factual queries from guesses to real answers

### Sprint Q — RTSP Cleanup
- Fix `RTSPStreamManager.stopAllDetectionLoops()` body (currently comment-only — P0 memory leak)
- Fix motion zone default `cameraFeedID: UUID()` — should use real feed ID

---

*End of sprint report.*
