using Jarvis.Core.Settings;

namespace Jarvis.Core.Conversation;

public sealed record ProviderStatus(
    LlmProviderType Type,
    string Model,
    bool Configured,
    string? Detail);

public sealed record ProviderConnectionResult(bool Ok, string Message);

/// <summary>
/// Selects the active <see cref="ILlmClient"/> based on settings. Validates that the
/// settings look sensible before handing back a real client; falls back to the echo
/// stub when nothing is configured.
/// </summary>
public interface ILlmProviderManager : ILlmClient
{
    ProviderStatus Status { get; }
    Task<ProviderConnectionResult> TestAsync(CancellationToken cancellationToken = default);
}
