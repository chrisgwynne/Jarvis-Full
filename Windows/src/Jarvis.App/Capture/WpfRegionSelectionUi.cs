using System.Windows;
using Jarvis.Perception.Capture;

namespace Jarvis.App.Capture;

public sealed class WpfRegionSelectionUi : IRegionSelectionUi
{
    public async Task<RegionSelection?> SelectAsync(CancellationToken cancellationToken = default)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher
            ?? throw new InvalidOperationException("Region capture requires a WPF Application.");

        // Marshal to UI thread; show window; await user.
        return await dispatcher.InvokeAsync(async () =>
        {
            var window = new RegionSelectionWindow();
            window.Show();
            using var reg = cancellationToken.Register(() => window.Dispatcher.BeginInvoke(window.Close));
            return await window.WaitForSelection().ConfigureAwait(true);
        }).Task.Unwrap().ConfigureAwait(false);
    }
}
