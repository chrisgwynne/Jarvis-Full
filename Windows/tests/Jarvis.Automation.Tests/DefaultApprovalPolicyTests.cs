using FluentAssertions;
using Jarvis.Automation;
using Jarvis.Core.Automation;
using Xunit;

namespace Jarvis.Automation.Tests;

public class DefaultApprovalPolicyTests
{
    private readonly DefaultApprovalPolicy _p = new();

    [Fact]
    public void Focus_window_is_safe() =>
        _p.Classify(new FocusWindowIntent("notepad")).Tier.Should().Be(SafetyTier.Safe);

    [Fact]
    public void Reveal_file_is_safe() =>
        _p.Classify(new RevealFileIntent(@"C:\Users\me\file.txt")).Tier.Should().Be(SafetyTier.Safe);

    [Fact]
    public void Scroll_is_safe() =>
        _p.Classify(new ScrollIntent(0, 100)).Tier.Should().Be(SafetyTier.Safe);

    [Fact]
    public void Move_window_is_confirm() =>
        _p.Classify(new MoveWindowIntent((IntPtr)123, 100, 100)).Tier.Should().Be(SafetyTier.Confirm);

    [Fact]
    public void Navigation_key_is_confirm() =>
        _p.Classify(new PressKeyIntent("Tab")).Tier.Should().Be(SafetyTier.Confirm);

    [Fact]
    public void Benign_shortcut_is_confirm() =>
        _p.Classify(new SendShortcutIntent("Ctrl+C")).Tier.Should().Be(SafetyTier.Confirm);

    [Fact]
    public void Browser_navigate_https_is_confirm() =>
        _p.Classify(new BrowserNavigateIntent("https://example.com")).Tier.Should().Be(SafetyTier.Confirm);

    [Fact]
    public void Type_text_requires_approval() =>
        _p.Classify(new TypeTextIntent("hello")).Tier.Should().Be(SafetyTier.Approve);

    [Fact]
    public void Click_requires_approval() =>
        _p.Classify(new ClickIntent(100, 200)).Tier.Should().Be(SafetyTier.Approve);

    [Fact]
    public void Open_app_requires_approval() =>
        _p.Classify(new OpenAppIntent("notepad.exe")).Tier.Should().Be(SafetyTier.Approve);

    [Fact]
    public void Create_draft_requires_approval() =>
        _p.Classify(new CreateDraftFileIntent(@"C:\Users\me\note.txt", "hi")).Tier.Should().Be(SafetyTier.Approve);

    [Fact]
    public void Privileged_executable_is_blocked()
    {
        var d = _p.Classify(new OpenAppIntent("powershell.exe"));
        d.Tier.Should().Be(SafetyTier.Block);
        d.BlockReason.Should().NotBeNullOrEmpty();
    }

    [Fact]
    public void File_protocol_browser_url_is_blocked() =>
        _p.Classify(new BrowserNavigateIntent("file:///C:/Windows/System32/")).Tier.Should().Be(SafetyTier.Block);

    [Fact]
    public void Javascript_url_is_blocked() =>
        _p.Classify(new BrowserNavigateIntent("javascript:alert(1)")).Tier.Should().Be(SafetyTier.Block);

    [Fact]
    public void Type_text_with_destructive_pattern_is_blocked()
    {
        var d = _p.Classify(new TypeTextIntent("rm -rf /"));
        d.Tier.Should().Be(SafetyTier.Block);
    }

    [Fact]
    public void Open_app_with_destructive_args_is_blocked() =>
        _p.Classify(new OpenAppIntent("notepad.exe", "format C:")).Tier.Should().Be(SafetyTier.Block);

    [Fact]
    public void Create_draft_in_windows_dir_is_blocked() =>
        _p.Classify(new CreateDraftFileIntent(@"C:\Windows\Temp\evil.txt", "x")).Tier.Should().Be(SafetyTier.Block);

    [Fact]
    public void Create_draft_under_program_files_is_blocked() =>
        _p.Classify(new CreateDraftFileIntent(@"C:\Program Files\Foo\bar.txt", "x")).Tier.Should().Be(SafetyTier.Block);
}
