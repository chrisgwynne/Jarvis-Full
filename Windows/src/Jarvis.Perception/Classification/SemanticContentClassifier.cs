using System.Text.RegularExpressions;
using Jarvis.Core.Perception;

namespace Jarvis.Perception.Classification;

/// <summary>
/// Heuristic content-type classifier. Cheap (compiled regex, single pass) and deterministic.
/// Order matters: the most specific signature wins.
/// </summary>
public sealed partial class SemanticContentClassifier : ISemanticContentClassifier
{
    // Compiled regex via source-gen for zero allocations on the hot path.
    [GeneratedRegex(@"^\s*https?://[^\s]+\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex UrlOnly();

    [GeneratedRegex(@"^[^@\s]+@[^@\s]+\.[^@\s]+$")]
    private static partial Regex EmailOnly();

    [GeneratedRegex(@"^\s*[\{\[][\s\S]*[\}\]]\s*$")]
    private static partial Regex JsonShape();

    [GeneratedRegex(@"\b(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|WITH)\b[\s\S]*\b(FROM|INTO|TABLE|VIEW|WHERE|VALUES|SET)\b", RegexOptions.IgnoreCase)]
    private static partial Regex SqlShape();

    [GeneratedRegex(@"(Traceback|Exception|at\s+\w[\w\.]+\(.*\)|\bin\s+[A-Z]:\\.*:line\s+\d+|File\s+"".*"",\s*line\s+\d+)")]
    private static partial Regex StackTraceShape();

    [GeneratedRegex(@"(^|\n)[A-Z]:\\[^\n]*>|^\$\s|^>\s|^PS\s[A-Z]:\\")]
    private static partial Regex TerminalShape();

    [GeneratedRegex(@"^(#{1,6}\s|\*\s|\-\s|\d+\.\s|```|>\s)", RegexOptions.Multiline)]
    private static partial Regex MarkdownShape();

    [GeneratedRegex(@"(\b(public|private|internal|protected|static|class|interface|namespace|using|func|def|import|export|const|let|var|return|if|else|for|while)\b[\s\S]*[\{\(;])|(=>\s*[\{\(])")]
    private static partial Regex CodeShape();

    [GeneratedRegex(@"^(?:[^\t\n]+\t[^\t\n]+\n){2,}", RegexOptions.Multiline)]
    private static partial Regex TableTabs();

    [GeneratedRegex(@"^(?:[^\|\n]+\|[^\|\n]+\n){2,}", RegexOptions.Multiline)]
    private static partial Regex TablePipes();

    public SemanticContentType Classify(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return SemanticContentType.Unknown;
        var t = text.Trim();
        if (t.Length > 64_000) t = t[..64_000]; // safety cap

        if (UrlOnly().IsMatch(t)) return SemanticContentType.Url;
        if (t.Length <= 320 && EmailOnly().IsMatch(t)) return SemanticContentType.Email;
        if (StackTraceShape().IsMatch(t)) return SemanticContentType.StackTrace;
        if (TerminalShape().IsMatch(t)) return SemanticContentType.TerminalOutput;
        if (JsonShape().IsMatch(t) && LooksLikeJson(t)) return SemanticContentType.Json;
        if (SqlShape().IsMatch(t)) return SemanticContentType.Sql;
        if (MarkdownShape().IsMatch(t)) return SemanticContentType.Markdown;
        if (TableTabs().IsMatch(t) || TablePipes().IsMatch(t)) return SemanticContentType.Table;
        if (CodeShape().IsMatch(t)) return SemanticContentType.Code;
        return SemanticContentType.Prose;
    }

    private static bool LooksLikeJson(string t)
    {
        var braces = 0; var brackets = 0; var quotes = 0;
        foreach (var c in t)
        {
            if (c == '{') braces++;
            else if (c == '}') braces--;
            else if (c == '[') brackets++;
            else if (c == ']') brackets--;
            else if (c == '"') quotes++;
        }
        return braces == 0 && brackets == 0 && quotes % 2 == 0;
    }
}
