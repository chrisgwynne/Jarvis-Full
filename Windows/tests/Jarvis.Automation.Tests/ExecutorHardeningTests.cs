using FluentAssertions;
using Jarvis.Automation;
using Jarvis.Core.Automation;
using Xunit;

namespace Jarvis.Automation.Tests;

/// <summary>
/// End-to-end tests of the P3.5 executor guards: rate limit, elevation, ACK timeout,
/// policy version + dryRunHash in audit, selector dry-run gating.
/// </summary>
public class ExecutorHardeningTests : IDisposable
{
    private readonly string _auditDir = Path.Combine(Path.GetTempPath(), "jarvis-ex35-" + Guid.NewGuid().ToString("N"));
    private readonly FakeBrowser _browser = new();
    private readonly JsonlAuditLog _audit;

    public ExecutorHardeningTests() => _audit = new JsonlAuditLog(_auditDir);

    private AutomationExecutor New(
        IRateLimiter? rate = null,
        IElevationProbe? elevation = null,
        IApprovalGate? gate = null) => new(
            policy: new DefaultApprovalPolicy(),
            planner: new DryRunPlanner(new DefaultApprovalPolicy()),
            gate: gate ?? new AutoApproveGate(),
            audit: _audit,
            windows: new NoopWindow(),
            input: new NoopInput(),
            files: new NoopFile(),
            browser: _browser,
            rateLimiter: rate,
            elevation: elevation);

    [Fact]
    public async Task Rate_limited_intent_is_denied_before_approval()
    {
        var rl = new TokenBucketRateLimiter(global: (1, TimeSpan.FromMinutes(1)));
        var exec = New(rate: rl);
        var first = await exec.ExecuteAsync(new FocusWindowIntent("notepad"));
        first.Outcome.Should().Be(AutomationOutcome.Succeeded);
        var second = await exec.ExecuteAsync(new FocusWindowIntent("notepad"));
        second.Outcome.Should().Be(AutomationOutcome.DeniedByPolicy);
        second.Message.Should().Contain("rate limit");
    }

    [Fact]
    public async Task Elevated_foreground_refuses_input_intents()
    {
        var probe = new AlwaysElevatedProbe();
        var exec = New(elevation: probe);
        var result = await exec.ExecuteAsync(new TypeTextIntent("hello"));
        result.Outcome.Should().Be(AutomationOutcome.Failed);
        result.Message.Should().Contain("elevated");
    }

    [Fact]
    public async Task Elevated_check_skipped_for_non_input_intents()
    {
        var probe = new AlwaysElevatedProbe();
        var exec = New(elevation: probe);
        var result = await exec.ExecuteAsync(new BrowserExtractSelectionIntent());
        result.Outcome.Should().Be(AutomationOutcome.Succeeded);
    }

    [Fact]
    public async Task Audit_entry_includes_policy_version_and_plan_hash()
    {
        var exec = New();
        await exec.ExecuteAsync(new FocusWindowIntent("notepad"));
        var entry = _audit.Recent().Last();
        entry.PolicyVersion.Should().Be(DefaultApprovalPolicy.Identifier);
        entry.DryRunHash.Should().NotBeNullOrEmpty();
        entry.DryRunHash!.Length.Should().Be(16);
    }

    [Fact]
    public async Task Browser_navigate_only_succeeds_when_ack_completes()
    {
        _browser.NextAckCompleted = true;
        var exec = New();
        var result = await exec.ExecuteAsync(new BrowserNavigateIntent("https://example.com"));
        result.Outcome.Should().Be(AutomationOutcome.Succeeded);
    }

    [Fact]
    public async Task Browser_navigate_fails_when_ack_says_not_completed()
    {
        _browser.NextAckCompleted = false;
        _browser.NextAckError = "user closed tab";
        var exec = New();
        var result = await exec.ExecuteAsync(new BrowserNavigateIntent("https://example.com"));
        result.Outcome.Should().Be(AutomationOutcome.Failed);
        result.Message.Should().Be("user closed tab");
    }

    [Fact]
    public async Task Browser_click_with_zero_matches_is_refused_before_clicking()
    {
        _browser.DryRunMatches = 0;
        var exec = New();
        var result = await exec.ExecuteAsync(new BrowserClickSelectorIntent("button#nope"));
        result.Outcome.Should().Be(AutomationOutcome.Failed);
        result.Message.Should().Contain("0 elements");
        _browser.ClickAttempted.Should().BeFalse();
    }

    [Fact]
    public async Task Browser_click_with_multiple_matches_is_refused()
    {
        _browser.DryRunMatches = 4;
        var exec = New();
        var result = await exec.ExecuteAsync(new BrowserClickSelectorIntent(".btn"));
        result.Outcome.Should().Be(AutomationOutcome.Failed);
        result.Message.Should().Contain("4 elements");
        _browser.ClickAttempted.Should().BeFalse();
    }

    [Fact]
    public async Task Browser_click_with_one_match_proceeds()
    {
        _browser.DryRunMatches = 1;
        _browser.NextAckCompleted = true;
        var exec = New();
        var result = await exec.ExecuteAsync(new BrowserClickSelectorIntent("button#submit"));
        result.Outcome.Should().Be(AutomationOutcome.Succeeded);
        _browser.ClickAttempted.Should().BeTrue();
    }

    public void Dispose() { try { Directory.Delete(_auditDir, recursive: true); } catch { } }

    // ── Fakes ───────────────────────────────────────────────────────────────

    private sealed class AlwaysElevatedProbe : IElevationProbe
    {
        public bool ForegroundRequiresElevation() => true;
        public bool WindowRequiresElevation(IntPtr hwnd) => true;
    }

    private sealed class NoopWindow : IWindowAutomationSurface
    {
        public Task<string?> FocusAsync(string p, string? t, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> MoveAsync(IntPtr h, int x, int y, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> ResizeAsync(IntPtr h, int w, int hh, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> SetStateAsync(IntPtr h, WindowState s, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> SwitchAppAsync(string p, CancellationToken c) => Task.FromResult<string?>(null);
    }

    private sealed class NoopInput : IInputAutomationSurface
    {
        public Task<string?> SendShortcutAsync(string a, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> TypeAsync(string t, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> PasteAsync(string t, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> PressKeyAsync(string k, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> MoveCursorAsync(int x, int y, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> ClickAsync(int x, int y, MouseButtonKind b, int n, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> ScrollAsync(int dx, int dy, CancellationToken c) => Task.FromResult<string?>(null);
    }

    private sealed class NoopFile : IFileAutomationSurface
    {
        public Task<string?> OpenAppAsync(string e, string? a, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> OpenFileAsync(string p, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> RevealAsync(string p, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> CreateDraftAsync(string p, string ct, bool o, CancellationToken c) => Task.FromResult<string?>(null);
    }

    private sealed class FakeBrowser : IBrowserCommandSurface
    {
        public bool IsAvailable => true;
        public bool NextAckCompleted = true;
        public string? NextAckError;
        public int DryRunMatches = 1;
        public bool ClickAttempted;
        public Task<string?> SendAsync(BrowserCommand command, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<BrowserAck> SendWithAckAsync(BrowserCommand command, TimeSpan timeout, CancellationToken c)
        {
            if (command.Type == "click") ClickAttempted = true;
            var matches = command.Type == "dryRun" ? (int?)DryRunMatches : null;
            return Task.FromResult(new BrowserAck(
                CommandId: command.CommandId ?? "ack",
                Accepted: true,
                Completed: NextAckCompleted,
                Error: NextAckCompleted ? null : NextAckError,
                Matches: matches));
        }
    }
}
