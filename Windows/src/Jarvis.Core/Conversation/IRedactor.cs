namespace Jarvis.Core.Conversation;

public sealed record RedactionReport(int Replacements, IReadOnlyDictionary<string, int> Categories);

public interface IRedactor
{
    /// <summary>Redact secrets/PII per the active settings. Returns the cleaned text and
    /// a counter of category→hits for diagnostics.</summary>
    (string Cleaned, RedactionReport Report) Redact(string? input);
}
