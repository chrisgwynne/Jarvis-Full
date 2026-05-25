using Jarvis.Core.Settings;
using Jarvis.Core.Tools;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Thread-safe registry of all registered <see cref="IWindowsTool"/> instances.
/// The lookup dictionary is built once in the constructor and is immutable thereafter.
/// </summary>
public sealed class WindowsToolRegistry : IWindowsToolRegistry
{
    private readonly IReadOnlyDictionary<string, IWindowsTool> _byKey;
    private readonly IReadOnlyList<IWindowsTool> _all;
    private readonly Func<ToolsSettings> _settings;

    public WindowsToolRegistry(IEnumerable<IWindowsTool> tools, Func<ToolsSettings> settings)
    {
        _settings = settings;
        var list = tools.ToList();
        _all = list.AsReadOnly();

        var dict = new Dictionary<string, IWindowsTool>(StringComparer.OrdinalIgnoreCase);
        foreach (var tool in list)
        {
            // Canonical name
            dict.TryAdd(tool.Name, tool);
            // All aliases
            foreach (var alias in tool.Aliases)
                dict.TryAdd(alias, tool);
        }
        _byKey = dict;
    }

    public IWindowsTool? Find(string nameOrAlias)
    {
        if (!_settings().Enabled) return null;
        _byKey.TryGetValue(nameOrAlias, out var tool);
        return tool;
    }

    public IReadOnlyList<IWindowsTool> All => _all;

    public bool IsEnabled => _settings().Enabled;
}
