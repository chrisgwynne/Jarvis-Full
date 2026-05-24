using FluentAssertions;
using Jarvis.Perception.Ide;
using Xunit;

namespace Jarvis.Perception.Tests;

public class WindowTitleIdeContextProviderTests
{
    [Theory]
    [InlineData("code", "VS Code")]
    [InlineData("Code", "VS Code")]
    [InlineData("Code - Insiders", "VS Code")]
    [InlineData("cursor", "Cursor")]
    [InlineData("devenv", "Visual Studio")]
    [InlineData("rider64", "Rider")]
    [InlineData("pycharm64", "PyCharm")]
    [InlineData("sublime_text", "Sublime Text")]
    [InlineData("explorer", null)]
    [InlineData("", null)]
    public void MapEditor_handles_known_processes(string process, string? expected) =>
        WindowTitleIdeContextProvider.MapEditor(process).Should().Be(expected);

    [Theory]
    [InlineData("VS Code", "Program.cs - jarvis - Visual Studio Code", "Program.cs", "jarvis")]
    [InlineData("VS Code", "Program.cs ● - jarvis - Visual Studio Code", "Program.cs", "jarvis")]
    [InlineData("Cursor",  "App.tsx - my-app - Cursor", "App.tsx", "my-app")]
    [InlineData("Rider",   "jarvis – Program.cs", "Program.cs", "jarvis")]
    [InlineData("Visual Studio", "Program.cs - Microsoft Visual Studio", "Program.cs", null)]
    public void ParseTitle_extracts_file_and_folder(string editor, string title, string expectedFile, string? expectedFolder)
    {
        var (file, folder) = WindowTitleIdeContextProvider.ParseTitle(editor, title);
        file.Should().Be(expectedFile);
        folder.Should().Be(expectedFolder);
    }

    [Fact]
    public void ParseTitle_returns_nulls_on_unrecognised_title()
    {
        var (file, folder) = WindowTitleIdeContextProvider.ParseTitle("VS Code", "");
        file.Should().BeNull();
        folder.Should().BeNull();
    }
}
