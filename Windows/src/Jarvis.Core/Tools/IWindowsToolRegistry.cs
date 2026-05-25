namespace Jarvis.Core.Tools;

public interface IWindowsToolRegistry
{
    IWindowsTool? Find(string nameOrAlias);
    IReadOnlyList<IWindowsTool> All { get; }
    bool IsEnabled { get; }
}
