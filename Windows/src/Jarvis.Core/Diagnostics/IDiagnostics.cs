namespace Jarvis.Core.Diagnostics;

public enum DiagnosticLevel { Trace, Debug, Info, Warn, Error }

public readonly record struct DiagnosticEntry(
    DateTimeOffset At,
    DiagnosticLevel Level,
    string Category,
    string Message,
    IReadOnlyDictionary<string, object?>? Properties);

public interface IDiagnostics
{
    void Record(DiagnosticLevel level, string category, string message, IReadOnlyDictionary<string, object?>? properties = null);
    IReadOnlyList<DiagnosticEntry> Recent(int max = 200);
    void RecordMetric(string name, double value);
    IReadOnlyDictionary<string, double> Metrics { get; }
}
