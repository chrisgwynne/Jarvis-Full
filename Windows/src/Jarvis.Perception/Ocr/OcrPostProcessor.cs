using System.Text.RegularExpressions;
using Jarvis.Core.Perception;

namespace Jarvis.Perception.Ocr;

/// <summary>
/// Cleans Windows.Media.Ocr output. Common artifacts:
///   - leading/trailing whitespace per line
///   - double spaces inside words ("re sult" -&gt; "result" is hard, but " result" -&gt; " result")
///   - smart quotes / ligature mangling
///   - blank-line bursts
///   - trailing pipe characters from table borders
/// </summary>
public sealed partial class OcrPostProcessor : IOcrPostProcessor
{
    [GeneratedRegex(@"[ \t]+\n")]          private static partial Regex TrailingSpaces();
    [GeneratedRegex(@"\n{3,}")]            private static partial Regex BlankLineBurst();
    [GeneratedRegex(@"[ \t]{2,}")]         private static partial Regex MultiSpace();
    [GeneratedRegex(@"[‘’`´]")]            private static partial Regex FancySingleQuote();
    [GeneratedRegex(@"[“”]")]              private static partial Regex FancyDoubleQuote();
    [GeneratedRegex(@"[—–]")]              private static partial Regex FancyDash();
    [GeneratedRegex(@"­|​")]     private static partial Regex SoftHyphenOrZwsp();
    [GeneratedRegex(@"^\s*\|\s*|\s*\|\s*$", RegexOptions.Multiline)] private static partial Regex EdgePipes();

    public string Clean(string rawText)
    {
        if (string.IsNullOrEmpty(rawText)) return string.Empty;
        var t = rawText.Replace("\r\n", "\n").Replace('\r', '\n');
        t = SoftHyphenOrZwsp().Replace(t, string.Empty);
        t = FancySingleQuote().Replace(t, "'");
        t = FancyDoubleQuote().Replace(t, "\"");
        t = FancyDash().Replace(t, "-");
        t = TrailingSpaces().Replace(t, "\n");
        t = MultiSpace().Replace(t, " ");
        t = EdgePipes().Replace(t, string.Empty);
        t = BlankLineBurst().Replace(t, "\n\n");
        return t.Trim();
    }
}
