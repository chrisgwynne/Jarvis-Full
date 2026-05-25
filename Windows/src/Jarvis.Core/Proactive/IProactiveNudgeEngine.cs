namespace Jarvis.Core.Proactive;

public sealed record ProactiveNudge(
    string Key,
    string Message,
    DateTimeOffset At);

public interface IProactiveNudgeEngine
{
    event EventHandler<ProactiveNudge>? NudgeReady;
    Task StartAsync(CancellationToken ct = default);
    Task StopAsync(CancellationToken ct = default);
}
