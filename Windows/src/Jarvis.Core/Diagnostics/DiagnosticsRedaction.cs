using System.Security.Cryptography;
using System.Text;

namespace Jarvis.Core.Diagnostics;

/// <summary>
/// Helpers for emitting privacy-safe diagnostics about user-originated text. Diagnostics
/// are persisted and may be exported, so raw transcripts, wake phrases, spoken text, etc.
/// must never be written verbatim. Instead we record the character length plus a short,
/// non-reversible hash — enough to correlate identical strings across events and to spot
/// "empty vs non-empty" without leaking content.
/// </summary>
public static class DiagnosticsRedaction
{
    /// <summary>Length of the string (0 for null/empty), safe to log.</summary>
    public static int Length(string? value) => value?.Length ?? 0;

    /// <summary>A short hex hash of the string for correlation. Returns "" for null/empty.
    /// Truncated to 8 hex chars — collision-tolerant for diagnostics, not reversible.</summary>
    public static string Hash(string? value)
    {
        if (string.IsNullOrEmpty(value)) return string.Empty;
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes, 0, 4).ToLowerInvariant();
    }
}
