using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Perception;
using Microsoft.Extensions.Logging;

namespace Jarvis.Perception.Clipboard;

/// <summary>
/// Listens to Win32 WM_CLIPBOARDUPDATE via an invisible HwndSource. Classifies content,
/// hashes it for dedup, evicts old entries, and never persists payloads to disk.
///
/// Safety:
///   - bounded history (default 32 entries)
///   - per-entry size cap (default 64 KiB text, image dims only — no pixels retained)
///   - hash dedup so spamming Ctrl-C doesn't generate noise
///   - 5-minute TTL on stored entries
/// </summary>
public sealed class ClipboardMonitor : IClipboardMonitor
{
    private const int WM_CLIPBOARDUPDATE = 0x031D;
    private const int HWND_MESSAGE_INT = -3;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

    private readonly ISemanticContentClassifier _classifier;
    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<ClipboardMonitor>? _logger;
    private readonly TimeSpan _ttl;
    private readonly int _maxHistory;
    private readonly int _maxTextChars;
    private readonly Queue<ClipboardEntry> _history = new();
    private readonly object _gate = new();

    private HwndSource? _source;
    private bool _listening;
    private string? _lastHash;
    private BitmapSource? _lastImage;

    public ClipboardMonitor(
        ISemanticContentClassifier classifier,
        IDiagnostics? diagnostics = null,
        ILogger<ClipboardMonitor>? logger = null,
        TimeSpan? entryTtl = null,
        int maxHistory = 32,
        int maxTextChars = 64 * 1024)
    {
        _classifier = classifier;
        _diagnostics = diagnostics;
        _logger = logger;
        _ttl = entryTtl ?? TimeSpan.FromMinutes(5);
        _maxHistory = maxHistory;
        _maxTextChars = maxTextChars;
    }

    public ClipboardEntry? Latest { get { lock (_gate) return _history.Count > 0 ? _history.Last() : null; } }

    public IReadOnlyList<ClipboardEntry> History
    {
        get { lock (_gate) { Evict(); return _history.Reverse().ToArray(); } }
    }

    public event EventHandler<ClipboardEntry>? Changed;

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_listening) return Task.CompletedTask;
        var app = Application.Current ?? throw new InvalidOperationException("ClipboardMonitor requires a WPF Application.");
        app.Dispatcher.Invoke(() =>
        {
            var parameters = new HwndSourceParameters("Jarvis.ClipboardSink")
            {
                WindowStyle = 0,
                ExtendedWindowStyle = 0,
                ParentWindow = new IntPtr(HWND_MESSAGE_INT) // message-only window
            };
            _source = new HwndSource(parameters);
            _source.AddHook(WndProc);
            if (!AddClipboardFormatListener(_source.Handle))
            {
                _diagnostics?.Record(DiagnosticLevel.Warn, "clipboard", "AddClipboardFormatListener failed",
                    new Dictionary<string, object?> { ["err"] = Marshal.GetLastWin32Error() });
            }
            _listening = true;
        });
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (!_listening) return Task.CompletedTask;
        Application.Current?.Dispatcher.Invoke(() =>
        {
            if (_source is not null)
            {
                RemoveClipboardFormatListener(_source.Handle);
                _source.RemoveHook(WndProc);
                _source.Dispose();
                _source = null;
            }
            _listening = false;
        });
        return Task.CompletedTask;
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_CLIPBOARDUPDATE)
        {
            TryCaptureCurrent();
            handled = true;
        }
        return IntPtr.Zero;
    }

    private void TryCaptureCurrent()
    {
        // System.Windows.Clipboard touches the clipboard, which can briefly be locked by
        // the source app. Retry a couple of times with a short backoff.
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                ProcessClipboard();
                return;
            }
            catch (COMException) when (attempt < 2)
            {
                Thread.Sleep(20);
            }
            catch (Exception ex)
            {
                _logger?.LogWarning(ex, "Clipboard read failed");
                _diagnostics?.Record(DiagnosticLevel.Warn, "clipboard", "read failed",
                    new Dictionary<string, object?> { ["error"] = ex.Message });
                return;
            }
        }
    }

    private void ProcessClipboard()
    {
        ClipboardEntry? entry = null;
        if (System.Windows.Clipboard.ContainsText())
        {
            var text = System.Windows.Clipboard.GetText();
            if (string.IsNullOrEmpty(text)) return;
            if (text.Length > _maxTextChars) text = text[.._maxTextChars];
            var hash = HashText(text);
            if (hash == _lastHash) return;
            _lastHash = hash;
            entry = new ClipboardEntry(
                CapturedAt: DateTimeOffset.UtcNow,
                ContentType: _classifier.Classify(text),
                Text: text,
                ImageWidth: null,
                ImageHeight: null,
                SourceApp: GuessSourceApp(),
                ContentHash: hash);
        }
        else if (System.Windows.Clipboard.ContainsImage())
        {
            var bs = System.Windows.Clipboard.GetImage();
            if (bs is null) return;
            var hash = "img:" + bs.PixelWidth + "x" + bs.PixelHeight + ":" + ImagePerceptualHash.Compute(bs);
            _lastImage = bs;
            if (hash == _lastHash) return;
            _lastHash = hash;
            entry = new ClipboardEntry(
                CapturedAt: DateTimeOffset.UtcNow,
                ContentType: SemanticContentType.Image,
                Text: null,
                ImageWidth: bs.PixelWidth,
                ImageHeight: bs.PixelHeight,
                SourceApp: GuessSourceApp(),
                ContentHash: hash);
        }

        if (entry is null) return;

        lock (_gate)
        {
            _history.Enqueue(entry);
            while (_history.Count > _maxHistory) _history.Dequeue();
            Evict();
        }
        _diagnostics?.Record(DiagnosticLevel.Debug, "clipboard", "entry",
            new Dictionary<string, object?>
            {
                ["type"] = entry.ContentType.ToString(),
                ["chars"] = entry.Text?.Length ?? 0,
                ["sourceApp"] = entry.SourceApp
            });
        Changed?.Invoke(this, entry);
    }

    private void Evict()
    {
        var cutoff = DateTimeOffset.UtcNow - _ttl;
        while (_history.Count > 0 && _history.Peek().CapturedAt < cutoff) _history.Dequeue();
    }

    private static string HashText(string text)
    {
        var bytes = SHA1.HashData(Encoding.UTF8.GetBytes(text));
        return Convert.ToHexString(bytes);
    }

    /// <summary>
    /// Returns the most recent clipboard image encoded as PNG bytes (or null when the
    /// last entry wasn't an image). On-demand only — never called in the hot path.
    /// </summary>
    public byte[]? TryGetLatestImageAsPng()
    {
        BitmapSource? snap;
        lock (_gate) snap = _lastImage;
        if (snap is null) return null;
        try
        {
            using var ms = new MemoryStream();
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(snap));
            encoder.Save(ms);
            return ms.ToArray();
        }
        catch
        {
            return null;
        }
    }

    private static string? GuessSourceApp()
    {
        try
        {
            var hwnd = Interop.User32.GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return null;
            _ = Interop.User32.GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == 0) return null;
            using var proc = Process.GetProcessById((int)pid);
            return proc.ProcessName;
        }
        catch
        {
            return null;
        }
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    internal static class Interop
    {
        internal static class User32
        {
            [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
            [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        }
    }
}
