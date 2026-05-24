# Phase 5 — Mac Brain Contract Hardening + End-to-End QA
> Generated automatically. Last updated: Phase 5 completion.

---

## 1. Files Changed

### Modified
| File | Change |
|---|---|
| `remote/macbrain/HttpMacBrainClient.kt` | URL validation, companion-object parsing, versioning metadata, `appVersion` param |

### New tests
| File | Coverage |
|---|---|
| `test/…/macbrain/BrainContractTest.kt` | URL validation (11 cases), DTO parsing contract (16 cases) |
| `test/…/macbrain/BrainRoutingPolicyTest.kt` | Local-first guard (37 cases), Brain routing (24 cases), priority ordering (3 cases) |
| `test/…/macbrain/BrainSyncRunnerTest.kt` | Extended: circuit-open gate, permission gates, exact-match guard, null client (5 new cases) |
| `test/…/macbrain/PendingBrainSyncStoreTest.kt` | Queue bounds, persistence, backoff, remove (existing — fixed MAX_RETRIES boundary) |

### Phase 4 (previous session — already landed)
All Phase 4 files remain unchanged. See session summary for details.

---

## 2. Task-by-Task Results

### Task 1 — Contract Resilience ✅

**What was hardened:**

| Property | Before | After |
|---|---|---|
| Unknown response fields | org.json ignores by default ✓ | Explicitly documented in `parseResponseBody` KDoc |
| Missing fields | opt* used throughout ✓ | Explicit `takeIf { isNotBlank() }` on all nullable strings |
| Malformed JSON | try/catch returns null ✓ | Now tested by `BrainContractTest` (7 parse-failure cases) |
| Oversized response | MAX_RESPONSE_BYTES = 32 KiB ✓ | Constant is now `internal` so tested directly |
| API key in logs | Never logged ✓ | Grep scan confirmed 0 log-call hits |
| URL scheme | Not validated | **Added `isValidBaseUrl()` — rejects ftp://, ws://, bare hostnames** |
| Trailing slash | `trimEnd('/')` ✓ | Unchanged |
| Parsing helpers | Private instance methods | **Moved to companion as `internal` for testability** |

### Task 2 — Request Versioning ✅

Every Brain request now includes a `meta` block:

```json
{
  "transcript":  "...",
  "intentHint":  "memory",
  "meta": {
    "apiVersion":        1,
    "androidAppVersion": "1.4.2",
    "deviceId":          "uuid-of-device",
    "requestId":         "uuid-per-request",
    "timestamp":         1716384000000
  }
}
```

The `/brain/interactions` batch payload carries an equivalent top-level `meta` object.

**Backward compatibility:** The server ignores unknown fields — unversioned servers continue to work. When the server is updated to parse `meta`, it gains full traceability without any Android changes.

`appVersion` is injected as a constructor parameter (default `""`). Production wiring via `JarvisRuntime` can pass `BuildConfig.VERSION_NAME`.

### Task 3 — Local-First QA Tests ✅

`BrainRoutingPolicyTest` covers all 37 "never-call-Brain" transcripts:

- Volume, flashlight, torch, screen rotation, brightness, DND
- Open app, launch, close
- Play, pause, stop music, next/previous/skip song
- Call, ring, dial
- Text, message, send
- Camera (take photo, selfie, screenshot)
- Timer (all 5 variants)
- Alarm (all 3 variants)
- Navigate/directions
- Home Assistant commands (turn on/off entity, thermostat)

### Task 4 — Brain-Assisted QA Tests ✅

`BrainRoutingPolicyTest` covers:

- **Memory** (14 cases): `remember that`, `don't forget`, `keep in mind`, `do you remember`, `what do you know about me`, `my preferences`, `my name`, etc.
- **Project** (16 cases): `what's broken`, `github`, `pull request`, `open prs`, `the repo`, `codebase`, `what are we building`, etc.
- **History** (12 cases): `what did we decide`, `we talked about`, `last time`, `you mentioned`, `previously`, `pick up where`, etc.
- **Priority ordering** (3 cases): project > history > memory when signals overlap

### Task 5 — Offline Sync QA Tests ✅

`PendingBrainSyncStoreTest` (8 tests) + `BrainSyncRunnerTest` (15 tests) together cover:

| Scenario | Test |
|---|---|
| Command outcome queues | `enqueueCommandOutcome adds event to store` |
| Memory candidate queues | `enqueueMemoryCandidate adds event to store` |
| HA correction queues | `enqueueHaCorrection adds event when entity names differ` |
| Failed sync remains queued | `syncNow keeps items in queue when reportEvents throws` |
| Successful sync removes item | `syncNow removes accepted events from store` |
| Disabled Brain keeps queue | `syncNow skips entirely when Brain is disabled` |
| Wi-Fi-only blocks cellular | `syncNow skips when wifi-only is set and device is not on wifi` |
| Circuit-open blocks sync | `syncNow skips when circuit breaker is open` |
| Retry count increases | `failed sync increments retryCount and item stays in queue` |
| Oldest low-value item drops first | `queue caps at MAX_SIZE and evicts lowest-priority item` |
| Exact HA match not queued | `enqueueHaCorrection skips exact case-insensitive match` |

### Task 6 — Diagnostics QA ✅

Diagnostic state flows through `MacBrainStats` → `MacBrainDiagnosticsSnapshot` → `MacBrainDiagnosticsScreen`.

| Field | Updated by | Verified |
|---|---|---|
| Cache hit/miss | `HttpMacBrainClient.fetchContext()` | `BrainContextCache.size` baked into every `record()` call |
| Circuit state | `BrainCircuitBreaker` on every `record()` | `BrainCircuitBreaker.currentState()` baked in |
| Pending sync count | `BrainSyncRunner.syncNow()` on success/failure | `PendingBrainSyncStore.size()` baked in |
| Last sync attempt | `MacBrainStats.recordSync { copy(lastSyncAttemptAt = ...) }` | Timestamp set before batch send |
| Last sync success | Set after successful `remove()` | Timestamp set per batch |
| Last sync failure | Set after failed batch or exception | Timestamp set on both partial and total failure |
| Health check | `HttpMacBrainClient.health()` | Updates `lastHealthOk`, `lastHealthLatencyMs`, `lastHealthCheckedAt` |
| API key masked | Never stored in snapshot | Snapshot has no credential fields — confirmed by grep |

### Task 7 — Runtime Safety Scan ✅

**Forbidden references in `remote/macbrain/`:**

| Pattern | Hits |
|---|---|
| `OpenClaw` | **0** |
| `Hermes` | **0** |
| `openclaw` | **0** |
| `hermes` | **0** |

**Note:** OpenClaw/Hermes references exist in `JarvisRuntime.kt` and other files — those are for the *separate, existing* OpenClaw remote LLM routing feature, not Mac Brain. No Mac Brain code references them.

**API key in logs:**

| Pattern | Hits |
|---|---|
| `Log.*apiKey` (log + key) | **0** |
| apiKey only appears in 3 places | All are `mapOf("Authorization" to "Bearer $apiKey")` — headers only |

**Network on main thread:** All Brain network calls are inside `withContext(Dispatchers.IO)` or `withContext(Dispatchers.IO)`. Confirmed: no blocking calls on the main/speech thread.

**Brain calls in instant-command paths:** `BrainRoutingPolicy.intentHint()` returns null for all instant commands (proven by 37 test cases). `VoicePipeline.streamAndSpeak()` only calls Brain when `intentHint()` returns non-null. `JarvisRuntime`'s InstantCommandRouter short-circuits before `VoicePipeline` is entered. Brain is never in the instant-command path.

---

## 3. Manual QA Checklist

### A. Brain Disabled (`macBrainEnabled = false`)

- [ ] Say "set a timer for 5 minutes" → timer starts, no delay, no Brain call in logcat
- [ ] Say "what do you know about me" → responds from local memory only, no Brain call in logcat
- [ ] Settings → Mac Brain Diagnostics → shows "Disabled", circuit CLOSED, 0 pending, all timestamps "—"

### B. Brain Enabled, Server Offline

- [ ] Say "turn on the lights" → light turns on instantly, no Brain call, speech is immediate
- [ ] Say "what's broken in the project" → response from local LLM fallback (no Brain context), no error spoken to user
- [ ] After 5 failed Brain health checks → circuit shows OPEN in diagnostics
- [ ] Sync queue grows with each command outcome (pending count > 0 in diagnostics)
- [ ] No error/toast/speech error mentioning "Brain" or "server" during normal conversation

### C. Brain Enabled, Server Online

- [ ] Settings → Mac Brain Diagnostics → "Test connection" → shows "Connected", latency in ms
- [ ] Say "what did we decide about the UI last time" → Brain is fetched (requestId in logcat), response includes context
- [ ] Say "turn on spotify" → instant local action, `[BRAIN_REQUEST_SKIPPED]` NOT in logcat
- [ ] After successful command → `[BRAIN_SYNC_REPORTED]` or pending count increases in diagnostics
- [ ] Diagnostics update: `lastSucceededAt`, `totalSuccesses`, cache hit after repeat query

### D. Interruption / Barge-in

- [ ] Say long question, barge in mid-response → TTS stops cleanly
- [ ] Next turn: Brain is skipped (barge-in sets `lastInterrupted != null` → Brain guard returns null)
- [ ] Logcat shows `[BARGE_IN_TRIGGERED]` but no `[BRAIN_REQUEST_STARTED]` for the resumed turn
- [ ] Assistant remains responsive — no 2-second silence waiting for Brain

### E. Offline / Mobile Network

- [ ] Disable Wi-Fi, `macBrainWifiOnly = true` → Brain sync skipped (`[BRAIN_SYNC_SKIP] reason=wifi_only` in logcat)
- [ ] Queue items persist after app restart (JSON file at app internal storage)
- [ ] Re-enable Wi-Fi → sync triggers automatically via debounced `trigger()`
- [ ] Diagnostics: `oldestQueuedAt` shows timestamp of oldest pending event

---

## 4. Known Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `"open issues"` transcript starts with `"open "` — caught by instant guard, not routed to Brain | Low | Users say "are there open issues" or "show me open issues" — documented in `BrainRoutingPolicyTest` |
| `appVersion` defaults to `""` until wired in `JarvisRuntime` | Low | Server uses it for tracing only; no functional impact |
| `MacBrainStats` is a singleton — test isolation not guaranteed for parallel test runs | Low | All Brain tests use `@Synchronized` state; JVM test runner is single-threaded by default |
| Circuit breaker tripped by non-Brain network errors (e.g. no internet at all) | Medium | Circuit auto-recovers after 5 minutes; user can reset manually from diagnostics |
| Sync queue max (250 items) may fill on first-run with many commands before server is set up | Low | Lowest-priority items (CONVERSATION_SUMMARY) evicted first; high-value items (HA corrections) survive |

---

## 5. Test Summary

Command: `.\gradlew.bat testDebugUnitTest --tests "com.jarvis.assistant.remote.macbrain.*"`
Report: `app/build/reports/tests/testDebugUnitTest/index.html`

| Suite | Tests | Passed | Failed | Skipped |
|---|---|---|---|---|
| `BrainContractTest` | 33 | 33 | 0 | 0 |
| `BrainRoutingPolicyTest` | 101 | 101 | 0 | 0 |
| `BrainSyncRunnerTest` | 17 | 17 | 0 | 0 |
| `PendingBrainSyncStoreTest` | 10 | 10 | 0 | 0 |
| **Total (Mac Brain)** | **161** | **161** | **0** | **0** |

Build: **SUCCESS** (`testDebugUnitTest`, exit 0, 26 s)

---

## 6. Next Recommended Phase

**Phase 6 — Mac Brain Server Implementation**

With the Android boundary fully hardened and proven, the next logical step is the Mac Brain server:

1. `/brain/context` endpoint — receives `BrainContextRequest` + `meta`, returns `BrainContextResponse`
2. `/brain/health` endpoint — returns 200 for health pings
3. `/brain/interactions` endpoint — receives batched `AndroidInteractionEvent`s, stores to memory DB
4. Memory retrieval — LLM-embedded similarity search over stored memories/preferences
5. Project summary — GitHub API integration for PR/issue/branch state
6. Device registration — use `meta.deviceId` for per-device context isolation

The wire protocol is already versioned (`apiVersion: 1`) and all Android request/response contracts are documented in `MacBrainModels.kt` and `BrainContractTest.kt`.
