using System.Windows;
using Jarvis.App.Interop;
using Jarvis.Core.Automation;

namespace Jarvis.App.Automation;

public sealed class WpfHighlightRenderer : IHighlightRenderer
{
    public async Task ShowAsync(int x, int y, int width, int height, string? label, TimeSpan duration, CancellationToken cancellationToken = default)
    {
        var app = System.Windows.Application.Current;
        if (app is null) return;
        await app.Dispatcher.InvokeAsync(() =>
        {
            var window = new HighlightOverlayWindow(x, y, width, height, label, duration);
            window.SourceInitialized += (_, _) =>
            {
                // Reuse the overlay-style helper to add WS_EX_TRANSPARENT (click-through)
                // and TOOLWINDOW / NOACTIVATE so the highlight never steals focus.
                OverlayInterop.ApplyOverlayStyles(window, clickThrough: true);
            };
            window.Show();
        }).Task.ConfigureAwait(false);
    }
}
