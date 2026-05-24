using System.Windows;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using MessageBox = System.Windows.MessageBox;
using MessageBoxButton = System.Windows.MessageBoxButton;
using MessageBoxImage = System.Windows.MessageBoxImage;

namespace Jarvis.App;

public partial class SettingsWindow : Window
{
    private readonly IJarvisSettingsStore _store;
    private readonly IMacBridgeCoordinator? _bridge;
    private bool _perfHud;

    public SettingsWindow(IJarvisSettingsStore store, bool perfHudOn, IMacBridgeCoordinator? bridge = null)
    {
        _store = store;
        _bridge = bridge;
        InitializeComponent();
        _perfHud = perfHudOn;
        LoadFromSettings(store.Current);
        RefreshE2EButtons();
    }

    public bool PerfHudRequested { get; private set; }

    private void LoadFromSettings(JarvisSettings s)
    {
        SizeSlider.Value = s.Pebble.Size;
        OpacitySlider.Value = s.Pebble.Opacity;
        EasingSlider.Value = s.Pebble.FollowEasing;
        FollowCursorCheck.IsChecked = s.Pebble.FollowCursor;
        AnimationsCheck.IsChecked = s.Pebble.AnimationsEnabled;
        ClickThroughCheck.IsChecked = s.Overlay.ClickThrough;
        AlwaysOnTopCheck.IsChecked = s.Overlay.AlwaysOnTop;
        ReducedMotionCheck.IsChecked = s.Performance.ReducedMotion;
        RespectBatteryCheck.IsChecked = s.Performance.RespectBatterySaver;
        GpuAccelCheck.IsChecked = s.Performance.GpuAcceleration;
        PerfHudCheck.IsChecked = _perfHud;

        // Gateway config (Phase 2).
        GatewayBaseUrlBox.Text = s.Gateway.BaseUrl;
        RefreshPairingStatus(s.Gateway);

        SidecarEnabledCheck.IsChecked = s.Sidecar.Enabled;
        BridgeUrlBox.Text = s.Sidecar.BridgeUrl;
        BridgeTokenBox.Password = s.Sidecar.BridgeToken ?? string.Empty;
        AutoReconnectCheck.IsChecked = s.Sidecar.AutoReconnect;
        OfflineDegradedCheck.IsChecked = s.Sidecar.OfflineDegradedModeEnabled;
        WakeWordEnabledCheck.IsChecked = s.Sidecar.WakeWordEnabled;
        LocalWakeAliasBox.Text = s.Sidecar.LocalWakeAlias;
        DeviceNameBox.Text = s.Sidecar.DeviceName;
        LocalTtsEnabledCheck.IsChecked = s.Sidecar.LocalTtsEnabled;
        PrivacyModeCheck.IsChecked = s.Sidecar.PrivacyMode;
        MouseChordEnabledCheck.IsChecked = s.MouseChord.EnableMouseChordMenu;
    }

    private JarvisSettings Build()
    {
        var s = _store.Current;
        return s with
        {
            Pebble = s.Pebble with
            {
                Size = (int)SizeSlider.Value,
                Opacity = OpacitySlider.Value,
                FollowEasing = EasingSlider.Value,
                FollowCursor = FollowCursorCheck.IsChecked == true,
                AnimationsEnabled = AnimationsCheck.IsChecked == true
            },
            Overlay = s.Overlay with
            {
                ClickThrough = ClickThroughCheck.IsChecked == true,
                AlwaysOnTop = AlwaysOnTopCheck.IsChecked == true
            },
            Performance = s.Performance with
            {
                ReducedMotion = ReducedMotionCheck.IsChecked == true,
                RespectBatterySaver = RespectBatteryCheck.IsChecked == true,
                GpuAcceleration = GpuAccelCheck.IsChecked == true
            },
            Gateway = s.Gateway with
            {
                BaseUrl    = GatewayBaseUrlBox.Text?.Trim() ?? s.Gateway.BaseUrl,
                DeviceId   = string.IsNullOrWhiteSpace(s.Gateway.DeviceId) ? Environment.MachineName : s.Gateway.DeviceId,
                DeviceName = string.IsNullOrWhiteSpace(s.Gateway.DeviceName) ? s.Sidecar.DeviceName : s.Gateway.DeviceName
            },
            Sidecar = s.Sidecar with
            {
                Enabled = SidecarEnabledCheck.IsChecked == true,
                BridgeUrl = string.IsNullOrWhiteSpace(BridgeUrlBox.Text) ? s.Sidecar.BridgeUrl : BridgeUrlBox.Text.Trim(),
                BridgeToken = string.IsNullOrEmpty(BridgeTokenBox.Password) ? null : BridgeTokenBox.Password,
                AutoReconnect = AutoReconnectCheck.IsChecked == true,
                OfflineDegradedModeEnabled = OfflineDegradedCheck.IsChecked == true,
                WakeWordEnabled = WakeWordEnabledCheck.IsChecked == true,
                LocalWakeAlias = LocalWakeAliasBox.Text?.Trim() ?? s.Sidecar.LocalWakeAlias,
                DeviceName = DeviceNameBox.Text?.Trim() ?? s.Sidecar.DeviceName,
                LocalTtsEnabled = LocalTtsEnabledCheck.IsChecked == true,
                PrivacyMode = PrivacyModeCheck.IsChecked == true
            },
            MouseChord = s.MouseChord with
            {
                EnableMouseChordMenu = MouseChordEnabledCheck.IsChecked == true
            }
        };
    }

    private async void OnSaveClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            await _store.SaveAsync(Build());
            PerfHudRequested = PerfHudCheck.IsChecked == true;
            DialogResult = true;
            Close();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"Couldn't save settings:\n{ex.Message}", "Jarvis", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void OnCancelClicked(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private void OnResetClicked(object sender, RoutedEventArgs e) => LoadFromSettings(JarvisSettings.Defaults);

    private void RefreshE2EButtons()
    {
        var connected = _bridge?.Status.State == BridgeState.Connected;
        SendTestTranscriptButton.IsEnabled = connected;
        RequestMacTestButton.IsEnabled = connected;
    }

    private void RefreshPairingStatus(BrainGatewayConfig gw)
    {
        if (gw.Paired && !string.IsNullOrWhiteSpace(gw.SessionToken))
        {
            var lastConn = gw.LastConnectedAt.HasValue
                ? $"  Last connected: {gw.LastConnectedAt.Value.ToLocalTime():g}"
                : string.Empty;
            PairingStatusText.Text = $"Paired  (device: {gw.DeviceId}){lastConn}";
            PairingStatusText.Foreground = System.Windows.Media.Brushes.LightGreen;
        }
        else if (!string.IsNullOrWhiteSpace(gw.BaseUrl))
        {
            PairingStatusText.Text = "Not paired — enter the 6-digit code from Mac Brain and click Pair.";
            PairingStatusText.Foreground = System.Windows.Media.Brushes.Orange;
        }
        else
        {
            PairingStatusText.Text = "Not configured — enter the Gateway URL above first.";
            PairingStatusText.Foreground = (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["TextSubtle"]
                ?? System.Windows.Media.Brushes.Gray;
        }
    }

    private async void OnPairClicked(object sender, RoutedEventArgs e)
    {
        var baseUrl = GatewayBaseUrlBox.Text?.Trim() ?? string.Empty;
        var code    = PairingCodeBox.Text?.Trim() ?? string.Empty;
        if (string.IsNullOrWhiteSpace(baseUrl))
        {
            TestBridgeOutput.Text = "Enter the Mac Brain Gateway URL first.";
            return;
        }
        if (string.IsNullOrWhiteSpace(code))
        {
            TestBridgeOutput.Text = "Enter the pairing code shown on Mac Brain.";
            return;
        }

        PairButton.IsEnabled    = false;
        TestBridgeOutput.Text   = "Pairing…";
        var s = _store.Current;
        var deviceId   = string.IsNullOrWhiteSpace(s.Gateway.DeviceId) ? Environment.MachineName : s.Gateway.DeviceId;
        var deviceName = string.IsNullOrWhiteSpace(s.Gateway.DeviceName) ? s.Sidecar.DeviceName : s.Gateway.DeviceName;

        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            var result = await GatewayPairingClient.PairAsync(
                baseUrl, deviceId, deviceName, code,
                appVersion: "1.0.0",
                capabilities: WindowsCapabilities.Enabled,
                cancellationToken: cts.Token).ConfigureAwait(true);

            if (!result.Success)
            {
                TestBridgeOutput.Text = $"Pairing failed: {result.Error}";
                return;
            }

            // Save the session token (DPAPI encryption handled by the store on save).
            var updated = _store.Current with
            {
                Gateway = _store.Current.Gateway with
                {
                    BaseUrl      = baseUrl,
                    DeviceId     = result.DeviceId ?? deviceId,
                    DeviceName   = deviceName,
                    SessionToken = result.SessionToken,
                    Paired       = true,
                    LastConnectedAt = DateTimeOffset.UtcNow
                }
            };
            await _store.SaveAsync(updated).ConfigureAwait(true);
            GatewayBaseUrlBox.Text = baseUrl;
            PairingCodeBox.Text    = string.Empty;
            RefreshPairingStatus(updated.Gateway);
            TestBridgeOutput.Text = "Paired successfully. The bridge will reconnect shortly.";
        }
        catch (Exception ex)
        {
            TestBridgeOutput.Text = $"Pairing error: {ex.Message}";
        }
        finally
        {
            PairButton.IsEnabled = true;
        }
    }

    /// <summary>Run the staged connectivity probe against the gateway URL currently in the box.</summary>
    private async void OnTestBridgeClicked(object sender, RoutedEventArgs e)
    {
        TestBridgeButton.IsEnabled = false;
        TestBridgeOutput.Text = "Probing…";
        try
        {
            // Prefer gateway URL; fall back to legacy WS URL for the probe.
            var gatewayBase = GatewayBaseUrlBox.Text?.Trim() ?? string.Empty;
            var token = _store.Current.Gateway.SessionToken ?? BridgeTokenBox.Password;
            string probeUrl;
            if (!string.IsNullOrWhiteSpace(gatewayBase))
            {
                // Probe wants a WS URL; derive it.
                var derived = new BrainGatewayConfig { BaseUrl = gatewayBase }.DeriveWebSocketUrl();
                probeUrl = derived ?? gatewayBase;
            }
            else
            {
                probeUrl = BridgeUrlBox.Text?.Trim() ?? string.Empty;
                token    = BridgeTokenBox.Password;
            }
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var result = await BridgeConnectivityProbe.RunAsync(probeUrl, token, cts.Token).ConfigureAwait(true);
            TestBridgeOutput.Text = result.FormatText();
        }
        catch (Exception ex)
        {
            TestBridgeOutput.Text = $"Probe error: {ex.Message}";
        }
        finally
        {
            TestBridgeButton.IsEnabled = true;
            RefreshE2EButtons();
        }
    }

    /// <summary>Send a synthetic final transcript over the live bridge so the Mac can confirm
    /// the transcript path works end-to-end. Requires a Connected bridge.</summary>
    private async void OnSendTestTranscriptClicked(object sender, RoutedEventArgs e)
    {
        if (_bridge is null || _bridge.Status.State != BridgeState.Connected)
        {
            TestBridgeOutput.Text = "Bridge not connected — save settings and wait for connection.";
            return;
        }
        SendTestTranscriptButton.IsEnabled = false;
        try
        {
            var ok = await _bridge.SendAsync(new SidecarFrame
            {
                Type = SidecarFrameTypes.TranscriptFinal,
                Text = "Jarvis Windows E2E test transcript",
                Confidence = 1.0,
                IsFinal = true,
                At = DateTimeOffset.UtcNow,
                DeviceId = Environment.MachineName
            }).ConfigureAwait(true);
            TestBridgeOutput.Text = ok
                ? "Test transcript sent — check Mac brain logs for receipt."
                : "Send failed — bridge may have disconnected.";
        }
        catch (Exception ex)
        {
            TestBridgeOutput.Text = $"Send error: {ex.Message}";
        }
        finally
        {
            SendTestTranscriptButton.IsEnabled = _bridge?.Status.State == BridgeState.Connected;
        }
    }

    /// <summary>Send a wake-style phrase that should trigger a full Mac round-trip (transcribe →
    /// intent → reply). Requires a Connected bridge with wake word processing on Mac.</summary>
    private async void OnRequestMacTestClicked(object sender, RoutedEventArgs e)
    {
        if (_bridge is null || _bridge.Status.State != BridgeState.Connected)
        {
            TestBridgeOutput.Text = "Bridge not connected — save settings and wait for connection.";
            return;
        }
        RequestMacTestButton.IsEnabled = false;
        try
        {
            var ok = await _bridge.SendAsync(new SidecarFrame
            {
                Type = SidecarFrameTypes.TranscriptFinal,
                Text = "Hello Jarvis, this is a Windows connectivity test",
                Confidence = 1.0,
                IsFinal = true,
                At = DateTimeOffset.UtcNow,
                DeviceId = Environment.MachineName
            }).ConfigureAwait(true);
            TestBridgeOutput.Text = ok
                ? "Test phrase sent — Mac should respond via OrchestrateSpeak frame."
                : "Send failed — bridge may have disconnected.";
        }
        catch (Exception ex)
        {
            TestBridgeOutput.Text = $"Send error: {ex.Message}";
        }
        finally
        {
            RequestMacTestButton.IsEnabled = _bridge?.Status.State == BridgeState.Connected;
        }
    }
}
