using Jarvis.Core.Settings;
using Jarvis.Core.Tools;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Returns a privacy-safe summary of the current clipboard text content.
/// Reads clipboard on the WPF dispatcher thread. Never stores clipboard content beyond the call.
/// </summary>
public sealed class ClipboardSummaryTool : IWindowsTool
{
    private readonly Func<ToolsSettings> _settings;

    public ClipboardSummaryTool(Func<ToolsSettings> settings)
    {
        _settings = settings;
    }

    public string Name => "clipboard_summary";
    public IReadOnlyList<string> Aliases { get; } = ["clipboard", "what_is_in_clipboard"];
    public string Description => "Returns a brief, privacy-safe summary of the current clipboard text.";
    public ToolSafetyLevel SafetyLevel => ToolSafetyLevel.Safe;

    public async Task<WindowsToolResult> ExecuteAsync(WindowsToolRequest request, CancellationToken ct = default)
    {
        if (!_settings().AllowClipboardRead)
        {
            return Blocked("Clipboard reading is disabled in settings. Enable Settings.Tools.AllowClipboardRead to use this.");
        }

        if (request.DryRun)
        {
            return Ok("Would read and summarise clipboard content (dry run)", null);
        }

        string? text = null;
        try
        {
            await System.Windows.Application.Current.Dispatcher.InvokeAsync(() =>
            {
                try { text = System.Windows.Clipboard.GetText(); }
                catch { /* clipboard can fail if locked by another app */ }
            });
        }
        catch (Exception ex)
        {
            return Fail($"Could not read clipboard: {ex.Message}");
        }

        if (string.IsNullOrEmpty(text))
        {
            return Ok("Clipboard is empty or contains non-text content.", null);
        }

        // Sanitise: strip control characters
        var sanitised = new string(text.Where(c => !char.IsControl(c) || c == '\n' || c == '\t').ToArray());
        var preview = sanitised.Length > 80
            ? sanitised[..80].Replace("\n", " ").Replace("\t", " ")
            : sanitised.Replace("\n", " ").Replace("\t", " ");

        var contentType = DetectContentType(sanitised);
        var summary = $"Clipboard has {text.Length} chars ({contentType}). Preview: \"{preview}{(sanitised.Length > 80 ? "…" : "")}\"";

        return Ok(summary, $"Length={text.Length}, Type={contentType}");
    }

    private static string DetectContentType(string text)
    {
        if (Uri.TryCreate(text.Trim(), UriKind.Absolute, out _)) return "URL";
        if (text.Contains('\n')) return "multi-line text";
        if (text.All(c => char.IsDigit(c) || c == '-' || c == '+' || c == '.' || c == ','))
            return "numeric";
        return "text";
    }

    private static WindowsToolResult Ok(string summary, string? detail) =>
        new(true, summary, detail, null, ToolPrivacyImpact.Clipboard, DateTimeOffset.UtcNow);

    private static WindowsToolResult Fail(string summary) =>
        new(false, summary, null, null, ToolPrivacyImpact.Clipboard, DateTimeOffset.UtcNow);

    private static WindowsToolResult Blocked(string summary) =>
        new(false, summary, "Blocked by settings policy.", null, ToolPrivacyImpact.Clipboard, DateTimeOffset.UtcNow);
}
