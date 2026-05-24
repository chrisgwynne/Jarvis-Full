using System.Diagnostics;
using Jarvis.Core.Diagnostics;

namespace Jarvis.Diagnostics;

/// <summary>
/// Samples the host process's CPU/RAM and pushes them as diagnostics metrics.
/// Deliberately cheap: one tick = one Process.Refresh + two doubles.
/// </summary>
public sealed class PerformanceSampler : IAsyncDisposable
{
    private readonly IDiagnostics _diagnostics;
    private readonly TimeSpan _interval;
    private readonly Process _self = Process.GetCurrentProcess();
    private readonly CancellationTokenSource _cts = new();
    private Task? _loop;
    private TimeSpan _lastCpu;
    private DateTime _lastTick;

    public PerformanceSampler(IDiagnostics diagnostics, TimeSpan? interval = null)
    {
        _diagnostics = diagnostics;
        _interval = interval ?? TimeSpan.FromSeconds(2);
    }

    public void Start()
    {
        if (_loop is not null) return;
        _lastCpu = _self.TotalProcessorTime;
        _lastTick = DateTime.UtcNow;
        _loop = Task.Run(RunAsync);
    }

    private async Task RunAsync()
    {
        var token = _cts.Token;
        while (!token.IsCancellationRequested)
        {
            try
            {
                _self.Refresh();
                var now = DateTime.UtcNow;
                var cpu = _self.TotalProcessorTime;
                var elapsed = (now - _lastTick).TotalMilliseconds;
                var used = (cpu - _lastCpu).TotalMilliseconds;
                if (elapsed > 0)
                {
                    var cpuPercent = used / (elapsed * Environment.ProcessorCount) * 100.0;
                    _diagnostics.RecordMetric("cpu.percent", cpuPercent);
                }
                _diagnostics.RecordMetric("memory.workingSetMb", _self.WorkingSet64 / 1024d / 1024d);
                _diagnostics.RecordMetric("memory.privateMb", _self.PrivateMemorySize64 / 1024d / 1024d);
                _diagnostics.RecordMetric("threads", _self.Threads.Count);
                _lastCpu = cpu;
                _lastTick = now;
            }
            catch (Exception ex)
            {
                _diagnostics.Record(DiagnosticLevel.Warn, "perf", "sampler tick failed", new Dictionary<string, object?> { ["error"] = ex.Message });
            }

            try { await Task.Delay(_interval, token).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
        }
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        if (_loop is not null)
        {
            try { await _loop.ConfigureAwait(false); } catch { /* shutting down */ }
        }
        _cts.Dispose();
        _self.Dispose();
    }
}
