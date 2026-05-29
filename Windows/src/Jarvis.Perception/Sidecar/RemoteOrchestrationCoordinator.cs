using Jarvis.Core.Diagnostics;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Default implementation. Strict filter: anything that isn't an orchestration frame is
/// ignored. We do not interpret orchestrate.speak as "Mac granted a lease" — the lease
/// is a separate frame; orchestrate.speak is just an *intent*, and the existing lease
/// coordinator remains authoritative.
/// </summary>
public sealed class RemoteOrchestrationCoordinator : IRemoteOrchestrationCoordinator
{
    private readonly IMacBridgeCoordinator _bridge;
    private readonly IDiagnostics? _diagnostics;
    private int _silence, _speak, _proactive;
    private bool _attached;

    public int SilenceCommands => _silence;
    public int SpeakCommands => _speak;
    public int ProactiveNotifications => _proactive;

    public event EventHandler<string>? SpeakRequested;
    public event EventHandler? SilenceRequested;
    public event EventHandler<ProactiveNotice>? ProactiveReceived;

    public RemoteOrchestrationCoordinator(IMacBridgeCoordinator bridge, IDiagnostics? diagnostics = null)
    {
        _bridge = bridge;
        _diagnostics = diagnostics;
    }

    public void Attach()
    {
        if (_attached) return;
        _bridge.FrameReceived += OnFrame;
        _attached = true;
    }

    private void OnFrame(object? sender, SidecarFrame frame)
    {
        switch (frame.Type)
        {
            case SidecarFrameTypes.OrchestrateSilent:
                Interlocked.Increment(ref _silence);
                _diagnostics?.Record(DiagnosticLevel.Info, "orchestrate", "silence",
                    new Dictionary<string, object?> { ["reason"] = frame.Reason });
                SilenceRequested?.Invoke(this, EventArgs.Empty);
                break;
            case SidecarFrameTypes.OrchestrateSpeak:
                Interlocked.Increment(ref _speak);
                _diagnostics?.Record(DiagnosticLevel.Info, "orchestrate", "speak requested",
                    new Dictionary<string, object?>
                    {
                        // Privacy: the speak text is user-facing content — log length + hash only.
                        ["textLen"] = DiagnosticsRedaction.Length(frame.Text),
                        ["textHash"] = DiagnosticsRedaction.Hash(frame.Text)
                    });
                SpeakRequested?.Invoke(this, frame.Text ?? string.Empty);
                break;
            case SidecarFrameTypes.ProactiveNotify:
                Interlocked.Increment(ref _proactive);
                var notice = new ProactiveNotice(frame.Reason, frame.Text, frame.Source,
                    frame.At ?? DateTimeOffset.UtcNow);
                _diagnostics?.Record(DiagnosticLevel.Info, "orchestrate", "proactive",
                    new Dictionary<string, object?> { ["title"] = notice.Title, ["source"] = notice.Source });
                ProactiveReceived?.Invoke(this, notice);
                break;
        }
    }

    public void Dispose()
    {
        if (_attached) { _bridge.FrameReceived -= OnFrame; _attached = false; }
    }
}
