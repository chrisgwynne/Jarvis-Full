using System.Security.Cryptography;
using System.Text;
using Jarvis.Core.Perception;
using Jarvis.Core.Snapshot;

namespace Jarvis.Perception.Snapshot;

/// <summary>
/// Pure projection from observation inputs to a compact <see cref="SemanticSnapshot"/>.
/// Stateless and side-effect-free: callers can hash the output to cheaply detect "nothing
/// meaningful changed since last time" and skip downstream work (LLM prompts, UI refreshes).
///
/// Sizing rules:
///   - selected text trimmed to 4 KB
///   - clipboard summary trimmed to 256 chars
///   - OCR summary trimmed to 512 chars (first non-empty lines)
/// </summary>
public sealed class SemanticSnapshotBuilder : ISemanticSnapshotBuilder
{
    private const int MaxSelectedChars = 4_000;
    private const int MaxClipboardChars = 256;
    private const int MaxOcrChars = 512;

    private readonly ISemanticContentClassifier _classifier;
    private readonly IWorkflowCategorizer _categorizer;

    public SemanticSnapshotBuilder(ISemanticContentClassifier classifier, IWorkflowCategorizer categorizer)
    {
        _classifier = classifier;
        _categorizer = categorizer;
    }

    public SemanticSnapshot Build(SemanticSnapshotInputs inputs)
    {
        var selectedText = Truncate(inputs.Selection?.Text, MaxSelectedChars);
        var selectedType = inputs.Selection?.HasSelection == true ? _classifier.Classify(selectedText) : SemanticContentType.Unknown;

        var clipText = Truncate(inputs.Clipboard?.Text, MaxClipboardChars);
        var clipType = inputs.Clipboard?.ContentType ?? SemanticContentType.Unknown;

        var ocrSummary = SummarizeOcr(inputs.RecentOcr?.Text);

        var workflow = _categorizer.Categorize(inputs);

        var snap = new SemanticSnapshot(
            CapturedAt: DateTimeOffset.UtcNow,
            ForegroundApp: inputs.Desktop?.ForegroundProcessName,
            ForegroundWindowTitle: inputs.Desktop?.ForegroundWindowTitle,
            SelectedText: selectedText,
            SelectedTextType: selectedType,
            ClipboardSummary: clipText,
            ClipboardType: clipType,
            Browser: inputs.Browser,
            Ide: inputs.Ide,
            RecentOcrSummary: ocrSummary,
            Workflow: workflow,
            Hash: "pending");

        return snap with { Hash = ComputeHash(snap) };
    }

    private static string? Truncate(string? value, int max)
    {
        if (string.IsNullOrEmpty(value)) return null;
        return value.Length <= max ? value : value[..max];
    }

    private static string? SummarizeOcr(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var sb = new StringBuilder();
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = line.Trim();
            if (trimmed.Length == 0) continue;
            if (sb.Length > 0) sb.Append('\n');
            sb.Append(trimmed);
            if (sb.Length >= MaxOcrChars) break;
        }
        if (sb.Length == 0) return null;
        return sb.Length <= MaxOcrChars ? sb.ToString() : sb.ToString(0, MaxOcrChars);
    }

    private static string ComputeHash(SemanticSnapshot s)
    {
        var key = string.Join('|',
            s.ForegroundApp ?? "",
            s.ForegroundWindowTitle ?? "",
            s.SelectedText ?? "",
            s.SelectedTextType,
            s.ClipboardSummary ?? "",
            s.ClipboardType,
            s.Browser?.Url ?? "",
            s.Ide?.Editor ?? "",
            s.Ide?.ActiveFile ?? "",
            s.Ide?.RepoRoot ?? "",
            s.Ide?.Branch ?? "",
            s.RecentOcrSummary ?? "",
            s.Workflow);
        var bytes = SHA1.HashData(Encoding.UTF8.GetBytes(key));
        return Convert.ToHexString(bytes);
    }
}
