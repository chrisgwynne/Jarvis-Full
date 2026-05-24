namespace Jarvis.Core.Automation;

public interface IHighlightRenderer
{
    /// <summary>Show a pulsing rect at the given device-pixel bounds for <paramref name="duration"/>.
    /// Must be safe to call from any thread; implementations marshal to the UI thread.
    /// Does not steal focus and does not block.</summary>
    Task ShowAsync(int x, int y, int width, int height, string? label, TimeSpan duration, CancellationToken cancellationToken = default);
}
