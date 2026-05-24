using FluentAssertions;
using Jarvis.Core.Settings;
using Jarvis.Settings;
using Xunit;

namespace Jarvis.Core.Tests;

public class JsonSettingsStoreTests : IDisposable
{
    private readonly string _dir;
    private readonly string _path;

    public JsonSettingsStoreTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "jarvis-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
        _path = Path.Combine(_dir, "settings.json");
    }

    [Fact]
    public async Task First_load_writes_defaults_to_disk()
    {
        var store = new JsonSettingsStore(_path);
        await store.LoadAsync();
        File.Exists(_path).Should().BeTrue();
        store.Current.Pebble.Size.Should().Be(32);
    }

    [Fact]
    public async Task Save_round_trips_through_disk()
    {
        var store = new JsonSettingsStore(_path);
        await store.LoadAsync();
        var modified = store.Current with { Pebble = store.Current.Pebble with { Size = 80, Opacity = 0.5 } };
        await store.SaveAsync(modified);

        var fresh = new JsonSettingsStore(_path);
        await fresh.LoadAsync();
        fresh.Current.Pebble.Size.Should().Be(80);
        fresh.Current.Pebble.Opacity.Should().Be(0.5);
    }

    [Fact]
    public async Task Corrupt_file_is_quarantined_and_replaced_with_defaults()
    {
        await File.WriteAllTextAsync(_path, "{ this is not json");
        var store = new JsonSettingsStore(_path);
        await store.LoadAsync();
        store.Current.Pebble.Size.Should().Be(32);
        Directory.GetFiles(_dir, "*.corrupt.*").Should().NotBeEmpty();
    }

    [Fact]
    public async Task Changed_event_fires_on_save()
    {
        var store = new JsonSettingsStore(_path);
        await store.LoadAsync();
        var fired = 0;
        store.Changed += (_, _) => fired++;
        await store.SaveAsync(store.Current with { });
        fired.Should().Be(1);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }
}
