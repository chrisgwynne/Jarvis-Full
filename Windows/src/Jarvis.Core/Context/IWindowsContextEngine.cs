namespace Jarvis.Core.Context;

public interface IWindowsContextEngine
{
    WindowsContextSnapshot Current { get; }
    event EventHandler<WindowsContextSnapshot>? ContextChanged;
    Task StartAsync(CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);
}
