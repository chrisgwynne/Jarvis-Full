# Windows Jarvis — Full Codebase Audit

_Audit date: 2026-05-25. Based on 222 C# source files across 7 projects._

---

## 1. Architecture Overview

Windows Jarvis is a WPF + WebView2 ambient desktop assistant. It follows a strict
layered architecture where domain types live in `Jarvis.Core` (no Win32 or WPF
dependencies), platform concerns are isolated in leaf projects, and the entire app
is wired together via constructor-injected services in `App.xaml.cs`.

The system has two operating modes:

1. **Standalone** — Windows runs its own LLM provider (OpenAI/Ollama/MiniMax) and
   handles the full conversation loop locally. No Mac involved.
2. **Sidecar** — Windows acts as a context provider and execution surface for a Mac
   Brain Daemon. The Mac is the reasoning core; Windows provides desktop telemetry,
   handles automation intents, and forwards audio via a WebSocket bridge.

The Pebble is a translucent ambient indicator (cursor-following SVG overlay) that
reflects the assistant state — breathing rate, halo intensity, listening ripple — via
the WebView2 renderer driven by a JavaScript bridge.

---

## 2. Module Inventory

| Project | TFM | Files | Purpose |
|---------|-----|-------|---------|
| `Jarvis.Core` | net8.0 | ~50 | Domain types, interfaces, settings, snapshot types. No Win32/WPF. |
| `Jarvis.Perception` | net8.0-windows | ~40 | Desktop context building: clipboard, browser bridge, IDE detection, OCR, selected text, semantic snapshot, conversation, sidecar/bridge. |
| `Jarvis.DesktopAwareness` | net8.0-windows | ~2 | Win32 foreground-app and idle-state poller at 250 ms. |
| `Jarvis.Diagnostics` | net8.0 | ~2 | In-process ring buffer + concurrent metric map + performance sampler (CPU/memory). |
| `Jarvis.Settings` | net8.0 | ~1 | JSON-backed settings store with DPAPI encryption for sensitive fields. |
| `Jarvis.Automation` | net8.0-windows | ~15 | Automation executor, approval policy, dry-run planner, audit log, rate limiter, Win32/input/browser/file surfaces. |
| `Jarvis.App` | net8.0-windows | ~70 | WPF host, overlay window, pebble follower, tray, hotkeys, chat panel, settings UI, sidecar audio (WinRT), mouse-chord menu, automation UI. |
| `Jarvis.Core.Tests` | net8.0 | 9 | Tests for Core models and Settings. |
| `Jarvis.Perception.Tests` | net8.0-windows | ~55 | Tests for perception, conversation, sidecar, bridge protocol. |
| `Jarvis.Automation.Tests` | net8.0-windows | 7 | Tests for automation executor, policies, audit log. |

---

## 3. Capability Map (what works today)

**Desktop context sensing**
- Foreground process name + window title (Win32 poll, 250 ms)
- User idle time (Win32 GetLastInputInfo)
- System clipboard monitoring (WPF clipboard hook)
- Selected text (UIAutomation TextPattern)
- Browser context: URL + title + selected text (WebSocket bridge, Chrome/Edge extension)
- IDE context: editor, active file, repo root, branch (window-title heuristics)
- OCR: region capture (GDI screen grab + Windows.Media.OCR) or clipboard image
- Workflow categorization (rule-based: Coding, Debugging, Browsing, Research, Writing, etc.)
- Semantic snapshot with SHA1 hash for dedup

**Mac bridge (sidecar mode)**
- WebSocket to Mac Brain Daemon via gateway protocol v2
- Pairing-code authentication flow (no manual token copying)
- Hello/heartbeat/state/context/transcript/lease/execute/chat frames
- Sequence numbers + replay protection
- Exponential backoff reconnect; degraded-mode detection
- Context frames pushed on every meaningful desktop change

**Audio**
- WinRT wake word detection (keyword spotting)
- WinRT STT (continuous recognition)
- WinRT TTS with speaker authority lease (Mac grants, Windows executes)
- Echo suppression coordination (suppresses during Mac speech)
- Partial transcript forwarding to Mac

**Automation**
- Click, type, key, scroll, drag, resize, close, browser navigation
- Dry-run planner + approval gate (WPF dialog for elevated actions)
- Audit log (JSONL, persisted to AppData)
- Token-bucket rate limiter
- Remote execution bridge (Mac sends `execute.intent`, Windows acks)

**Conversation (standalone mode)**
- OpenAI / Ollama / MiniMax LLM provider manager
- Context budgeter with redaction (email, phone, file paths, length caps)
- Local intent router (guidance, automation, OCR shortcuts)
- History ring buffer (64 messages)
- Quota guard (daily request + char limits)

**UI**
- WPF overlay (WebView2) — pebble breathing/halo animations at up to 120 fps
- Cursor follower with configurable easing
- Chat panel window (Markdown streaming)
- Context inspector window (live snapshot view)
- Settings window (full settings tree)
- LLM settings window
- Redaction preview
- Guidance prompt + highlight renderer
- Audit log window
- Pebble interaction menu (left+right chord)
- System tray icon + menu

**Attention model**
- `AmbientAttentionModel`: maps cursor velocity / typing rate / app switches / idle → Focused/Active/Ambient/Idle mode + 0–1 intensity
- Drives pebble renderer at 4 Hz

---

## 4. Context Pipeline

```
Win32 (GetForegroundWindow, GetLastInputInfo)
    ↓ 250 ms poll
DesktopAwarenessService → DesktopSnapshot
    ↓ SnapshotChanged event
PerceptionService (aggregates all inputs)
    ├── ISelectedTextProvider (UIAutomation)
    ├── IClipboardMonitor (WPF hook)
    ├── IBrowserContext (WebSocket bridge)
    ├── IIdeContextProvider (window-title heuristics)
    └── IOcrService (Windows.Media.OCR, on demand)
    ↓ ISemanticSnapshotBuilder.Build(SemanticSnapshotInputs)
SemanticSnapshot (SHA1 hash, immutable record)
    ↓ PerceptionService.Changed event
SidecarContextPublisher
    ↓ IConversationContextBuilder.Build()
ConversationContext
    ↓ IContextBudgeter.Budget() → redaction + truncation
Compact ConversationContext
    ↓ map to ContextPayload
ContextPayload (JSON DTO)
    ↓ SidecarFrame { type="context", snapshotHash, context }
MacBridgeCoordinator → WebSocket → Mac Brain Daemon
```

Key dedup: `SidecarContextPublisher` caches the last `snapshotHash` and skips sending
if it hasn't changed. `SemanticSnapshotBuilder.ComputeHash()` SHA1s all meaningful
fields so byte-for-byte identity is not required.

---

## 5. Mac Bridge Protocol

**Protocol version:** `SidecarProtocol.Version = 2` (in `Jarvis.Core/Sidecar/SidecarFrame.cs`)

**Frame envelope fields:** `type`, `id`, `protocolVersion`, `seq` (monotonic per direction),
`replyTo` (correlates responses to requests).

**Frame types (from `SidecarFrameTypes`):**

| Direction | Type | Purpose |
|-----------|------|---------|
| W→M | `hello` | Initial handshake + capability.update |
| W,M→ | `heartbeat` | Keepalive; Windows measures RTT |
| W→M | `state` | Pebble + mic + speaker state |
| W→M | `context` | Compact desktop snapshot (only on hash change) |
| W→M | `transcript.partial` / `.final` | STT output from Windows mic |
| W→M | `lease.request` | Request to speak |
| M→W | `lease.grant` | Mac authorises Windows TTS |
| M→W | `lease.revoke` | Mac reclaims speaker authority |
| W,M→ | `speaker.active` / `.silent` | Playback started/stopped |
| M→W | `execute.intent` | Automation request from Mac |
| W→M | `execute.ack` | Automation outcome |
| M→W | `chat.reply.partial` / `.final` | Streamed LLM response |
| M→W | `tts.text` | Mac asks Windows to speak a line |
| M→W | `orchestrate.silent` / `.speak` | Distributed-brain coordination |
| M→W | `proactive.notify` | Mac-initiated notification |
| W→M | `presence` | Attention/idle/workflow snapshot |
| W→M | `replay.begin` / `.end` | Queued frames from a disconnect window |

**Wire format:** JSON objects wrapped in a gateway envelope (`GatewayMessage`) for
the daemon protocol. Sequence numbers are per-direction monotonic integers; receivers
drop frames where `seq <= lastInboundSeq` for replay protection.

**Gateway auth:** `Authorization: Bearer <session-token>` header on WebSocket upgrade.
Session token obtained via pairing-code exchange at `/v1/windows/pair`.

---

## 6. Test Coverage Assessment

| Module | Coverage | Notes |
|--------|----------|-------|
| `Jarvis.Core` | Good | Attention model, pebble state machine, diagnostics ring buffer, settings store, wake alias, mouse chord. All pure logic. |
| `Jarvis.Perception` | Very good | Semantic snapshot builder, workflow categorizer, context budgeter, context builder, conversation service, redaction, OCR post-processor, bridge protocol v2, sidecar serialization, distributed conversation/fallback, TTS lease coordinator, echo suppression, remote execution bridge, quota guard, guidance service, browser bridge. |
| `Jarvis.Automation` | Good | Executor, approval policy, dry-run planner, audit log, rate limiter. |
| `Jarvis.DesktopAwareness` | None | `DesktopAwarenessService` has no tests. Win32 interop is hard to stub but the service logic is testable if `IDesktopAwarenessService` is faked. |
| `Jarvis.App` | None | WPF wiring, tray, overlay lifecycle. UI code; integration-only. |
| `Jarvis.Settings` | Partial | `JsonSettingsStore` tested via Jarvis.Core.Tests; DPAPI path not covered. |
| `Jarvis.Diagnostics` | Good | Ring buffer, metric recording, tail windows. |

**Missing coverage:**
- `AppUsageTracker` — added in Phase 3; tests added in this sprint.
- `PrivacySafeTimeline`, `WindowsContextSnapshot`, `WindowsContextEngine`, `DashboardViewModel` — added in Phase 3; tests added in this sprint.
- `DesktopAwarenessService` idle/transition logic — no unit tests.
- DPAPI encryption/decryption round-trip in `JsonSettingsStore`.
- WinRT audio stack (mic capture, TTS, wake word) — Windows-only runtime; not mocked.

---

## 7. Privacy & Security Posture

**Redaction pipeline**
`RedactionService` strips email addresses, phone numbers, and optionally file paths
from selected text, clipboard, and OCR results before they reach the LLM or the Mac
bridge. Configurable via `RedactionSettings`. Length caps: selected text 4 KB,
clipboard 256 chars, OCR 512 chars.

**Title sensitivity**
`AppUsageTracker` (Phase 3) checks window titles against a deny-list:
`incognito`, `private browsing`, ` - inprivate`, `password`, `bank`, `paypal`,
`1password`, `bitwarden`, `keepass`. Matched titles are dropped; only the process name
and workflow category are retained. The flag `TitleRedacted = true` is carried in
the entry so callers know data was withheld.

**Privacy mode**
`SidecarSettings.PrivacyMode = true` suppresses mic capture and all context pushes.
The pebble shows muted. Toggle available in tray menu and pebble interaction chord.

**Session token / credentials**
`Gateway.SessionToken` is encrypted at rest via DPAPI (CurrentUser scope) in
`JsonSettingsStore`. A `"dpapi:"` prefix distinguishes encrypted values from legacy
plaintext tokens (migrated on first save). The token is never logged in full.

**Raw data exposure risks**
- OCR text is previewed in diagnostics (first 80 chars) — controlled by `Record(Debug, ...)`.
- Redacted-field hashes are logged when `ShowRedactedPreviewInDiagnostics = true`.
- `ConversationContext` fields (selected text, clipboard, URL) flow into the LLM
  system prompt — the budgeter applies caps but cannot prevent all leakage to cloud.
- `DesktopSnapshot.ForegroundWindowTitle` is stored verbatim in the ring buffer before
  being evaluated for sensitivity — a short window where the raw title exists in memory.

**DPAPI usage** — `Jarvis.Settings` references `System.Security.Cryptography.ProtectedData`.
Only `Gateway.SessionToken` is protected; API keys (`LlmSettings.ApiKey`) are
stored as plaintext JSON. This is a known gap.

---

## 8. Performance Characteristics

**Awareness polling**
`DesktopAwarenessService` polls at 250 ms (configurable via `PollIntervalMs`). Each
poll calls `GetForegroundWindow`, `ReadWindowTitle` (via `GetWindowTextW`),
`GetWindowThreadProcessId`, `Process.GetProcessById`, and `GetLastInputInfo`.
Measured cost: `awareness.lastPollMs` recorded to `IDiagnostics` metrics each cycle.
Target: <0.1% CPU.

**Overlay / pebble renderer**
`OverlaySettings.TargetFps = 120` (configurable). The overlay is a transparent WPF
window hosting a WebView2 instance rendering an SVG pebble. CPU budget is dominated
by WebView2's compositor; GPU acceleration is on by default. The overlay window itself
is click-through (`WS_EX_TRANSPARENT`). Memory floor: ~80–100 MB including WebView2
process. Target: <120 MB.

**Snapshot building**
`SemanticSnapshotBuilder.Build()` is synchronous and pure. SHA1 computation over
~10 string fields takes microseconds. UIAutomation `TryReadSelection()` is the
dominant latency item (can block 5–50 ms on some apps).

**Bridge throughput**
`MacBridgeCoordinator` queues outbound frames in a `BlockingCollection` (cap 256).
Context frames are deduplicated by hash so the wire is quiet when the user is idle.
Heartbeat interval: 10 s.

**Diagnostics**
`DiagnosticsService` uses a `Queue<DiagnosticEntry>` behind a lock (ring buffer,
default 1024). `PerformanceSampler` records CPU/memory via `Process.GetCurrentProcess()`
at a configurable interval. All in-process; no I/O on the hot path.

---

## 9. Gaps & Risks

**High priority**
1. `AppUsageTracker` — before Phase 3, no history of app transitions was maintained.
   The attention model in `App.xaml.cs` tracked `_recentAppSwitches` as a plain int
   without history. Phase 3 adds a proper ring-buffer implementation.
2. No context timeline in `ContextPayload` — the Mac brain sees only the current
   foreground app, not where the user was for the last N minutes. Phase 3 adds
   `recentApps` and `timelineSummary` fields.
3. `LlmSettings.ApiKey` is stored in plaintext JSON. Should use DPAPI like `SessionToken`.
4. `DesktopAwarenessService` — no unit tests. The service is critical but only exercised
   via integration. A test-seam abstraction over Win32 would enable isolation.

**Medium priority**
5. `WorkflowCategorizer` private `Classify` method is a stub (always returns Unknown).
   Selected-text classification inside the categorizer is intentionally disabled but
   undocumented — it looks like incomplete code.
6. WinRT audio stack has no unit tests or mocks. Failures are silent at startup if the
   audio stack is unavailable; the error is logged but startup continues.
7. `ContextBudgeter` doesn't budget `recentApps` / `timelineSummary` (new Phase 3
   fields) — they bypass the char-budget system entirely. If the app history is long,
   the payload could grow unexpectedly.
8. `ConversationService` history cap is 64 messages, hard-coded. No settings knob.

**Low priority**
9. `BrainGatewayConfig.DeriveWebSocketUrl()` derives `/v2/ws` but the existing
   `SendGatewayHelloAsync` comment references `/v1/windows/ws`. If the daemon still
   uses v1 paths there could be a routing mismatch.
10. Mouse chord detector installs a low-level `WH_MOUSE_LL` hook — any unhandled
    exception in the hook callback could hang the system message loop.
11. `DistributedConversationCoordinator` persists session/device IDs to
    `%AppData%\Jarvis\distributed.json` without any integrity check. Corrupt files
    fall back to a fresh GUID; no data is lost but a session attribution gap arises.

---

## 10. Foundation for Phase 3

**What already exists**

| Need | Existing building block |
|------|------------------------|
| Foreground-process change events | `IDesktopAwarenessService.SnapshotChanged` |
| Workflow categorization | `IWorkflowCategorizer` + `WorkflowCategorizer` |
| Semantic snapshot with hash | `SemanticSnapshot` + `SemanticSnapshotBuilder` |
| Desktop context events | `PerceptionService.Changed` |
| Context payload wire format | `ContextPayload` in `SidecarFrame.cs` |
| Settings infrastructure | `JarvisSettings` record + `IJarvisSettingsStore` |
| Diagnostics/metrics | `IDiagnostics.RecordMetric(string, double)` |
| Test harness (xUnit + FluentAssertions) | `Jarvis.Perception.Tests` |

**What must be added (Phase 3)**

- `AppUsageEntry` record + `IAppUsageTracker` interface (Jarvis.Core/Awareness)
- `AppUsageTracker` implementation with ring buffer + sensitivity filter (Jarvis.DesktopAwareness)
- `PrivacySafeTimeline` + `TimelineEntry` (Jarvis.Core/Context)
- `WindowsContextSnapshot` + `IWindowsContextSnapshotBuilder` (Jarvis.Core/Context)
- `IWindowsContextEngine` interface (Jarvis.Core/Context)
- `WindowsContextSnapshotBuilder` + `WindowsContextEngine` (Jarvis.Perception/Context)
- `ContextEngineSettings` + `AwarenessSettings.AppUsageHistoryDepth` additions to settings
- `ContextPayload.RecentApps` + `TimelineSummary` bridge fields
- `DashboardViewModel` (Jarvis.App/Dashboard)
- Test coverage for all the above
