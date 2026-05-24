using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Fans STT partial / final transcripts out to the Mac via the bridge. Applies the echo
/// suppression coordinator on the way through and records audio diagnostics. Partials
/// are sent freely (so the Mac can plan ahead); finals are deduplicated against the
/// echo suppressor's "recently sent" window.
///
/// Latency note: partials should hit the wire in the same tick they're emitted by STT —
/// we never queue or batch. The bridge's outbound queue handles backpressure.
/// </summary>
public sealed class PartialTranscriptCoordinator : IPartialTranscriptCoordinator, IDisposable
{
    private readonly IMacBridgeCoordinator _bridge;
    private readonly IEchoSuppressionCoordinator _echo;
    private readonly AudioDiagnostics _diag;
    private readonly IDiagnostics? _diagnostics;
    private readonly Func<SidecarSettings>? _settings;
    private readonly IDistributedConversationCoordinator? _conversation;
    private ISpeechRecognitionProvider? _provider;
    private string? _sessionId;
    private DateTimeOffset _utteranceStartedAt;
    private int _partialsThisUtterance;

    private int _partialsSent;
    private int _finalsSent;
    private int _suppressedPartials;
    private int _suppressedFinals;
    private int _interruptions;

    public int PartialsSent => _partialsSent;
    public int FinalsSent => _finalsSent;
    public int SuppressedPartials => _suppressedPartials;
    public int SuppressedFinals => _suppressedFinals;
    public int Interruptions => _interruptions;

    public PartialTranscriptCoordinator(
        IMacBridgeCoordinator bridge,
        IEchoSuppressionCoordinator echo,
        AudioDiagnostics diag,
        IDiagnostics? diagnostics = null,
        Func<SidecarSettings>? settings = null,
        IDistributedConversationCoordinator? conversation = null)
    {
        _bridge = bridge;
        _echo = echo;
        _diag = diag;
        _diagnostics = diagnostics;
        _settings = settings;
        _conversation = conversation;
    }

    private (string? alias, string? device, string? sessionId) GetAttribution()
    {
        var s = _settings?.Invoke();
        var alias = s is null ? null : (s.WakeAliasEnabled ? s.LocalWakeAlias : null);
        var device = _conversation?.DeviceId ?? s?.DeviceName;
        // Distributed session id wins over STT's per-utterance id — the conversation must
        // not fork per utterance; the STT id is sub-utterance scope only.
        return (alias, device, _conversation?.SessionId);
    }

    public void Attach(ISpeechRecognitionProvider provider)
    {
        Detach();
        _provider = provider;
        provider.Partial += OnPartial;
        provider.Final += OnFinal;
    }

    public void Detach()
    {
        if (_provider is null) return;
        _provider.Partial -= OnPartial;
        _provider.Final -= OnFinal;
        _provider = null;
    }

    private void OnPartial(object? sender, TranscriptEvent ev)
    {
        // Belt-and-suspenders: check PrivacyMode directly before delegating to the echo
        // suppressor so transcripts are blocked even if the suppressor's internal flag
        // hasn't been synced (e.g. settings loaded after construction).
        if (_settings?.Invoke().PrivacyMode == true)
        {
            Interlocked.Increment(ref _suppressedPartials);
            RecordSuppression(SuppressionReason.PrivacyMode);
            return;
        }
        var reason = _echo.ShouldSuppress(ev.Text);
        if (reason != SuppressionReason.None)
        {
            Interlocked.Increment(ref _suppressedPartials);
            RecordSuppression(reason);
            return;
        }
        if (_sessionId is null)
        {
            _sessionId = ev.SessionId;
            _utteranceStartedAt = ev.At;
            _partialsThisUtterance = 0;
        }
        _partialsThisUtterance++;
        if (_partialsThisUtterance == 1)
        {
            // First partial latency: how long from utterance start to first partial.
            // Provider-supplied At is the time the partial was produced — we can't see
            // the actual audio onset cheaply, so use At-At as 0 and instead record the
            // delta from session start.
            Interlocked.Add(ref _diag.FirstPartialLatencyTotalMs,
                (long)Math.Max(0, (ev.At - _utteranceStartedAt).TotalMilliseconds));
            Interlocked.Increment(ref _diag.FirstPartialLatencyCount);
        }
        Interlocked.Increment(ref _partialsSent);
        Interlocked.Increment(ref _diag.Partials);
        var (alias, device, sessionId) = GetAttribution();
        _ = _bridge.SendAsync(new SidecarFrame
        {
            Type = SidecarFrameTypes.TranscriptPartial,
            // Carry the distributed session id when available; fall back to STT's sub-id.
            SessionId = sessionId ?? ev.SessionId,
            Text = ev.Text,
            Confidence = ev.Confidence,
            IsFinal = false,
            At = ev.At,
            WakeAlias = alias,
            CaptureDeviceId = device
        });
    }

    private void OnFinal(object? sender, TranscriptEvent ev)
    {
        if (_settings?.Invoke().PrivacyMode == true)
        {
            Interlocked.Increment(ref _suppressedFinals);
            RecordSuppression(SuppressionReason.PrivacyMode);
            ResetSession();
            return;
        }
        var reason = _echo.ShouldSuppress(ev.Text);
        if (reason != SuppressionReason.None)
        {
            Interlocked.Increment(ref _suppressedFinals);
            RecordSuppression(reason);
            ResetSession();
            return;
        }
        Interlocked.Increment(ref _finalsSent);
        Interlocked.Increment(ref _diag.Finals);
        if (_sessionId is not null)
        {
            Interlocked.Add(ref _diag.FinalLatencyTotalMs,
                (long)Math.Max(0, (ev.At - _utteranceStartedAt).TotalMilliseconds));
            Interlocked.Increment(ref _diag.FinalLatencyCount);
        }
        var (finalAlias, finalDevice, finalSessionId) = GetAttribution();
        _ = _bridge.SendAsync(new SidecarFrame
        {
            Type = SidecarFrameTypes.TranscriptFinal,
            SessionId = finalSessionId ?? ev.SessionId,
            Text = ev.Text,
            Confidence = ev.Confidence,
            IsFinal = true,
            At = ev.At,
            WakeAlias = finalAlias,
            CaptureDeviceId = finalDevice
        });
        ResetSession();
    }

    /// <summary>External signal that an interruption happened (mid-TTS). Tags the next
    /// final transcript with an interruption marker via diagnostics.</summary>
    public void MarkInterruption()
    {
        Interlocked.Increment(ref _interruptions);
        Interlocked.Increment(ref _diag.Interruptions);
    }

    private void RecordSuppression(SuppressionReason reason)
    {
        switch (reason)
        {
            case SuppressionReason.PlaybackActive: Interlocked.Increment(ref _diag.SuppressedFromPlayback); break;
            case SuppressionReason.PostSpeechCooldown: Interlocked.Increment(ref _diag.SuppressedFromCooldown); break;
            case SuppressionReason.EchoSimilarity: Interlocked.Increment(ref _diag.SuppressedFromSimilarity); break;
            case SuppressionReason.Duplicate: Interlocked.Increment(ref _diag.DuplicateTranscripts); break;
        }
        _diagnostics?.Record(DiagnosticLevel.Debug, "sidecar.transcript", "suppressed",
            new Dictionary<string, object?> { ["reason"] = reason.ToString() });
    }

    private void ResetSession()
    {
        _sessionId = null;
        _partialsThisUtterance = 0;
    }

    public void Dispose() => Detach();
}
