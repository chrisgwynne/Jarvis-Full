using System.Runtime.CompilerServices;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using static Jarvis.Core.Sidecar.LocalLlmFallbackPolicy;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Routes <see cref="ILlmClient.StreamAsync"/> calls to:
///   - the Mac bridge when the bridge is connected (preferred)
///   - the local provider stack (OpenAI / MiniMax / Ollama / Echo) when the bridge
///     is down AND OfflineDegradedModeEnabled is true
///   - a "no brain available" placeholder otherwise
///
/// This is the load-bearing piece that makes Windows a sidecar: the chat panel calls
/// <c>ILlmClient</c>, the request goes to the Mac when possible, and to the local
/// fallback only when degraded mode is enabled.
/// </summary>
public sealed class DegradedModeRouter : ILlmClient
{
    private readonly IMacBridgeCoordinator _bridge;
    private readonly SidecarLlmClient _sidecar;
    private readonly ILlmClient _localFallback;
    private readonly Func<SidecarSettings> _settings;

    public DegradedModeRouter(
        IMacBridgeCoordinator bridge,
        SidecarLlmClient sidecar,
        ILlmClient localFallback,
        Func<SidecarSettings> settings)
    {
        _bridge = bridge;
        _sidecar = sidecar;
        _localFallback = localFallback;
        _settings = settings;
    }

    public bool IsConfigured => _sidecar.IsConfigured || _localFallback.IsConfigured;

    public IAsyncEnumerable<string> StreamAsync(LlmRequest request, CancellationToken cancellationToken = default)
    {
        var settings = _settings();
        if (_sidecar.IsConfigured)
            return _sidecar.StreamAsync(request, cancellationToken);
        // LocalLlmFallbackPolicy enforces the sidecar contract: local LLM only when bridge
        // is genuinely down AND the user opted in. Never when Mac is reachable.
        if (CanUseLocalLlm(_bridge.Status.State, settings.OfflineDegradedModeEnabled))
            return _localFallback.StreamAsync(request, cancellationToken);
        return Empty();
    }

    private static async IAsyncEnumerable<string> Empty(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await Task.CompletedTask;
        yield return "_(Mac bridge is down and offline degraded mode is disabled.)_";
    }
}
