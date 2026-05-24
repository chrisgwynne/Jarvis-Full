using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Forms;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Diagnostics;

namespace Jarvis.App.Tray;

/// <summary>
/// Owns the NotifyIcon, the context menu, and the user-facing lifecycle (Show/Hide/Quit).
/// Keeps the WPF Application running independently of any open windows.
/// </summary>
public sealed class TrayController : IDisposable
{
    private readonly NotifyIcon _notify;
    private readonly Window _overlay;
    private readonly IJarvisSettingsStore _settings;
    private readonly IDiagnostics _diagnostics;
    private readonly Action<bool> _setPerfHud;
    private readonly Func<bool> _getPerfHud;
    private readonly Action _openSettings;
    private readonly Action _captureRegion;
    private readonly Action _openInspector;
    private readonly Action _ocrClipboardImage;
    private readonly Action _openAuditLog;
    private readonly Action _copyBridgeToken;
    private readonly Action _openGuidance;
    private readonly Action _openChat;
    private readonly Action _openLlmSettings;
    private readonly Action _openRedactionPreview;
    private readonly Action _exportConversation;
    private readonly Icon _icon;
    private nint _iconHandle;
    private bool _visible = true;

    public TrayController(
        Window overlay,
        IJarvisSettingsStore settings,
        IDiagnostics diagnostics,
        Action openSettings,
        Action<bool> setPerfHud,
        Func<bool> getPerfHud,
        Action captureRegion,
        Action openInspector,
        Action ocrClipboardImage,
        Action openAuditLog,
        Action copyBridgeToken,
        Action openGuidance,
        Action openChat,
        Action openLlmSettings,
        Action openRedactionPreview,
        Action exportConversation)
    {
        _overlay = overlay;
        _settings = settings;
        _diagnostics = diagnostics;
        _openSettings = openSettings;
        _setPerfHud = setPerfHud;
        _getPerfHud = getPerfHud;
        _captureRegion = captureRegion;
        _openInspector = openInspector;
        _ocrClipboardImage = ocrClipboardImage;
        _openAuditLog = openAuditLog;
        _copyBridgeToken = copyBridgeToken;
        _openGuidance = openGuidance;
        _openChat = openChat;
        _openLlmSettings = openLlmSettings;
        _openRedactionPreview = openRedactionPreview;
        _exportConversation = exportConversation;

        _icon = BuildPebbleIcon(out _iconHandle);
        _notify = new NotifyIcon
        {
            Icon = _icon,
            Text = "Jarvis — middle-click cursor for menu",
            Visible = true,
            ContextMenuStrip = BuildMenu()
        };
        _notify.DoubleClick += (_, _) => ToggleVisible();

        // One-shot tip so the user knows Jarvis is alive even when Windows 11 hides the
        // icon in the overflow tray. Fired once per process — not per launch — because we
        // can't easily track first-run state, but the balloon is short.
        try { _notify.ShowBalloonTip(4000, "Jarvis", "Click the ^ in the taskbar to find me. Ctrl+Shift+Q quits.", ToolTipIcon.Info); }
        catch { /* balloons can fail silently on locked-down systems */ }
    }

    /// <summary>Build a distinctive 32×32 pebble glyph so the icon is recognisable in the
    /// Windows 11 overflow tray, instead of looking like every other generic app icon.</summary>
    private static Icon BuildPebbleIcon(out nint handle)
    {
        using var bmp = new Bitmap(32, 32, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            // Outer halo
            using (var halo = new SolidBrush(Color.FromArgb(60, 120, 180, 255)))
                g.FillEllipse(halo, 1, 1, 30, 30);
            // Core sphere — matches the in-app pebble's blue
            using var core = new LinearGradientBrush(
                new Rectangle(6, 6, 20, 20),
                Color.FromArgb(255, 207, 232, 255),
                Color.FromArgb(255, 60, 130, 220),
                90f);
            g.FillEllipse(core, 6, 6, 20, 20);
            // Highlight
            using var hi = new SolidBrush(Color.FromArgb(180, 255, 255, 255));
            g.FillEllipse(hi, 11, 9, 6, 4);
        }
        handle = bmp.GetHicon();
        return Icon.FromHandle(handle);
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        var show = new ToolStripMenuItem("Hide pebble", null, (_, _) => ToggleVisible()) { Name = "show" };
        menu.Items.Add(show);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Chat…", null, (_, _) => _openChat()));
        menu.Items.Add(new ToolStripMenuItem("LLM settings…", null, (_, _) => _openLlmSettings()));
        menu.Items.Add(new ToolStripMenuItem("Redaction preview…", null, (_, _) => _openRedactionPreview()));
        menu.Items.Add(new ToolStripMenuItem("Export conversation…", null, (_, _) => _exportConversation()));
        menu.Items.Add(new ToolStripMenuItem("Where do I click?…", null, (_, _) => _openGuidance()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Capture region…", null, (_, _) => _captureRegion()));
        menu.Items.Add(new ToolStripMenuItem("OCR clipboard image", null, (_, _) => _ocrClipboardImage()));
        menu.Items.Add(new ToolStripMenuItem("Inspect context…", null, (_, _) => _openInspector()));
        menu.Items.Add(new ToolStripMenuItem("Audit log…", null, (_, _) => _openAuditLog()));
        menu.Items.Add(new ToolStripMenuItem("Copy bridge token", null, (_, _) => _copyBridgeToken()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Settings…", null, (_, _) => _openSettings()));
        var hud = new ToolStripMenuItem("Performance HUD", null, (_, _) =>
        {
            _setPerfHud(!_getPerfHud());
            RefreshChecks(menu);
        }) { Name = "hud" };
        menu.Items.Add(hud);
        menu.Items.Add(new ToolStripMenuItem("Export diagnostics…", null, OnExportDiagnostics));
        menu.Items.Add(new ToolStripMenuItem("Open log folder", null, (_, _) => OpenLogFolder()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quit Jarvis", null, (_, _) => QuitRequested?.Invoke(this, EventArgs.Empty)));
        menu.Opening += (_, _) => RefreshChecks(menu);
        return menu;
    }

    private void RefreshChecks(ContextMenuStrip menu)
    {
        if (menu.Items["show"] is ToolStripMenuItem show)
            show.Text = _visible ? "Hide pebble" : "Show pebble";
        if (menu.Items["hud"] is ToolStripMenuItem hud)
            hud.Checked = _getPerfHud();
    }

    public event EventHandler? QuitRequested;

    private void ToggleVisible()
    {
        _visible = !_visible;
        if (_visible) _overlay.Show(); else _overlay.Hide();
    }

    private async void OnExportDiagnostics(object? sender, EventArgs e)
    {
        using var dlg = new SaveFileDialog
        {
            Title = "Export Jarvis diagnostics",
            Filter = "JSON (*.json)|*.json",
            FileName = $"jarvis-diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}.json",
            InitialDirectory = DiagnosticsFileSink.DefaultDirectory()
        };
        if (dlg.ShowDialog() != DialogResult.OK) return;
        try
        {
            await DiagnosticsExporter.ExportJsonAsync(_diagnostics, dlg.FileName);
            _notify.ShowBalloonTip(2000, "Jarvis", $"Diagnostics exported to {Path.GetFileName(dlg.FileName)}", ToolTipIcon.Info);
        }
        catch (Exception ex)
        {
            _diagnostics.Record(DiagnosticLevel.Warn, "diagnostics", "export failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }
    }

    private void OpenLogFolder()
    {
        var dir = DiagnosticsFileSink.DefaultDirectory();
        Directory.CreateDirectory(dir);
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $"\"{dir}\"",
                UseShellExecute = true
            });
        }
        catch (Exception ex)
        {
            _diagnostics.Record(DiagnosticLevel.Warn, "tray", "open log folder failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }
    }

    public void Dispose()
    {
        _notify.Visible = false;
        _notify.Dispose();
        try { _icon.Dispose(); } catch { }
        if (_iconHandle != 0) { DestroyIcon(_iconHandle); _iconHandle = 0; }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(nint handle);
}
