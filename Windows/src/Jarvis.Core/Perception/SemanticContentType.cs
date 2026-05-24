namespace Jarvis.Core.Perception;

/// <summary>
/// Coarse-grained content classification for clipboard payloads and OCR results.
/// Detection is best-effort and heuristic (regex + signature checks) — never use
/// these to gate security decisions.
/// </summary>
public enum SemanticContentType
{
    Unknown,
    Prose,
    Code,
    Url,
    Email,
    Json,
    Sql,
    Markdown,
    StackTrace,
    TerminalOutput,
    Table,
    Image
}
