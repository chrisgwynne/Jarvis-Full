# Windows Phase 4 — Discovery & Architecture

## Existing Execution Paths

### Low-level automation path (pre-Phase 4)
```
Mac → execute.intent frame → IMacBridgeCoordinator.FrameReceived
  → RemoteExecutionBridge.OnFrame
  → ParseIntent (whitelist of ~20 kinds)
  → IAutomationExecutor.ExecuteAsync
  → [DefaultApprovalPolicy + TokenBucketRateLimiter + WpfApprovalGate + JsonlAuditLog]
  → Win32 surface (Win32WindowSurface / Win32InputSurface / FileSurface)
  → execute.ack back to Mac
```

### Bridge frame types (pre-Phase 4)
- `hello`, `heartbeat`, `state`, `context` — handshake/sync
- `transcript.partial`, `transcript.final` — STT from Windows mic
- `lease.request`, `lease.grant`, `lease.revoke`, `speaker.active`, `speaker.silent` — TTS authority
- `execute.intent` (M→W) — AutomationIntent dispatch
- `execute.ack` (W→M) — AutomationOutcome result
- `chat.reply.partial`, `chat.reply.final` — response streaming
- `tts.text` — Windows TTS
- `orchestrate.silent`, `orchestrate.speak`, `proactive.notify`, `presence`, `replay.begin/end` — P7 distributed

### Automation intent types (pre-Phase 4)
| Kind | Class |
|---|---|
| window.focus | FocusWindowIntent |
| window.switchApp | SwitchAppIntent |
| window.move / resize / state | MoveWindowIntent / ResizeWindowIntent / SetWindowStateIntent |
| keyboard.shortcut / type / paste / key | SendShortcutIntent / TypeTextIntent / PasteTextIntent / PressKeyIntent |
| mouse.move / click / scroll | MoveCursorIntent / ClickIntent / ScrollIntent |
| ui.highlight | HighlightTargetIntent |
| browser.navigate / reload / back / forward / focusInput / extractSelection / scroll / click | BrowserNavigateIntent etc. |
| app.open | OpenAppIntent |
| file.open / reveal / createDraft | OpenFileIntent / RevealFileIntent / CreateDraftFileIntent |

### Existing abstractions
- `IWindowsTool` / `IWindowsToolRegistry` — **new in Phase 4**
- `IDesktopMemoryQueryService` — **new in Phase 4**
- `ISessionMemoryStore` — stores WorkSession JSONL in %APPDATA%\Jarvis
- `IAppUsageTracker` — ring buffer of AppUsageEntry (process name, workflow, dwell time)
- `IFocusSessionTracker` — current FocusMetrics (duration, score, state, app switches)
- `IPresenceModeManager` — Work / Focus / Casual / Gaming / Presentation / Silent / Developer
- `DashboardViewModel` — context snapshot view model, PropertyChanged-based

## Bridge Message Types Added (Phase 4)

| Frame type | Direction | Purpose |
|---|---|---|
| `windows.tool.request` | M→W | Invoke a named tool with parameters |
| `windows.tool.result` | W→M | Result of a tool invocation |
| `windows.memory.query` | M→W | Query local desktop memory |
| `windows.memory.answer` | W→M | Answer to a memory query |

## Tool Inventory

| Name | Aliases | Safety | Privacy |
|---|---|---|---|
| open_app | open, launch, start_app | Confirm | None |
| focus_app | focus, bring_to_front, switch_to | Safe | None |
| close_app | close, quit_app | Confirm/Approve | None |
| screenshot_window | screenshot, capture_screen, capture_window | Confirm | Screenshot |
| clipboard_summary | clipboard, what_is_in_clipboard | Safe | Clipboard |
| volume_control | volume, mute, unmute, set_volume | Safe | None |
| inspect_processes | processes, what_is_running, running_apps | Safe | AppList |
| open_project | project, open_repo, open_folder | Confirm | FilePath |

## Safe Extension Points

1. **New tools**: implement `IWindowsTool`, register as `IWindowsTool` singleton in DI → automatically picked up by `WindowsToolRegistry`.
2. **New bridge frame types**: add constants to `SidecarFrameTypes`, add fields to `SidecarFrame`, create a bridge class following `WindowsToolBridge` / `WindowsMemoryBridge` pattern.
3. **New memory query handlers**: add keyword matchers + handlers in `DesktopMemoryQueryService.AnswerAsync`.
4. **Dashboard quick actions**: add XAML button, wire in `DashboardWindow.xaml.cs`, handle in `App.OnDashboardQuickAction`.

## Gaps / Future Work

- `volume_control set` action uses best-effort WM_APPCOMMAND stepping — precise control requires CoreAudioAPI
- `open_project` alias file (`projects.json`) is populated manually by the user
- `screenshot_window` captures the foreground window at execution time; a pre-configured target hwnd would be more deterministic
- DesktopMemoryQueryService returns cached focus metrics; real-time streaming answers would require live event subscription
