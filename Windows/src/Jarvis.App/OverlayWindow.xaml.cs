using System.IO;
using System.Windows;
using Jarvis.App.Interop;
using Jarvis.App.Overlay;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Core.State;
using Microsoft.Web.WebView2.Core;

namespace Jarvis.App;

public partial class OverlayWindow : Window
{
    private readonly IJarvisSettingsStore _settings;
    private readonly PebbleStateMachine _machine;
    private readonly IDiagnostics _diagnostics;
    private CursorFollower? _follower;
    private TopmostGuard? _topmostGuard;

    public PebbleBridge? Bridge { get; private set; }
    public CursorFollower? Follower => _follower;
    public event EventHandler? WebViewMissing;
    public event EventHandler<Exception>? WebViewFailed;

    public OverlayWindow(IJarvisSettingsStore settings, PebbleStateMachine machine, IDiagnostics diagnostics)
    {
        _settings = settings;
        _machine = machine;
        _diagnostics = diagnostics;
        InitializeComponent();
        ApplySettings(settings.Current);
        SourceInitialized += OnSourceInitialized;
        Loaded += OnLoaded;
        Closed += OnClosed;
        settings.Changed += (_, s) => Dispatcher.BeginInvoke(() => ApplySettings(s));
    }

    private void ApplySettings(JarvisSettings s)
    {
        // Window is the SVG canvas plus a small halo margin (1.5×). Lower padding =
        // pebble visually closer to the cursor at the same CursorOffset.
        Width = s.Pebble.Size * 1.5;
        Height = s.Pebble.Size * 1.5;
        Opacity = s.Pebble.Opacity;
        if (IsLoaded)
        {
            OverlayInterop.SetClickThrough(this, s.Overlay.ClickThrough);
            if (s.Overlay.AlwaysOnTop) OverlayInterop.ReassertTopmost(this);
        }
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        OverlayInterop.ApplyOverlayStyles(this, _settings.Current.Overlay.ClickThrough);
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (WebView2Runtime.DetectInstalledVersion() is null)
        {
            _diagnostics.Record(DiagnosticLevel.Error, "boot", "WebView2 runtime missing");
            WebViewMissing?.Invoke(this, EventArgs.Empty);
            return;
        }

        var userDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Jarvis", "WebView2");
        Directory.CreateDirectory(userDataFolder);

        try
        {
            var env = await CoreWebView2Environment.CreateAsync(
                browserExecutableFolder: null,
                userDataFolder: userDataFolder,
                options: new CoreWebView2EnvironmentOptions(
                    additionalBrowserArguments: "--disable-features=msSmartScreenProtection --autoplay-policy=no-user-gesture-required"));

            await Web.EnsureCoreWebView2Async(env);

            var core = Web.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            core.Settings.IsZoomControlEnabled = false;

            var webRoot = Path.Combine(AppContext.BaseDirectory, "web");
            core.SetVirtualHostNameToFolderMapping("pebble.local", webRoot, CoreWebView2HostResourceAccessKind.Allow);
            Web.Source = new Uri("https://pebble.local/pebble.html");

            Bridge = new PebbleBridge(Web, _machine, _diagnostics);
            Bridge.Attach();

            _follower = new CursorFollower(this, _settings, _diagnostics);
            _follower.Start();

            _topmostGuard = new TopmostGuard(this);
            _topmostGuard.Start();

            _diagnostics.Record(DiagnosticLevel.Info, "boot", "overlay ready");
        }
        catch (Exception ex)
        {
            _diagnostics.Record(DiagnosticLevel.Error, "boot", "WebView2 init failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            WebViewFailed?.Invoke(this, ex);
        }
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _follower?.Dispose();
        _topmostGuard?.Dispose();
        Bridge?.Dispose();
    }
}
