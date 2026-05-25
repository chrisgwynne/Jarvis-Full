# Windows Jarvis — Feature Roadmap

---

## Product Direction

Windows Jarvis is the eyes, hands, and microphone of a distributed AI system. Its job
is not to be a standalone chatbot — it is to make the desktop legible to the Mac
brain at all times, and to execute the Mac's instructions with precision and safety.
Every feature decision on Windows must be evaluated against this frame: does it make
context richer, execution more reliable, or the connection between devices more robust?

The long-term bet is that a distributed Jarvis — Mac as the persistent reasoning
brain, Windows as the rich context surface — will be meaningfully more capable than
either machine alone. Windows has access to the user's full work context (what app
they're in, what they've been reading, what they've selected, what's in their
clipboard). The Mac brain has memory, reasoning depth, and persistent state across
devices. Connecting them well is the core engineering challenge.

---

## Current Capabilities (what ships today)

- **Pebble overlay** — translucent ambient indicator following the cursor. Breathing
  rate and halo intensity track the AmbientAttentionModel (Focused / Active / Ambient
  / Idle). Renders via WebView2 at up to 120 fps; <100 MB memory floor.
- **Foreground context** — process name, window title, user idle time polled at 250 ms.
  Less than 0.1% CPU overhead.
- **Rich perception** — clipboard text, selected text (UIAutomation), browser context
  (WebSocket extension bridge), IDE context (window-title heuristics for VS Code,
  JetBrains, etc.), OCR (Windows.Media.OCR on region capture or clipboard image).
- **Workflow categorization** — rule-based: Coding, Debugging, Browsing, Research,
  Writing, Communication, Media, Shopping, Editing, TerminalWork.
- **Mac bridge (sidecar mode)** — WebSocket to Mac Brain Daemon. Protocol v2 with
  sequence numbers, replay protection, pairing-code auth (DPAPI at rest), exponential
  backoff, degraded-mode detection. Context frames, transcript, lease/TTS, automation.
- **Distributed audio** — WinRT wake-word detection, STT, TTS. Echo suppression.
  Speaker authority lease (Mac grants/revokes Windows TTS permission).
- **Automation execution** — click, type, key, scroll, drag, resize, browser nav.
  Dry-run approval gate. JSONL audit log. Remote execution bridge (Mac sends intent,
  Windows acks).
- **Standalone conversation** — OpenAI / Ollama / MiniMax with context injection,
  redaction, quota guard.
- **Settings, tray, hotkeys, chord menu** — full admin surface.

---

## Phase 3 Foundations (what this sprint adds)

Phase 3 lays the infrastructure on which richer context and proactive features depend.
None of this is user-visible on its own, but every subsequent feature builds on it.

- **`AppUsageTracker`** — ring-buffer history of foreground-app sessions with dwell
  time. Finalises entries on foreground transitions. Privacy filter drops titles
  matching known-sensitive patterns (InPrivate, password managers, banking sites).
- **`PrivacySafeTimeline`** — immutable projection of app usage history into
  `TimelineEntry` records (workflow + process + dwell, never a title). Compact summary
  string for context payloads: `"Coding(15m)→Browsing(3m)→Coding(now)"`.
- **`WindowsContextSnapshot`** — enriched snapshot that wraps `SemanticSnapshot`
  with a timeline and a list of recent process names. SHA1 hash over all meaningful
  fields enables cheap dedup.
- **`WindowsContextEngine`** — subscribes to both `PerceptionService.Changed` and
  `AppUsageTracker.EntryAdded`. Rebuilds `WindowsContextSnapshot` and fires
  `ContextChanged` only when the hash differs. Master switch respects
  `ContextEngineSettings.Enabled`.
- **`ContextPayload` extensions** — `recentApps` (last N distinct process names) and
  `timelineSummary` (compact string) added to the bridge wire format. Mac brain can
  now answer "what was the user doing before this?" without asking.
- **`DashboardViewModel`** — `INotifyPropertyChanged` view model ready for a future
  dashboard panel. Reflects current workflow, bridge status, recent apps, timeline
  summary, and published-frame count.
- **Settings additions** — `ContextEngineSettings` (enabled, history depth, summary
  depth, privacy switch) and `AwarenessSettings.AppUsageHistoryDepth`.

---

## Near-Term (next 1–2 sprints): Richer Context Signals

**Goal:** make the context the Mac brain receives noticeably more useful. Each item
below is independently shippable; pick the highest-leverage items per sprint.

### 1. Persist `AppUsageTracker` history to disk
Today the ring buffer is in-memory and lost on restart. A brief JSONL file in
`%AppData%\Jarvis\app-usage.jsonl` (capped at 7 days) lets the engine reconstruct
the last few hours of context after a reboot. The Mac brain then has continuity across
Windows restarts.

### 2. Wire `WindowsContextEngine` into `SidecarContextPublisher`
Currently `SidecarContextPublisher` uses only `SemanticSnapshot`. Switch it to
`WindowsContextEngine.Current` so `recentApps` and `timelineSummary` flow to the Mac
automatically on every context push. Requires updating the `ContextPayload` mapping in
`SidecarContextPublisher.PublishCurrentAsync`.

### 3. Typing-rate signal for `AmbientAttentionModel`
The model already has a `TypingRate` input but it's hardwired to `0` in `App.xaml.cs`.
Add a lightweight `IInputObserver` that counts keystrokes via the existing low-level
hook infrastructure (the chord detector already installs `WH_KEYBOARD_LL`). Feed a
2-second rolling average into the model. Enables `Focused` mode to trigger on real
typing, not just stable-focus heuristics.

### 4. Encrypt `LlmSettings.ApiKey` at rest
API keys are stored as plaintext JSON. Apply the same `"dpapi:"` pattern already used
for `Gateway.SessionToken` in `JsonSettingsStore`. Migration: on first load, if the
key doesn't start with `"dpapi:"`, treat it as plaintext and re-encrypt on next save.

### 5. Surface `DashboardViewModel` in a real UI panel
Wire `DashboardViewModel` into a new lightweight settings-adjacent window. Show: current
workflow badge, timeline summary strip, bridge status, recent apps list, published-frame
count. This gives users and developers a live view of what context is being sent to Mac.

### 6. Browser context — active tab URL without the extension
The current browser bridge requires a Chrome/Edge extension. For users without it,
add a best-effort title-parsing path that extracts the page title from
`ForegroundWindowTitle` (Edge/Chrome include it). Lower fidelity but zero-install.

---

## Medium-Term (3–6 months): Proactive Intelligence

**Goal:** Windows surfaces insights proactively rather than waiting for a user query.

### 1. Proactive workflow nudges
When `AppUsageTracker` detects a pattern — e.g. more than 3 context switches in 5
minutes, or >30 minutes of continuous Browsing before a scheduled coding task —
Windows sends a `presence` frame to the Mac brain with a structured signal. The Mac
decides whether to surface a nudge via `proactive.notify`.

Design constraint: Windows never decides what to say. It only observes and reports.
The Mac brain owns tone, timing, and personalisation.

### 2. Focus session detection and handoff
Extend `AppUsageTracker` with a `FocusSession` concept: contiguous Coding or Writing
dwell > 20 minutes with no app switches. Emit a `focus.started` / `focus.ended` signal
to the Mac. The Mac can then suppress interruptions (proactive notifications, TTS)
during focus and provide a summary when focus ends.

### 3. Work-context handoff between devices
When the user switches from Windows to Mac mid-task, Windows sends a structured
"last activity" snapshot: current workflow, recent apps, selected text, open file, IDE
branch. The Mac brain receives this as a `context` frame and can proactively offer
continuity ("You were working on `feature/auth` in VS Code — want to pick that up?").

### 4. Clipboard intelligence
Currently clipboard is captured verbatim (capped at 256 chars). Add:
- Content type detection: code snippet, URL, email address, numeric data, natural language.
- Context linking: if the clipboard text matches a browser URL the user visited
  recently, annotate the `ContextPayload` with that match.
- Cross-device clipboard: when the Mac brain receives a clipboard entry, it can push
  it back to Windows via an `execute.intent` (if the user has opted in).

### 5. IDE deep context
The current `IIdeContextProvider` infers context from window titles alone. Build an
optional Language Server Protocol client that connects to VS Code / JetBrains via
their existing debug-adapter / LSP endpoints to read: current file cursor position,
diagnostic errors, recently modified files, open terminals. Gated behind an explicit
user opt-in in settings.

---

## Long-Term: Windows as Intelligent Context Provider for Distributed Jarvis Brain

The three-year vision: Windows becomes a first-class sensor node in a multi-device
Jarvis network. It contributes a continuous, rich, privacy-respecting stream of
desktop context that the Mac brain (and eventually a cloud memory layer) can reason
over across any time horizon.

**Key capabilities to build toward:**

- **Structured context graph** — instead of flat string fields, Windows emits typed
  events (AppOpened, DocumentFocused, CodeFileChanged, WebPageViewed) that the Mac
  brain accumulates into a structured activity graph. Enables semantic retrieval
  ("what was the user reading when they asked about X?").

- **Passive learning** — `WorkflowCategorizer` learns per-user corrections. If the
  user labels an app as "Research" when the rule says "Browsing", that correction is
  persisted locally and applied going forward.

- **Hardware signals** — ambient light sensor (dim/bright room), microphone energy
  (background noise level), display count/layout changes. These enrich the attention
  model with physical environment context.

- **Multi-window awareness** — today only the foreground window is tracked. A
  background thread could poll `EnumWindows` to detect split-screen / virtual desktop
  arrangements and surface multi-app context ("user is watching a video tutorial while
  coding").

- **Privacy-controlled memory** — a local semantic store (vector DB, ~1 GB) that
  indexes the timeline without ever sending raw data to the Mac. The Mac can query it
  by embedding ("what were they working on this morning?") and Windows returns a
  summary. Data stays local; embeddings are computed on-device.

---

## Privacy Principles (non-negotiable constraints)

1. **No raw window titles for sensitive content.** Any title matching the sensitive
   pattern list (InPrivate, passwords, banking, password managers) is dropped at the
   `AppUsageTracker` layer and never travels further in the pipeline.

2. **No raw transcripts stored.** STT output is forwarded to the Mac in real time and
   never written to disk on Windows. The distributed conversation coordinator persists
   only session/device IDs, never utterance text.

3. **DPAPI for credentials.** `Gateway.SessionToken` is encrypted at rest. Future
   `LlmSettings.ApiKey` must receive the same treatment. No credentials in plaintext
   JSON files.

4. **User opt-out respected immediately.** `SidecarSettings.PrivacyMode = true`
   suppresses all context pushes and mic capture without requiring a restart. The
   toggle is accessible from the tray, the chord menu, and hotkeys.

5. **Context stays on the wire, not in logs.** `ContextPayload` fields (selected text,
   clipboard, OCR) must not appear in diagnostic ring-buffer entries or file logs.
   Only hashes and length hints are permitted.

6. **Sensitive contexts excluded from timeline.** Private browsing sessions, password-
   manager windows, and banking sites appear in `AppUsageTracker` history only as
   `TitleRedacted = true` entries with process name and workflow category. No URL, no
   title snippet ever reaches the Mac.

7. **Local fallback available.** When the Mac bridge is down, Windows degrades to its
   local LLM provider rather than buffering context indefinitely. Users in air-gapped
   environments can run fully locally with no data leaving the machine.

---

## Implementation Guidelines

- **Sealed classes + record DTOs.** Domain types are `sealed record`; services are
  `sealed class` with constructor injection. Favour immutability in types that cross
  thread or process boundaries.
- **`lock (_gate)` for ring buffers.** All mutable collections shared across threads
  must be behind a named `_gate` field. Avoid `ConcurrentQueue` for ring buffers —
  the capped-overwrite semantic requires custom locking.
- **`IDiagnostics` for observability.** Every service that does meaningful work should
  call `diagnostics.RecordMetric(...)` and `diagnostics.Record(...)` on state
  transitions and errors. Do not use `Console.WriteLine` or `Debug.WriteLine`.
- **No new NuGet packages without review.** The dependency surface is intentionally
  minimal. Before adding a package, check if the capability already exists in BCL or
  existing dependencies.
- **Test every new pure type.** `PrivacySafeTimeline`, `WindowsContextSnapshot`,
  `DashboardViewModel`, and similar pure/stateless types must have unit tests.
  Win32-dependent services should be tested via interface stubs.
- **Performance targets are hard constraints.** `<1% CPU for awareness polling`,
  `<120 MB for the overlay process`. If a feature would breach these, redesign before
  shipping, not after.
- **All context-pipeline changes must be hash-aware.** Adding a new field to
  `ContextPayload` must also update the hash inputs in the relevant snapshot builder
  so the dedup logic continues to work correctly.
