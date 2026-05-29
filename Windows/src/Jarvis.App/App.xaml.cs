using System.Diagnostics;
using System.Windows;
using Jarvis.App.Dashboard;
using Jarvis.Core.Logging;
using Jarvis.Settings;
using Jarvis.App.Overlay;
using Jarvis.App.Tray;
using Jarvis.Core.Awareness;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Focus;
using Jarvis.Core.Hotkeys;
using Jarvis.Core.Memory;
using Jarvis.Core.Presence;
using Jarvis.Core.Proactive;
using Jarvis.Core.Settings;
using Jarvis.Core.State;
using Jarvis.DesktopAwareness;
using Jarvis.Diagnostics;
using Jarvis.Perception.Dashboard;
using Jarvis.Perception.Presence;
using Jarvis.Perception.Proactive;
using Jarvis.App.Automation;
using Jarvis.App.Capture;
using Jarvis.App.Hotkeys;
using Jarvis.Automation;
using Jarvis.Automation.Surfaces;
using Jarvis.Core.Automation;
using Jarvis.Core.Conversation;
using Jarvis.Core.Guidance;
using Jarvis.Core.Perception;
using Jarvis.Core.Snapshot;
using Jarvis.Perception;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Conversation;
using Jarvis.Perception.Guidance;
using Jarvis.Perception.Sidecar;
using Jarvis.Core.Tools;
using Jarvis.Perception.Browser;
using Jarvis.Perception.Capture;
using Jarvis.Perception.Classification;
using Jarvis.Perception.Clipboard;
using Jarvis.Perception.Ide;
using Jarvis.Perception.Memory;
using Jarvis.Perception.Ocr;
using Jarvis.Perception.Selection;
using Jarvis.Perception.Snapshot;
using Jarvis.Perception.Tools;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using MessageBox = System.Windows.MessageBox;
using MessageBoxButton = System.Windows.MessageBoxButton;
using MessageBoxImage = System.Windows.MessageBoxImage;
using MessageBoxResult = System.Windows.MessageBoxResult;

namespace Jarvis.App;

public partial class App : System.Windows.Application
{
    private IServiceProvider? _services;
    private OverlayWindow? _overlay;
    private PerformanceSampler? _sampler;
    private IDesktopAwarenessService? _awareness;
    private DiagnosticsFileSink? _fileSink;
    private TrayController? _tray;
    private SettingsWindow? _settingsWindow;
    private ContextInspectorWindow? _inspectorWindow;
    private IClipboardMonitor? _clipboardMonitor;
    private WebSocketBrowserContextProvider? _browserBridge;
    private GlobalHotkeyService? _hotkeyService;
    private IMacBridgeCoordinator? _macBridge;
    private ISidecarContextPublisher? _contextPublisher;
    private IRemoteExecutionBridge? _remoteExecutor;
    private WindowsToolBridge? _toolBridge;
    private WindowsMemoryBridge? _memoryBridge;
    private IMicrophoneCapture? _mic;
    private IPartialTranscriptCoordinator? _partialCoord;
    private IPlaybackInterruptionCoordinator? _interruptCoord;
    private Jarvis.App.Chord.MouseChordService? _chord;
    private Jarvis.App.Chord.PebbleInteractionMenuWindow? _menu;
    private System.Windows.Threading.DispatcherTimer? _attentionTimer;
    private int _recentAppSwitches;
    private DateTimeOffset _lastAppChangeAt = DateTimeOffset.MinValue;
    private DateTimeOffset _lastInputAt = DateTimeOffset.UtcNow;
    private string? _lastForegroundApp;
    private bool _shuttingDown;
    private Mutex? _singleInstanceMutex;
    private CancellationTokenSource? _micRebindCts;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // WIN-8: single-instance guard — if another instance is already running, exit immediately.
        _singleInstanceMutex = new Mutex(initiallyOwned: true, name: "Jarvis.App.SingleInstance", out var createdNew);
        if (!createdNew)
        {
            _singleInstanceMutex.Dispose();
            _singleInstanceMutex = null;
            Shutdown();
            return;
        }

        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandled;
        DispatcherUnhandledException += OnDispatcherUnhandled;
        TaskScheduler.UnobservedTaskException += OnTaskUnhandled;

        var services = new ServiceCollection();
        ConfigureServices(services);
        _services = services.BuildServiceProvider();

        // Wire the chat-side region-capture hook now that DI is built.
        if (_services.GetService<ILocalIntentRouter>() is Jarvis.Perception.Conversation.LocalIntentRouter routerImpl)
        {
            routerImpl.CaptureRegionHook = CaptureRegionForTextAsync;
            routerImpl.CloseInteractionMenuHook = CloseInteractionMenu;
        }

        var settingsStore = _services.GetRequiredService<IJarvisSettingsStore>();
        try
        {
            await settingsStore.LoadAsync();
        }
        catch (Exception ex)
        {
            // last-resort: corrupt-file path already quarantines bad JSON, but I/O errors are still
            // possible (locked file, permissions). Continue with in-memory defaults rather than crash.
            MessageBox.Show($"Couldn't load settings — using defaults.\n\n{ex.Message}", "Jarvis",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        var diagnostics = _services.GetRequiredService<IDiagnostics>();
        _fileSink = diagnostics as DiagnosticsFileSink;
        var sidecarSettings = settingsStore.Current.Sidecar;
        if (sidecarSettings.HasAliasCollision)
        {
            diagnostics.Record(DiagnosticLevel.Warn, "wake", "alias collision",
                new Dictionary<string, object?>
                {
                    ["alias"] = sidecarSettings.LocalWakeAlias,
                    ["identity"] = sidecarSettings.AssistantIdentityName,
                    ["hint"] = "set Sidecar.LocalWakeAlias to a distinct word (e.g. \"Pebble\") so this device doesn't double-wake with the Mac brain."
                });
        }
        diagnostics.Record(DiagnosticLevel.Info, "wake", "configured",
            new Dictionary<string, object?>
            {
                ["device"] = sidecarSettings.DeviceName,
                ["identity"] = sidecarSettings.AssistantIdentityName,
                ["alias"] = sidecarSettings.EffectiveWakeAlias,
                ["aliasEnabled"] = sidecarSettings.WakeAliasEnabled
            });
        diagnostics.Record(DiagnosticLevel.Info, "boot", "Jarvis starting",
            new Dictionary<string, object?>
            {
                ["version"] = typeof(App).Assembly.GetName().Version?.ToString(),
                ["pid"] = Environment.ProcessId
            });

        _sampler = _services.GetRequiredService<PerformanceSampler>();
        _sampler.Start();

        _awareness = _services.GetRequiredService<IDesktopAwarenessService>();
        WireAwarenessToState();
        await _awareness.StartAsync();

        _overlay = _services.GetRequiredService<OverlayWindow>();
        _overlay.WebViewMissing += OnWebViewMissing;
        _overlay.WebViewFailed += OnWebViewFailed;
        _overlay.Show();

        _clipboardMonitor = _services.GetRequiredService<IClipboardMonitor>();
        await _clipboardMonitor.StartAsync();

        _browserBridge = _services.GetRequiredService<WebSocketBrowserContextProvider>();
        _browserBridge.Start();

        // Bring up the Mac sidecar bridge.
        _macBridge = _services.GetRequiredService<IMacBridgeCoordinator>();
        _macBridge.StatusChanged += OnBridgeStatusChanged;
        _macBridge.FrameReceived += OnBridgeFrame;
        await _macBridge.StartAsync();

        var focusTracker = _services.GetRequiredService<IFocusSessionTracker>();
        await focusTracker.StartAsync();

        var presenceManager = _services.GetRequiredService<IPresenceModeManager>();
        await presenceManager.StartAsync();

        var nudgeEngine = _services.GetRequiredService<IProactiveNudgeEngine>();
        await nudgeEngine.StartAsync();
        nudgeEngine.NudgeReady += (_, nudge) =>
            diagnostics.Record(DiagnosticLevel.Info, "proactive", nudge.Key,
                new Dictionary<string, object?> { ["msg"] = nudge.Message });

        var contextEngine = _services.GetRequiredService<Jarvis.Core.Context.IWindowsContextEngine>();
        await contextEngine.StartAsync();

        _contextPublisher = _services.GetRequiredService<ISidecarContextPublisher>();
        await _contextPublisher.StartAsync();

        _remoteExecutor = _services.GetRequiredService<IRemoteExecutionBridge>();
        _remoteExecutor.Attach();

        // P8 — tool layer + memory bridges
        _toolBridge = _services.GetRequiredService<WindowsToolBridge>();
        _toolBridge.Attach();
        _memoryBridge = _services.GetRequiredService<WindowsMemoryBridge>();
        _memoryBridge.Attach();

        // P7 — wire the orchestration + fallback coordinators (they self-subscribe to
        // bridge events; resolving them is enough to start them).
        var orchestration = _services.GetRequiredService<IRemoteOrchestrationCoordinator>();
        orchestration.Attach();
        // WIN-5: surface Mac orchestration frames as user-visible actions (#39).
        orchestration.SpeakRequested  += (_, text) => _ = tts.SpeakAsync(text);
        orchestration.SilenceRequested += (_, _)   => _ = tts.StopAsync();
        orchestration.ProactiveReceived += (_, notice) =>
            diagnostics.Record(DiagnosticLevel.Info, "proactive.notify", notice.Title ?? "notice",
                new Dictionary<string, object?> { ["source"] = notice.Source, ["text"] = notice.Body });
        _ = _services.GetRequiredService<IDistributedFallbackCoordinator>();
        var conversation = _services.GetRequiredService<IDistributedConversationCoordinator>();
        diagnostics.Record(DiagnosticLevel.Info, "conversation.session", "resumed",
            new Dictionary<string, object?>
            {
                ["sessionId"] = conversation.SessionId,
                ["deviceId"] = conversation.DeviceId,
                ["wakeAlias"] = conversation.WakeAlias
            });

        // P6.5 — audio runtime. The mic + STT + wake stack is started here; the partial-
        // transcript coordinator forwards STT events to the bridge after echo suppression.
        var stt = _services.GetRequiredService<ISpeechRecognitionProvider>();
        _partialCoord = _services.GetRequiredService<IPartialTranscriptCoordinator>();
        _partialCoord.Attach(stt);
        var tts = _services.GetRequiredService<ILocalTtsService>();
        _interruptCoord = _services.GetRequiredService<IPlaybackInterruptionCoordinator>();
        _interruptCoord.Attach(stt, tts);
        _interruptCoord.Interrupted += (_, _) =>
            _ = Dispatcher.BeginInvoke(() => _overlay?.Bridge?.PushInterruption());
        if (tts is Jarvis.App.Sidecar.WinRtTtsService realTts && _interruptCoord is PlaybackInterruptionCoordinator pic)
            realTts.PlaybackChanged = pic.NotifyPlaybackChanged;

        _mic = _services.GetRequiredService<IMicrophoneCapture>();
        _mic.Transcript += OnMicTranscript;
        if (_services.GetService<IWakeWordDetector>() is { } wake)
            wake.Detected += OnWakeDetected;
        try
        {
            // Only auto-start if the sidecar is enabled — otherwise the user is running
            // standalone and the mic stays cold until they wire something up.
            if (settingsStore.Current.Sidecar.Enabled && !settingsStore.Current.Sidecar.PrivacyMode)
                await _mic.StartAsync(settingsStore.Current.Sidecar.MicrophoneId);
        }
        catch (Exception ex)
        {
            diagnostics.Record(DiagnosticLevel.Warn, "mic", "auto-start failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }

        // Refresh the device list so the settings UI / diagnostics have something to show.
        var audioCoord = _services.GetRequiredService<IAudioDeviceCoordinator>();
        _ = audioCoord.RefreshAsync();

        // WIN-4: rebind mic when the default audio device changes (#39).
        audioCoord.DevicesChanged += async (_, _) =>
        {
            // Debounce: cancel any pending rebind and start a fresh one after a short delay
            // so a rapid add→remove sequence doesn't thrash Start/Stop.
            _micRebindCts?.Cancel();
            _micRebindCts = new CancellationTokenSource();
            var token = _micRebindCts.Token;
            try
            {
                await Task.Delay(300, token).ConfigureAwait(false);
                if (token.IsCancellationRequested) return;
                if (_mic is null) return;
                var cfg = settingsStore.Current.Sidecar;
                if (!cfg.Enabled || cfg.PrivacyMode) return;
                var newId = cfg.MicrophoneId
                    ?? audioCoord.Microphones.FirstOrDefault(m => m.IsDefault)?.Id;
                await _mic.StopAsync(token).ConfigureAwait(false);
                await _mic.StartAsync(newId, token).ConfigureAwait(false);
                diagnostics.Record(DiagnosticLevel.Info, "mic", "rebound after device change",
                    new Dictionary<string, object?> { ["mic"] = newId });
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                diagnostics.Record(DiagnosticLevel.Warn, "mic", "rebind failed",
                    new Dictionary<string, object?> { ["error"] = ex.Message });
            }
        };

        // WIN-8: re-cycle bridge + audio on resume from sleep/hibernate (#39).
        Microsoft.Win32.SystemEvents.PowerModeChanged += async (_, pme) =>
        {
            if (pme.Mode != Microsoft.Win32.PowerModes.Resume) return;
            diagnostics.Record(DiagnosticLevel.Info, "lifecycle", "resume — cycling bridge + audio");
            try
            {
                if (_macBridge is not null)
                {
                    await _macBridge.StopAsync().ConfigureAwait(false);
                    await _macBridge.StartAsync().ConfigureAwait(false);
                }
                _ = audioCoord.RefreshAsync();
            }
            catch (Exception ex)
            {
                diagnostics.Record(DiagnosticLevel.Warn, "lifecycle", "resume cycle failed",
                    new Dictionary<string, object?> { ["error"] = ex.Message });
            }
        };

        // P6.7 — drive the AmbientAttentionModel from the awareness signals at 4 Hz and
        // forward to the renderer so the breathing rate / halo intensity can dial subtly.
        var attention = _services.GetRequiredService<Jarvis.Core.Presence.AmbientAttentionModel>();
        attention.ModeChanged += (_, mode) => diagnostics.Record(DiagnosticLevel.Debug, "pebble.attention", "mode changed",
            new Dictionary<string, object?> { ["mode"] = mode.ToString() });
        _attentionTimer = new System.Windows.Threading.DispatcherTimer(System.Windows.Threading.DispatcherPriority.Background)
        { Interval = TimeSpan.FromMilliseconds(250) };
        _attentionTimer.Tick += (_, _) => TickAttention(attention);
        _attentionTimer.Start();

        // P6.1 — left+right mouse chord opens the Pebble Interaction Menu.
        if (settingsStore.Current.MouseChord.EnableMouseChordMenu)
        {
            _chord = new Jarvis.App.Chord.MouseChordService(
                () => settingsStore.Current.MouseChord,
                diagnostics,
                () => settingsStore.Current);
            _chord.ChordFired += (_, pos) => Dispatcher.BeginInvoke(() => OpenInteractionMenu(pos.X, pos.Y));
            _chord.Start();
        }

        _tray = new TrayController(
            overlay: _overlay,
            settings: settingsStore,
            diagnostics: diagnostics,
            openSettings: ShowSettings,
            setPerfHud: SetPerfHud,
            getPerfHud: () => _overlay?.Bridge?.HudOn ?? false,
            captureRegion: () => _ = CaptureRegionAsync(),
            openInspector: ShowInspector,
            ocrClipboardImage: () => _ = OcrClipboardImageAsync(),
            openAuditLog: ShowAuditLog,
            openGuidance: ShowGuidancePrompt,
            openChat: ShowChat,
            openLlmSettings: ShowLlmSettings,
            openRedactionPreview: ShowRedactionPreview,
            exportConversation: ExportConversation,
            openDashboard: ShowDashboard);
        _tray.QuitRequested += (_, _) => RequestShutdown("tray quit");

        // Real global hotkeys via RegisterHotKey.
        _hotkeyService = _services.GetRequiredService<GlobalHotkeyService>();
        var hk = settingsStore.Current.Hotkeys;
        _hotkeyService.Register("ToggleVisibility", hk.ToggleVisibility, ToggleOverlayVisibility);
        _hotkeyService.Register("CaptureRegion", "Ctrl+Shift+R", () => _ = CaptureRegionAsync());
        _hotkeyService.Register("OpenInspector", "Ctrl+Shift+I", ShowInspector);
        _hotkeyService.Register("OpenSettings", "Ctrl+Shift+,", ShowSettings);
        _hotkeyService.Register("OpenGuidance", "Ctrl+Shift+G", ShowGuidancePrompt);
        _hotkeyService.Register("ClickLastTarget", "Ctrl+Shift+Enter", () => _ = ClickLastTargetAsync());
        _hotkeyService.Register("OpenChat", "Ctrl+Shift+Space", ShowChat);
        _hotkeyService.Register("QuitJarvis", "Ctrl+Shift+Q", () => RequestShutdown("hotkey quit"));
    }

    private DashboardWindow? _dashboardWindow;

    private void ShowDashboard()
    {
        if (_services is null) return;
        if (_dashboardWindow is { IsLoaded: true }) { _dashboardWindow.Activate(); return; }
        var vm = _services.GetRequiredService<DashboardViewModel>();
        _dashboardWindow = new DashboardWindow(vm);
        _dashboardWindow.Closed += (_, _) => _dashboardWindow = null;
        _dashboardWindow.QuickActionRequested += OnDashboardQuickAction;
        _dashboardWindow.Show();
        _dashboardWindow.Activate();
    }

    private void OnDashboardQuickAction(object? sender, string action)
    {
        if (_services is null) return;
        var registry = _services.GetService<IWindowsToolRegistry>();
        var presenceManager = _services.GetService<IPresenceModeManager>();
        var vm = _services.GetService<DashboardViewModel>();

        switch (action)
        {
            case "toggle_focus":
                if (presenceManager is not null)
                {
                    if (presenceManager.Current == PresenceMode.Focus && presenceManager.IsUserOverride)
                        presenceManager.ClearOverride();
                    else
                        presenceManager.SetMode(PresenceMode.Focus);
                }
                break;

            case "screenshot":
                _ = Task.Run(async () =>
                {
                    var tool = registry?.Find("screenshot_window");
                    if (tool is null) return;
                    var req = new WindowsToolRequest("dashboard", "screenshot_window",
                        new Dictionary<string, string>(), false, "dashboard", DateTimeOffset.UtcNow);
                    var result = await tool.ExecuteAsync(req).ConfigureAwait(false);
                    vm?.RecordToolRun("screenshot_window", result.Success, result.Summary, result.PrivacyImpact);
                });
                break;

            case "running_apps":
                _ = Task.Run(async () =>
                {
                    var tool = registry?.Find("inspect_processes");
                    if (tool is null) return;
                    var req = new WindowsToolRequest("dashboard", "inspect_processes",
                        new Dictionary<string, string>(), false, "dashboard", DateTimeOffset.UtcNow);
                    var result = await tool.ExecuteAsync(req).ConfigureAwait(false);
                    vm?.RecordToolRun("inspect_processes", result.Success, result.Summary, result.PrivacyImpact);
                    if (result.Detail is not null)
                        _ = Dispatcher.BeginInvoke(() =>
                            System.Windows.MessageBox.Show(result.Detail, "Running Apps",
                                MessageBoxButton.OK, MessageBoxImage.None));
                });
                break;
        }
    }

    private Jarvis.App.Llm.LlmSettingsWindow? _llmSettingsWindow;
    private void ShowLlmSettings()
    {
        if (_services is null) return;
        if (_llmSettingsWindow is { IsLoaded: true }) { _llmSettingsWindow.Activate(); return; }
        _llmSettingsWindow = new Jarvis.App.Llm.LlmSettingsWindow(
            _services.GetRequiredService<IJarvisSettingsStore>(),
            _services.GetRequiredService<ILlmProviderManager>(),
            onSaved: () =>
            {
                // Chat panel refreshes its provider line on next turn; if open, hint via status.
                _services.GetRequiredService<IDiagnostics>().Record(DiagnosticLevel.Info, "llm", "settings reloaded");
            });
        _llmSettingsWindow.Closed += (_, _) => _llmSettingsWindow = null;
        _llmSettingsWindow.Show();
        _llmSettingsWindow.Activate();
    }

    private void ShowRedactionPreview()
    {
        if (_services is null) return;
        var window = new Jarvis.App.Llm.RedactionPreviewWindow(
            _services.GetRequiredService<IConversationService>(),
            _services.GetRequiredService<IConversationContextBuilder>(),
            _services.GetRequiredService<IContextBudgeter>());
        window.Show();
        window.Activate();
    }

    private void ExportConversation()
    {
        if (_services is null) return;
        var conversation = _services.GetRequiredService<IConversationService>();
        var manager = _services.GetService<ILlmProviderManager>();
        using var dlg = new System.Windows.Forms.SaveFileDialog
        {
            Title = "Export Jarvis conversation",
            Filter = "Markdown (*.md)|*.md|All files (*.*)|*.*",
            FileName = $"jarvis-chat-{DateTime.Now:yyyyMMdd-HHmmss}.md",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Desktop)
        };
        if (dlg.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
        var includeDebug = (System.Windows.Forms.Control.ModifierKeys & System.Windows.Forms.Keys.Shift)
            == System.Windows.Forms.Keys.Shift;
        var md = ConversationExporter.ToMarkdown(
            conversation.History, conversation.Diagnostics,
            new ConversationExportOptions(
                ProviderLine: manager is null ? null : $"{manager.Status.Type} · {manager.Status.Model}",
                IncludeDebugMetadata: includeDebug));
        try { System.IO.File.WriteAllText(dlg.FileName, md); } catch { }
    }

    private Jarvis.App.Chat.ChatPanelWindow? _chatWindow;
    private void ShowChat()
    {
        if (_services is null) return;
        if (_chatWindow is not null)
        {
            if (!_chatWindow.IsVisible) _chatWindow.Show();
            _chatWindow.Activate();
            return;
        }
        _chatWindow = new Jarvis.App.Chat.ChatPanelWindow(
            _services.GetRequiredService<IConversationService>(),
            _services.GetRequiredService<PebbleStateMachine>(),
            _services.GetService<ILlmProviderManager>());
        _chatWindow.Closed += (_, _) => _chatWindow = null;
        _chatWindow.Show();
        _chatWindow.Activate();
    }

    private async Task ClickLastTargetAsync()
    {
        if (_services is null) return;
        var guidance = _services.GetRequiredService<IGuidanceService>();
        var target = guidance.LastHighlighted;
        if (target is null)
        {
            _services.GetRequiredService<IDiagnostics>()
                .Record(DiagnosticLevel.Info, "guidance", "click-it: no last target");
            return;
        }
        var (cx, cy) = target.Center;
        var executor = _services.GetRequiredService<IAutomationExecutor>();
        await executor.ExecuteAsync(new ClickIntent((int)Math.Round(cx), (int)Math.Round(cy)));
        guidance.Clear();
    }

    private void ToggleOverlayVisibility()
    {
        if (_overlay is null) return;
        Dispatcher.BeginInvoke(() =>
        {
            if (_overlay.IsVisible) _overlay.Hide();
            else _overlay.Show();
        });
    }

    private void OnWebViewMissing(object? sender, EventArgs e)
    {
        var ans = MessageBox.Show(
            "Jarvis needs the Microsoft Edge WebView2 Runtime, which doesn't appear to be installed.\n\n" +
            "Open the download page now?",
            "Jarvis", MessageBoxButton.YesNo, MessageBoxImage.Information);
        if (ans == MessageBoxResult.Yes)
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = WebView2Runtime.DownloadUrl,
                    UseShellExecute = true
                });
            }
            catch { /* nothing useful to do */ }
        }
        RequestShutdown("WebView2 missing");
    }

    private void OnWebViewFailed(object? sender, Exception ex)
    {
        MessageBox.Show($"The pebble renderer couldn't start:\n\n{ex.Message}", "Jarvis",
            MessageBoxButton.OK, MessageBoxImage.Error);
        RequestShutdown("WebView2 init failed");
    }

    private void ShowSettings()
    {
        if (_services is null) return;
        if (_settingsWindow is { IsLoaded: true })
        {
            _settingsWindow.Activate();
            return;
        }
        var store = _services.GetRequiredService<IJarvisSettingsStore>();
        _settingsWindow = new SettingsWindow(store, _overlay?.Bridge?.HudOn ?? false, _macBridge);
        var ok = _settingsWindow.ShowDialog();
        if (ok == true) SetPerfHud(_settingsWindow.PerfHudRequested);
        _settingsWindow = null;
    }

    private void SetPerfHud(bool on) => _overlay?.Bridge?.SetHud(on);

    private Jarvis.App.Guidance.GuidancePromptWindow? _guidanceWindow;
    private void ShowGuidancePrompt()
    {
        if (_services is null) return;
        if (_guidanceWindow is { IsLoaded: true }) { _guidanceWindow.Activate(); return; }
        _guidanceWindow = new Jarvis.App.Guidance.GuidancePromptWindow(
            _services.GetRequiredService<IGuidanceService>(),
            _services.GetRequiredService<IAutomationExecutor>());
        _guidanceWindow.Closed += (_, _) => _guidanceWindow = null;
        _guidanceWindow.Show();
        _guidanceWindow.Activate();
    }

    private AuditLogWindow? _auditWindow;
    private void ShowAuditLog()
    {
        if (_services is null) return;
        if (_auditWindow is { IsLoaded: true }) { _auditWindow.Activate(); return; }
        _auditWindow = new AuditLogWindow(_services.GetRequiredService<IAuditLog>());
        _auditWindow.Closed += (_, _) => _auditWindow = null;
        _auditWindow.Show();
    }

    private void ShowInspector()
    {
        if (_services is null) return;
        if (_inspectorWindow is { IsLoaded: true })
        {
            _inspectorWindow.Activate();
            return;
        }
        var perception = _services.GetRequiredService<PerceptionService>();
        var diagnostics = _services.GetRequiredService<IDiagnostics>();
        var audit = _services.GetRequiredService<IAuditLog>();
        _inspectorWindow = new ContextInspectorWindow(
            perception: perception,
            ocrProvider: () =>
            {
                var ocr = perception.RecentOcr;
                return ocr is null ? null : new ContextInspectorWindow.OcrSummary(ocr.Text, ocr.Duration.TotalMilliseconds, ocr.Language);
            },
            diagnostics: diagnostics,
            audit: audit,
            guidance: _services.GetRequiredService<IGuidanceService>(),
            highlighter: _services.GetRequiredService<IHighlightRenderer>());
        _inspectorWindow.Closed += (_, _) => _inspectorWindow = null;
        _inspectorWindow.Show();
    }

    private async Task OcrClipboardImageAsync()
    {
        if (_services is null || _clipboardMonitor is null) return;
        var ocr = _services.GetRequiredService<IOcrService>();
        var perception = _services.GetRequiredService<PerceptionService>();
        var diagnostics = _services.GetRequiredService<IDiagnostics>();
        try
        {
            var png = (_clipboardMonitor as ClipboardMonitor)?.TryGetLatestImageAsPng();
            if (png is null || png.Length == 0)
            {
                diagnostics.Record(DiagnosticLevel.Info, "ocr", "no clipboard image to OCR");
                return;
            }
            if (!ocr.IsAvailable) return;
            var result = await ocr.RecognizeAsync(png);
            perception.SetRecentOcr(result);
            SurfaceOcrResult(result.Text);
        }
        catch (Exception ex)
        {
            diagnostics.Record(DiagnosticLevel.Warn, "ocr", "clipboard OCR failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }
    }

    private async Task CaptureRegionAsync()
    {
        var text = await CaptureRegionForTextAsync(CancellationToken.None);
        SurfaceOcrResult(text);
    }

    /// <summary>After a successful OCR, put the text on the clipboard and pop a balloon
    /// so the user actually sees something happened. Empty / null results are silent.</summary>
    private void SurfaceOcrResult(string? text)
    {
        if (_services is null) return;
        if (string.IsNullOrWhiteSpace(text)) return;
        try { System.Windows.Clipboard.SetText(text); } catch { /* clipboard contention */ }
        var diagnostics = _services.GetRequiredService<IDiagnostics>();
        diagnostics.Record(DiagnosticLevel.Info, "ocr", "captured to clipboard",
            new Dictionary<string, object?> { ["chars"] = text.Length });
        // Brief peek of the captured text in the diagnostics channel so it's visible
        // in the audit / log even without opening the inspector.
        var preview = text.Length > 80 ? text[..80] + "…" : text;
        diagnostics.Record(DiagnosticLevel.Debug, "ocr", "result", new Dictionary<string, object?> { ["text"] = preview });
    }

    /// <summary>Capture + OCR a region. Returns the recognised text (or null when
    /// cancelled / OCR engine missing). Side effect: updates PerceptionService's recent OCR.</summary>
    private async Task<string?> CaptureRegionForTextAsync(CancellationToken cancellationToken)
    {
        if (_services is null) return null;
        var capture = _services.GetRequiredService<IRegionCapture>();
        var ocr = _services.GetRequiredService<IOcrService>();
        var perception = _services.GetRequiredService<PerceptionService>();
        var diagnostics = _services.GetRequiredService<IDiagnostics>();

        try
        {
            var result = await capture.CaptureAsync(cancellationToken);
            if (result is null) return null;
            if (!ocr.IsAvailable)
            {
                diagnostics.Record(DiagnosticLevel.Warn, "capture", "OCR engine unavailable; no language pack");
                return null;
            }
            var ocrResult = await ocr.RecognizeAsync(result.PngBytes, cancellationToken);
            perception.SetRecentOcr(ocrResult);
            return ocrResult.Text;
        }
        catch (OperationCanceledException) { return null; }
        catch (Exception ex)
        {
            diagnostics.Record(DiagnosticLevel.Warn, "capture", "pipeline failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            return null;
        }
    }

    private void OnBridgeStatusChanged(object? sender, BridgeStatus status)
    {
        if (_services is null) return;
        var sm = _services.GetService<PebbleStateMachine>();
        if (sm is null) return;
        Dispatcher.BeginInvoke(() =>
        {
            sm.Apply(sm.LastInputs with
            {
                BridgeReconnecting = status.State == BridgeState.Reconnecting,
                BridgeDegraded = status.State == BridgeState.Degraded
            });
        });

        // Also update dashboard VM with live bridge status.
        var vm = _services.GetService<DashboardViewModel>();
        if (vm is not null)
            Dispatcher.BeginInvoke(() => vm.BridgeStatus = status.State.ToString());
    }

    private void OnBridgeFrame(object? sender, SidecarFrame frame)
    {
        if (_services is null) return;
        // Speaker activity → Pebble; lease handling is delegated to TtsLeaseCoordinator.
        var lease = _services.GetService<ITtsLeaseCoordinator>();
        lease?.ApplyInbound(frame);
        if (frame.Type == SidecarFrameTypes.SpeakerActive && frame.Source == "mac")
            UpdateRemoteSpeaking(true);
        else if (frame.Type == SidecarFrameTypes.SpeakerSilent && frame.Source == "mac")
            UpdateRemoteSpeaking(false);
    }

    private void UpdateRemoteSpeaking(bool active)
    {
        var sm = _services?.GetService<PebbleStateMachine>();
        if (sm is null) return;
        Dispatcher.BeginInvoke(() => sm.Apply(sm.LastInputs with { RemoteSpeaking = active }));
    }

    private void OpenInteractionMenu(int cursorPxX, int cursorPxY)
    {
        if (_services is null) return;
        if (_menu is { IsLoaded: true }) { _menu.Activate(); return; }

        var diagnostics = _services.GetRequiredService<IDiagnostics>();
        var sidecar = _services.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar;

        // Items mapped to existing app commands. Mute toggles privacy; reconnect bounces the bridge.
        var items = new List<Jarvis.App.Chord.PebbleInteractionMenuWindow.MenuItem>
        {
            new("Chat",              "💬", ShowChat),
            new("Where do I click?", "🎯", ShowGuidancePrompt),
            new("OCR region",        "🔍", () => _ = CaptureRegionAsync()),
            new("OCR clipboard image","📋", () => _ = OcrClipboardImageAsync()),
            new("Inspect context",   "🔎", ShowInspector),
            new("Settings",          "⚙️", ShowSettings),
            new("LLM settings",      "🤖", ShowLlmSettings),
            new(sidecar.PrivacyMode ? "Unmute" : "Mute", "🔇", ToggleMute),
            new("Reconnect sidecar", "🔌", () => _ = ReconnectSidecarAsync()),
            new("Close menu",        "✕",  () => { /* close is automatic after Select */ }),
        };

        _menu = new Jarvis.App.Chord.PebbleInteractionMenuWindow(items, diagnostics);
        _menu.Closed += (_, _) =>
        {
            var reason = _menu?.CloseReason ?? "unknown";
            var selected = _menu?.LastSelectedItem ?? "";
            diagnostics.Record(DiagnosticLevel.Info, "chord.menu", "closed",
                new Dictionary<string, object?> { ["reason"] = reason, ["item"] = selected });
            _menu = null;
            // Renderer hint: drop the menu-open visual.
            _overlay?.Bridge?.PushMenuOpen(false);
        };
        diagnostics.Record(DiagnosticLevel.Info, "chord.menu", "opened",
            new Dictionary<string, object?> { ["x"] = cursorPxX, ["y"] = cursorPxY });
        _overlay?.Bridge?.PushMenuOpen(true);
        _menu.ShowAt(cursorPxX, cursorPxY);
    }

    private void CloseInteractionMenu()
    {
        if (_menu is null) return;
        Dispatcher.BeginInvoke(() =>
        {
            if (_menu is null) return;
            // The window's Closed handler logs + nulls _menu.
            try { _menu.Close(); } catch { }
        });
    }

    private void ToggleMute()
    {
        if (_services is null) return;
        var store = _services.GetRequiredService<IJarvisSettingsStore>();
        var s = store.Current;
        var next = s with { Sidecar = s.Sidecar with { PrivacyMode = !s.Sidecar.PrivacyMode } };
        _ = store.SaveAsync(next);
        // Echo suppressor honours PrivacyMode directly so the mic suppresses on next transcript.
        _services.GetService<IEchoSuppressionCoordinator>()?.SetPrivacyMode(next.Sidecar.PrivacyMode);
    }

    private async Task ReconnectSidecarAsync()
    {
        if (_services is null || _macBridge is null) return;
        try
        {
            await _macBridge.StopAsync();
            await _macBridge.StartAsync();
        }
        catch (Exception ex)
        {
            _services.GetService<IDiagnostics>()?.Record(DiagnosticLevel.Warn, "sidecar.bridge",
                "manual reconnect failed", new Dictionary<string, object?> { ["error"] = ex.Message });
        }
    }

    private void OnMicTranscript(object? sender, TranscriptEvent ev)
    {
        var sm = _services?.GetService<PebbleStateMachine>();
        if (sm is null) return;
        Dispatcher.BeginInvoke(() =>
        {
            // Listening flicks on for the duration of an utterance; the state machine
            // collapses Listening to Idle once Listening is false again.
            sm.Apply(sm.LastInputs with
            {
                Listening = !ev.IsFinal,
                MicrophoneOpen = true
            });
        });
    }

    private async void OnWakeDetected(object? sender, WakeDetection ev)
    {
        // Log who woke. The wake alias is the *local* device's word — the assistant
        // identity is constant on Mac. This is attribution only, not personality.
        var settings = _services?.GetService<IJarvisSettingsStore>()?.Current.Sidecar;
        _services?.GetService<IDiagnostics>()?.Record(DiagnosticLevel.Info, "wake", "device woke",
            new Dictionary<string, object?>
            {
                ["alias"] = settings?.EffectiveWakeAlias,
                ["device"] = settings?.DeviceName,
                ["identity"] = settings?.AssistantIdentityName,
                ["confidence"] = ev.Confidence
            });

        var sm = _services?.GetService<PebbleStateMachine>();
        if (sm is null) return;
        _ = Dispatcher.BeginInvoke(() =>
        {
            sm.Apply(sm.LastInputs with { WakeDetected = true });
            _overlay?.Bridge?.PushWakeRipple();
        });
        try { await Task.Delay(800).ConfigureAwait(false); } catch { }
        _ = Dispatcher.BeginInvoke(() => sm.Apply(sm.LastInputs with { WakeDetected = false }));
    }

    private void WireAwarenessToState()
    {
        if (_awareness is null || _services is null) return;
        var machine = _services.GetRequiredService<PebbleStateMachine>();
        _awareness.SnapshotChanged += (_, snap) =>
        {
            // Track app switches + last-input time for the attention model.
            if (!string.Equals(snap.ForegroundProcessName, _lastForegroundApp, StringComparison.Ordinal))
            {
                _lastForegroundApp = snap.ForegroundProcessName;
                _recentAppSwitches++;
                _lastAppChangeAt = DateTimeOffset.UtcNow;
            }
            if (snap.IsUserActive) _lastInputAt = DateTimeOffset.UtcNow;

            var inputs = machine.LastInputs with
            {
                ForegroundApp = snap.ForegroundProcessName,
                UserActive = snap.IsUserActive
            };
            Dispatcher.BeginInvoke(() => machine.Apply(inputs));
        };
    }

    private void TickAttention(Jarvis.Core.Presence.AmbientAttentionModel attention)
    {
        if (_services is null) return;
        var velocity = _overlay?.Follower?.LastCursorVelocity ?? 0;

        // Recent-switch window: decay every tick so the model sees a 30-second moving sum.
        if (DateTimeOffset.UtcNow - _lastAppChangeAt > TimeSpan.FromSeconds(30))
            _recentAppSwitches = Math.Max(0, _recentAppSwitches - 1);

        var idle = (DateTimeOffset.UtcNow - _lastInputAt).TotalSeconds;
        var stableFocus = !string.IsNullOrEmpty(_lastForegroundApp)
            && DateTimeOffset.UtcNow - _lastAppChangeAt > TimeSpan.FromSeconds(30);

        var signals = new Jarvis.Core.Presence.AttentionSignals(
            CursorVelocity: velocity,
            TypingRate: 0, // typing-rate signal would need IInputObserver — left for future
            RecentAppSwitches: _recentAppSwitches,
            RecentInterruptions: 0,
            IdleSeconds: idle,
            StableFocus: stableFocus);
        var mode = attention.Observe(signals);

        // Push attention to the renderer (single message; no allocation hot loop).
        _overlay?.Bridge?.PushAttention(mode, attention.Intensity);
    }

    private void RequestShutdown(string reason)
    {
        if (_shuttingDown) return;
        _shuttingDown = true;
        _services?.GetRequiredService<IDiagnostics>().Record(DiagnosticLevel.Info, "lifecycle",
            "shutdown requested", new Dictionary<string, object?> { ["reason"] = reason });
        Dispatcher.BeginInvoke(() => Shutdown());
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        try
        {
            _tray?.Dispose();
            _hotkeyService?.Dispose();
            _attentionTimer?.Stop();
            _chord?.Dispose();
            try { _menu?.Close(); } catch { }
            if (_partialCoord is IDisposable pcd) pcd.Dispose();
            if (_interruptCoord is IDisposable icd) icd.Dispose();
            if (_mic is not null) { try { await _mic.StopAsync(); } catch { } await _mic.DisposeAsync(); }
            _remoteExecutor?.Dispose();
            _toolBridge?.Dispose();
            _memoryBridge?.Dispose();
            if (_contextPublisher is not null) await _contextPublisher.DisposeAsync();
            if (_macBridge is not null)
            {
                _macBridge.StatusChanged -= OnBridgeStatusChanged;
                _macBridge.FrameReceived -= OnBridgeFrame;
                await _macBridge.DisposeAsync();
            }
            if (_browserBridge is not null) await _browserBridge.DisposeAsync();
            if (_clipboardMonitor is not null) await _clipboardMonitor.DisposeAsync();
            if (_awareness is not null) await _awareness.DisposeAsync();
            if (_sampler is not null) await _sampler.DisposeAsync();
            if (_fileSink is not null) await _fileSink.DisposeAsync();
        }
        catch { /* shutting down */ }
        _micRebindCts?.Cancel();
        try { _singleInstanceMutex?.ReleaseMutex(); } catch { }
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }

    private void OnDomainUnhandled(object sender, UnhandledExceptionEventArgs e) =>
        _services?.GetService<IDiagnostics>()?.Record(DiagnosticLevel.Error, "crash",
            "AppDomain unhandled", new Dictionary<string, object?> { ["error"] = e.ExceptionObject?.ToString() });

    private void OnDispatcherUnhandled(object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
    {
        _services?.GetService<IDiagnostics>()?.Record(DiagnosticLevel.Error, "crash",
            "Dispatcher unhandled", new Dictionary<string, object?> { ["error"] = e.Exception.Message });
        // Swallow so a single UI-thread blip doesn't kill the overlay; tray quit is the real exit.
        e.Handled = true;
    }

    private void OnTaskUnhandled(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        _services?.GetService<IDiagnostics>()?.Record(DiagnosticLevel.Warn, "crash",
            "Unobserved task", new Dictionary<string, object?> { ["error"] = e.Exception.Message });
        e.SetObserved();
    }

    private static void ConfigureServices(IServiceCollection services)
    {
        services.AddLogging(b => b.AddDebug().SetMinimumLevel(LogLevel.Debug));

        services.AddSingleton<IJarvisSettingsStore, JsonSettingsStore>();
        services.AddSingleton<IDiagnostics>(_ => new DiagnosticsFileSink(new DiagnosticsService(capacity: 2048)));
        services.AddSingleton<PerformanceSampler>();
        services.AddSingleton<PebbleStateMachine>();
        services.AddSingleton<Jarvis.Core.Presence.AmbientAttentionModel>();
        services.AddSingleton<Jarvis.Core.Presence.AmplitudeSmoother>(_ => new Jarvis.Core.Presence.AmplitudeSmoother());
        services.AddSingleton<IDesktopAwarenessService, DesktopAwarenessService>();
        services.AddSingleton<GlobalHotkeyService>();
        services.AddSingleton<IHotkeyService>(sp => sp.GetRequiredService<GlobalHotkeyService>());

        // Perception
        services.AddSingleton<ISemanticContentClassifier, SemanticContentClassifier>();
        services.AddSingleton<IClipboardMonitor, ClipboardMonitor>();
        services.AddSingleton<ISelectedTextProvider, UIAutomationSelectedTextProvider>();
        services.AddSingleton<IOcrPostProcessor, OcrPostProcessor>();
        services.AddSingleton<IOcrService, WindowsOcrService>();
        services.AddSingleton<IIdeContextProvider>(sp => new WindowTitleIdeContextProvider(
            () => sp.GetRequiredService<IDesktopAwarenessService>().Latest,
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<WebSocketBrowserContextProvider>(sp => new WebSocketBrowserContextProvider(
            diagnostics: sp.GetService<IDiagnostics>()));
        services.AddSingleton<IBrowserContext>(sp => sp.GetRequiredService<WebSocketBrowserContextProvider>());
        services.AddSingleton<IWorkflowCategorizer, WorkflowCategorizer>();
        services.AddSingleton<ISemanticSnapshotBuilder, SemanticSnapshotBuilder>();
        services.AddSingleton<IRegionSelectionUi, WpfRegionSelectionUi>();
        services.AddSingleton<IScreenGrabber, GdiScreenGrabber>();
        services.AddSingleton<IRegionCapture, RegionCaptureCoordinator>();
        services.AddSingleton<PerceptionService>();

        // Automation (P3)
        services.AddSingleton<IApprovalPolicy, DefaultApprovalPolicy>();
        services.AddSingleton<IDryRunPlanner, DryRunPlanner>();
        services.AddSingleton<IApprovalGate, WpfApprovalGate>();
        services.AddSingleton<IAuditLog>(_ => new JsonlAuditLog());
        services.AddSingleton<IRateLimiter>(_ => new TokenBucketRateLimiter());
        services.AddSingleton<IElevationProbe, Win32ElevationProbe>();
        services.AddSingleton<IHighlightRenderer, WpfHighlightRenderer>();
        services.AddSingleton<IWindowAutomationSurface, Win32WindowSurface>();
        services.AddSingleton<IInputAutomationSurface, Win32InputSurface>();
        services.AddSingleton<IFileAutomationSurface, FileSurface>();
        services.AddSingleton<IBrowserCommandSurface>(sp => new BridgeBrowserCommandSurface(
            sp.GetRequiredService<WebSocketBrowserContextProvider>()));
        services.AddSingleton<IAutomationExecutor, AutomationExecutor>();

        // Guidance (P4)
        services.AddSingleton<IUiTargetSource, UIAutomationTargetSource>();
        services.AddSingleton<IUiTargetSource>(sp => new BrowserDomTargetSource(
            sp.GetRequiredService<IBrowserCommandSurface>(),
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<IUiTargetSource>(sp => new OcrTargetSource(
            grabPng: bounds =>
            {
                var grabber = sp.GetRequiredService<IScreenGrabber>();
                var sel = new Jarvis.Perception.Capture.RegionSelection(bounds, 0, 1.0);
                return Task.FromResult<byte[]?>(grabber.CaptureToPng(sel));
            },
            ocr: sp.GetRequiredService<IOcrService>(),
            diagnostics: sp.GetService<IDiagnostics>()));
        // Conversation (P5 + P5.5)
        services.AddSingleton<IConversationContextBuilder>(sp => new ContextBuilder(
            sp.GetRequiredService<PerceptionService>(),
            sp.GetRequiredService<IGuidanceService>()));
        services.AddSingleton<IRedactor>(sp => new RedactionService(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Redaction));
        services.AddSingleton<IContextBudgeter>(sp => new ContextBudgeter(
            sp.GetRequiredService<IRedactor>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Redaction,
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Llm));
        services.AddSingleton<ILlmProviderManager>(sp => new Jarvis.Perception.Conversation.Providers.LlmProviderManager(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Llm,
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<ILlmClient>(sp => sp.GetRequiredService<ILlmProviderManager>());
        services.AddSingleton<ILocalIntentRouter>(sp => new LocalIntentRouter(
            sp.GetRequiredService<IGuidanceService>(),
            sp.GetRequiredService<IAutomationExecutor>(),
            sp.GetRequiredService<IHighlightRenderer>(),
            captureRegion: null, // late-bound below via property after the app is up
            diagnostics: sp.GetService<IDiagnostics>()));
        services.AddSingleton<IQuotaGuard>(sp => new DailyQuotaGuard(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Quota));

        // Sidecar (P6) — Windows is the desktop sidecar; Mac is the brain.
        services.AddSingleton<IMacBridgeCoordinator>(sp => new MacBridgeCoordinator(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar,
            sp.GetService<IDiagnostics>(),
            gateway: () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Gateway));
        // P7 — distributed conversation continuity + degraded-mode replay buffer.
        services.AddSingleton<IDistributedConversationCoordinator>(sp => new DistributedConversationCoordinator(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar,
            diagnostics: sp.GetService<IDiagnostics>()));
        services.AddSingleton<IDistributedFallbackCoordinator>(sp => new DistributedFallbackCoordinator(
            sp.GetRequiredService<IMacBridgeCoordinator>(),
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<IRemoteOrchestrationCoordinator>(sp => new RemoteOrchestrationCoordinator(
            sp.GetRequiredService<IMacBridgeCoordinator>(),
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<ITtsLeaseCoordinator>(sp => new TtsLeaseCoordinator(
            sp.GetRequiredService<IMacBridgeCoordinator>(),
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<IEchoSuppressionCoordinator>(sp => new EchoSuppressionCoordinator(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar));
        services.AddSingleton<SidecarLlmClient>(sp => new SidecarLlmClient(
            sp.GetRequiredService<IMacBridgeCoordinator>()));
        // P6.5 — real WinRT audio runtime. Stubs remain in the source tree as test seams.
        services.AddSingleton<AudioDiagnostics>();
        services.AddSingleton<IAudioDeviceCoordinator>(sp => new Jarvis.App.Sidecar.WinRtAudioDeviceCoordinator(
            sp.GetService<IDiagnostics>(),
            sp.GetService<AudioDiagnostics>()));
        services.AddSingleton<IWakeWordDetector>(sp => new Jarvis.App.Sidecar.WinRtKeywordWakeWordService(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar,
            sp.GetService<IEchoSuppressionCoordinator>(),
            sp.GetService<IDiagnostics>(),
            sp.GetService<AudioDiagnostics>()));
        services.AddSingleton<ISpeechRecognitionProvider>(sp => new Jarvis.App.Sidecar.WinRtSpeechRecognitionService(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar,
            sp.GetService<IDiagnostics>(),
            sp.GetService<AudioDiagnostics>()));
        services.AddSingleton<IMicrophoneCapture>(sp => new Jarvis.App.Sidecar.WinRtMicrophoneCapture(
            sp.GetRequiredService<IWakeWordDetector>(),
            sp.GetRequiredService<ISpeechRecognitionProvider>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar,
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<IReplyLogger, JsonlReplyLogger>();
        services.AddSingleton<ILocalTtsService>(sp =>
        {
            var inner = new Jarvis.App.Sidecar.WinRtTtsService(
                sp.GetRequiredService<ITtsLeaseCoordinator>(),
                () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar,
                sp.GetService<IDiagnostics>(),
                sp.GetService<AudioDiagnostics>());
            return new LoggingTtsService(inner, sp.GetRequiredService<IReplyLogger>());
        });
        services.AddSingleton<IPartialTranscriptCoordinator>(sp => new PartialTranscriptCoordinator(
            sp.GetRequiredService<IMacBridgeCoordinator>(),
            sp.GetRequiredService<IEchoSuppressionCoordinator>(),
            sp.GetRequiredService<AudioDiagnostics>(),
            sp.GetService<IDiagnostics>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar,
            sp.GetService<IDistributedConversationCoordinator>()));
        services.AddSingleton<IPlaybackInterruptionCoordinator>(sp => new PlaybackInterruptionCoordinator(
            sp.GetRequiredService<IMacBridgeCoordinator>(),
            sp.GetRequiredService<IEchoSuppressionCoordinator>(),
            sp.GetRequiredService<ITtsLeaseCoordinator>(),
            sp.GetRequiredService<AudioDiagnostics>(),
            (PartialTranscriptCoordinator?)sp.GetService<IPartialTranscriptCoordinator>(),
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<ISidecarContextPublisher>(sp => new SidecarContextPublisher(
            sp.GetRequiredService<PerceptionService>(),
            sp.GetRequiredService<IConversationContextBuilder>(),
            sp.GetRequiredService<IContextBudgeter>(),
            sp.GetRequiredService<IMacBridgeCoordinator>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar,
            contextEngine: sp.GetService<Jarvis.Core.Context.IWindowsContextEngine>(),
            awarenessSettings: () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Awareness));
        services.AddSingleton<IRemoteExecutionBridge>(sp => new RemoteExecutionBridge(
            sp.GetRequiredService<IMacBridgeCoordinator>(),
            sp.GetRequiredService<IAutomationExecutor>(),
            sp.GetService<IDiagnostics>()));

        // The chat panel's ILlmClient is now the degraded-mode router (Mac when up, local otherwise).
        services.AddSingleton<DegradedModeRouter>(sp => new DegradedModeRouter(
            sp.GetRequiredService<IMacBridgeCoordinator>(),
            sp.GetRequiredService<SidecarLlmClient>(),
            localFallback: sp.GetRequiredService<ILlmProviderManager>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar));

        services.AddSingleton<IConversationService>(sp => new ConversationService(
            sp.GetRequiredService<IConversationContextBuilder>(),
            sp.GetRequiredService<ILocalIntentRouter>(),
            // Sidecar router becomes the LLM client; falls back to the cloud/local stack
            // (existing P5.5 provider manager) when the Mac bridge is down.
            sp.GetRequiredService<DegradedModeRouter>(),
            sp.GetRequiredService<IContextBudgeter>(),
            sp.GetRequiredService<IQuotaGuard>(),
            sp.GetService<IDiagnostics>()));

        services.AddSingleton<IGuidanceService>(sp => new GuidanceService(
            awareness: sp.GetRequiredService<IDesktopAwarenessService>(),
            browser: sp.GetRequiredService<IBrowserContext>(),
            highlighter: sp.GetRequiredService<IHighlightRenderer>(),
            sources: sp.GetServices<IUiTargetSource>(),
            cursorReader: () => Jarvis.App.Interop.CursorInterop.GetCursor(),
            diagnostics: sp.GetService<IDiagnostics>()));

        services.AddTransient<OverlayWindow>();

        // Context awareness
        services.AddSingleton<IAppUsageTracker>(sp => new AppUsageTracker(
            sp.GetRequiredService<IDesktopAwarenessService>(),
            sp.GetRequiredService<IWorkflowCategorizer>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Awareness));

        // Focus + presence + proactive
        services.AddSingleton<IFocusSessionTracker>(sp => new FocusSessionTracker(
            sp.GetRequiredService<IAppUsageTracker>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Awareness,
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<IPresenceModeManager>(sp => new PresenceModeManager(
            sp.GetRequiredService<IFocusSessionTracker>(),
            sp.GetRequiredService<IAppUsageTracker>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Awareness,
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<ISessionMemoryStore>(sp => new SessionMemoryStore(
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<IProactiveNudgeEngine>(sp => new ProactiveNudgeEngine(
            sp.GetRequiredService<IFocusSessionTracker>(),
            sp.GetRequiredService<IPresenceModeManager>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Proactivity,
            sp.GetService<IDiagnostics>()));

        // Context engine
        services.AddSingleton<Jarvis.Core.Context.IWindowsContextSnapshotBuilder, Jarvis.Perception.Context.WindowsContextSnapshotBuilder>();
        services.AddSingleton<Jarvis.Core.Context.IWindowsContextEngine>(sp => new Jarvis.Perception.Context.WindowsContextEngine(
            sp.GetRequiredService<PerceptionService>(),
            sp.GetRequiredService<IAppUsageTracker>(),
            sp.GetRequiredService<Jarvis.Core.Context.IWindowsContextSnapshotBuilder>(),
            sp.GetRequiredService<IFocusSessionTracker>(),
            sp.GetRequiredService<IPresenceModeManager>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.ContextEngine,
            sp.GetService<IDiagnostics>()));

        // Dashboard
        services.AddSingleton<DashboardViewModel>(sp =>
        {
            var vm = new DashboardViewModel();
            var engine = sp.GetRequiredService<Jarvis.Core.Context.IWindowsContextEngine>();
            engine.ContextChanged += (_, snap) =>
                System.Windows.Application.Current.Dispatcher.BeginInvoke(() => vm.ApplyContextSnapshot(snap));
            return vm;
        });

        // ─── P8: Tool layer ──────────────────────────────────────────────────────────

        // Register individual tools
        services.AddSingleton<IWindowsTool, OpenAppTool>();
        services.AddSingleton<IWindowsTool, FocusAppTool>();
        services.AddSingleton<IWindowsTool>(sp => new CloseAppTool(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Tools));
        services.AddSingleton<IWindowsTool>(sp => new ScreenshotWindowTool(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Tools));
        services.AddSingleton<IWindowsTool>(sp => new ClipboardSummaryTool(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Tools));
        services.AddSingleton<IWindowsTool, VolumeMicTool>();
        services.AddSingleton<IWindowsTool, ProcessInspectTool>();
        services.AddSingleton<IWindowsTool>(sp => new OpenProjectTool(
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Projects));

        // Tool registry
        services.AddSingleton<IWindowsToolRegistry>(sp => new WindowsToolRegistry(
            sp.GetServices<IWindowsTool>(),
            () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Tools));

        // Desktop memory query service
        services.AddSingleton<IDesktopMemoryQueryService>(sp => new DesktopMemoryQueryService(
            sp.GetRequiredService<ISessionMemoryStore>(),
            sp.GetRequiredService<IAppUsageTracker>(),
            sp.GetRequiredService<IFocusSessionTracker>()));

        // Bridges (Attach() called in OnStartup)
        services.AddSingleton<WindowsToolBridge>(sp => new WindowsToolBridge(
            sp.GetRequiredService<IMacBridgeCoordinator>(),
            sp.GetRequiredService<IWindowsToolRegistry>(),
            sp.GetService<IDiagnostics>()));
        services.AddSingleton<WindowsMemoryBridge>(sp => new WindowsMemoryBridge(
            sp.GetRequiredService<IMacBridgeCoordinator>(),
            sp.GetRequiredService<IDesktopMemoryQueryService>(),
            sp.GetService<IDiagnostics>()));
    }
}
