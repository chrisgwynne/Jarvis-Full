# Conversation-First Architecture (shared, all platforms)

Status: design / north-star. Drives the Android → Mac → Windows rework.
Companion to the platform conversation-first audit issues.

## Principle

Jarvis is **conversation-first with embedded actions** (MCU-Jarvis model), not a
command router. The user's speech is treated as normal conversation first; the
system *detects* actionable commands embedded inside that conversation, runs them
(quietly or with a brief acknowledgement), and **keeps talking**. One utterance
can produce **both** a conversational reply **and** one or more actions. Actions
run in the background and never block the conversation unless confirmation,
permission, or a missing slot genuinely requires it.

### What "command-first" looks like today (to be removed)
- One utterance → one winning intent → the turn ends (`continue`/`return`).
- Conversational content is discarded when a command matches; commands are
  discarded when the turn is classified as "chat".
- Robotic "I can't do that" / "I don't know how to do that" when routing misses.
- Tools block speech; the assistant goes silent until the tool finishes.

## The 6-stage pipeline (shared contract)

```
transcript
  │
  ▼
(1) Conversation understanding ── interpret the FULL utterance as human speech;
  │                               emotional/contextual meaning; default = converse
  ▼
(2) Embedded command extraction ─ find actionable SPANS anywhere in the utterance;
  │                               return { conversationalText, actions[] } (0..n)
  ▼
(3) Action planner ────────────── per action: local-first; resolve slots; decide
  │                               silent / brief-ack / confirm; safety gate
  ▼
(4) Response composer ─────────── ONE blended reply = conversational response
  │                               (+ light action acknowledgement). Speak it now.
  ▼
(5) Background tool runner ─────── run actions async on a job; subtle UI status;
  │                               do NOT block speech; graceful failure recovery
  ▼
(6) Continuation manager ──────── when a job reports, fold the result back into
                                  the conversation and resume the original topic
```

### Turn contract (data model)
A turn is no longer "an intent". It is:

```
Turn {
  conversationalReply: String          // always present (may be empty for pure command)
  actions: [ActionSpan]                // 0..n extracted commands
}
ActionSpan { text, tool, slots, sourceRange, eligibility }
```

LLM responses must be able to carry **both** speech and tool calls in one result
(a `Composite { say, calls[] }` shape), and providers must stop dropping the text
block when a tool block is present.

## Decision rules (when to confirm / act silently / briefly acknowledge)

| Situation | Behaviour |
|---|---|
| Reversible, low-risk, unambiguous (lights, flashlight, volume, media, open app, camera, take photo, timer/alarm) | **Act silently** or a ≤1-clause brief-ack folded into the conversational reply ("…camera's up, by the way"). No modal. |
| Action needs a missing slot (e.g. "open the project" with no name) | **Ask one** targeted question; keep the rest of the conversation alive. |
| Irreversible / destructive / sensitive (send message/email, place call, delete, purchase, smart-lock) | **Confirm** once, conversationally ("Want me to send that?"); never auto-fire. |
| Routing/permission/tool failure | **Brief, in-voice** recovery that keeps the conversation open ("Couldn't get the camera — it might be in use. Anyway…"). Never a bare "I can't do that". |
| Pure conversation (no action span) | A substantive conversational reply. Never a refusal, never silence. |
| Ambiguous / not addressed to Jarvis | Don't invent a command; converse or stay quiet per attention gate (hard-ignore only TTS echo / notifications / phone-call audio). |

## Per-platform mapping (reuse existing classes)

### Android (priority 1)
- **Stage 1**: keep `prompt/PromptAssembler.kt` (add a TURN CONTRACT section); make
  `conversation/ConversationClassifier` + `ToolUsePolicy` multi-label (conversation +
  per-span eligibility) instead of all-or-nothing.
- **Stage 2**: the LLM is the span extractor once `LlmResult.Composite` exists; add a
  lightweight `EmbeddedCommandSplitter` so the `voice/routing/InstantCommandRouter`
  fast-path only claims **pure** commands.
- **Stage 3**: reuse as-is — `runtime/ToolDispatcher` (RiskClass × ConfidenceTier ×
  `AutonomyEngine`), `LocalFirstRouter`, `PlanRunner`, `ConfirmationGate`,
  `PendingMessageIntent`.
- **Stage 4**: add `LlmResult.Composite(say, calls)` + parse it in
  `AnthropicProvider`/`BaseOpenAiProvider`; new `ResponseComposer`; remove the terminal
  `continue` from tool branches in `JarvisRuntime.streamAndSpeak`.
- **Stage 5**: new `BackgroundToolRunner` wrapping `ToolDispatcher.dispatch` in
  `scope.launch`; drive `DeviceStateStore` + `overlay/OverlayCardManager`.
- **Stage 6**: generalise `resumeContinuation`/`ResumableResponse` beyond barge-in.

### Mac (priority 2 — and the cross-device brain)
- Flip `Conversation/ConversationRouter` default from `.command` to conversation;
  add a span-based `EmbeddedCommandExtractor` (reuse `NaturalCommandParser`/
  `CommandUnderstanding`); run `IntentRouter`/`CommandPhraseMatcher` only over spans.
- **Route `handleRemoteTranscript` through the SAME pipeline as `handleTranscript`** so
  Android/Windows get conversation-first from the brain.
- Extend `Conversation/JarvisAnswerComposer` with a real blend mode (remove the
  "ignore the command" prompt); enforce `Conversation/ActionPolicy` in `execute()`;
  run vision/tool pipelines async (`Vision/VisionActionPipeline`,
  `ToolExecutionGraph`); continuation via `ActiveContextRegistry`/`RollingDialogueMemory`.

### Windows (priority 3)
- Route finalised STT transcripts into `IConversationService.SendAsync` (today voice
  only animates the Pebble); make replies **speak** (`ILocalTtsService.SpeakAsync` has
  no caller); subscribe `RemoteOrchestrationCoordinator` events (`SpeakRequested` →
  speak, `ProactiveReceived` → toast).
- Evolve `LocalIntentRouter.Classify` → span `Extract`; add a tool-calling-capable
  provider request or a planner that calls `IWindowsToolRegistry` locally; relax the
  mandatory `WpfApprovalGate` modal for user-initiated, just-highlighted actions; run
  actions async; write tool results back into history.

## Shared contract

Define the `(conversationalReply, actions[])` turn, the planner decision, and the
"speak + act + continue" state machine **once** (this doc), with each platform's
router/composer as an adapter. The Mac remains the brain; Android/Windows send
transcripts and render the same conversation-first output.

## Rollout order
1. **Android** end-to-end (it has the strongest planner to reuse).
2. **Mac** — flip polarity + unify remote/local so cross-device matches Android.
3. **Windows** — wire voice→pipeline→speech + embedded extraction.

## Test matrix (apply on every platform)
1. Pure conversation, no command → one reply, zero actions, not dropped, not a refusal.
2. Pure command → action runs; silent/brief-ack; no modal.
3. Conversation + 1 command → blended reply **and** the action (the bad-day+camera case).
4. Conversation + multiple commands → one reply + N actions.
5. Command then emotion → action runs **and** emotion acknowledged.
6. Emotion then command → emotion acknowledged **and** action runs (not suppressed).
7. Ambiguous speech → no command invented; conversational/clarifying reply.
8. Background action while speaking → reply spoken before the (slow) tool completes; status shown.
9. Tool failure → graceful in-voice recovery; conversation continues.
10. "No command found" → still a useful conversational reply (never silence/refusal).
