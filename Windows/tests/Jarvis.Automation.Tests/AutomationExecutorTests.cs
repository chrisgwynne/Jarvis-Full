using FluentAssertions;
using Jarvis.Automation;
using Jarvis.Core.Automation;
using Xunit;

namespace Jarvis.Automation.Tests;

public class AutomationExecutorTests : IDisposable
{
    private readonly string _auditDir = Path.Combine(Path.GetTempPath(), "jarvis-ex-" + Guid.NewGuid().ToString("N"));
    private readonly FakeWindow _windows = new();
    private readonly FakeInput _input = new();
    private readonly FakeFile _files = new();
    private readonly FakeBrowser _browser = new();
    private readonly JsonlAuditLog _audit;

    private AutomationExecutor New(IApprovalGate? gate = null) => new(
        policy: new DefaultApprovalPolicy(),
        planner: new DryRunPlanner(new DefaultApprovalPolicy()),
        gate: gate ?? new AutoApproveGate(),
        audit: _audit,
        windows: _windows,
        input: _input,
        files: _files,
        browser: _browser);

    public AutomationExecutorTests() => _audit = new JsonlAuditLog(_auditDir);

    [Fact]
    public async Task Safe_intent_skips_the_gate_and_dispatches()
    {
        var gate = new RecordingGate();
        var exec = New(gate);
        var result = await exec.ExecuteAsync(new FocusWindowIntent("notepad"));
        result.Outcome.Should().Be(AutomationOutcome.Succeeded);
        gate.Calls.Should().Be(0, "Safe tier never asks for approval");
        _windows.FocusCalls.Should().Be(1);
    }

    [Fact]
    public async Task Blocked_intent_never_dispatches()
    {
        var exec = New();
        var result = await exec.ExecuteAsync(new TypeTextIntent("rm -rf /"));
        result.Outcome.Should().Be(AutomationOutcome.DeniedByPolicy);
        result.Plan.Safety.Tier.Should().Be(SafetyTier.Block);
        _input.TypeCalls.Should().Be(0);
    }

    [Fact]
    public async Task Denied_approval_does_not_dispatch()
    {
        var exec = New(new DenyingGate());
        var result = await exec.ExecuteAsync(new TypeTextIntent("hello"));
        result.Outcome.Should().Be(AutomationOutcome.DeniedByPolicy);
        _input.TypeCalls.Should().Be(0);
    }

    [Fact]
    public async Task Approved_intent_dispatches_and_audits()
    {
        var exec = New();
        var result = await exec.ExecuteAsync(new TypeTextIntent("hi"));
        result.Outcome.Should().Be(AutomationOutcome.Succeeded);
        _input.TypeCalls.Should().Be(1);
        _audit.Recent().Should().ContainSingle(e => e.IntentKind == "keyboard.type");
    }

    [Fact]
    public async Task Dispatch_failure_is_caught_and_reported()
    {
        _input.NextError = "fake-error";
        var exec = New();
        var result = await exec.ExecuteAsync(new TypeTextIntent("hi"));
        result.Outcome.Should().Be(AutomationOutcome.Failed);
        result.Message.Should().Be("fake-error");
        _audit.Recent().Last().Outcome.Should().Be(AutomationOutcome.Failed);
    }

    [Fact]
    public async Task Browser_command_serializes_with_camelCase()
    {
        var exec = New();
        var result = await exec.ExecuteAsync(new BrowserNavigateIntent("https://example.com"));
        result.Outcome.Should().Be(AutomationOutcome.Succeeded);
        _browser.LastCommand.Should().NotBeNull();
        _browser.LastCommand!.Type.Should().Be("navigate");
        _browser.LastCommand.Url.Should().Be("https://example.com");
    }

    [Fact]
    public void DryRun_returns_plan_without_dispatching()
    {
        var exec = New();
        var plan = exec.DryRun(new ClickIntent(10, 10));
        plan.Safety.Tier.Should().Be(SafetyTier.Approve);
        _input.ClickCalls.Should().Be(0);
    }

    public void Dispose() { try { Directory.Delete(_auditDir, recursive: true); } catch { } }

    // ── Fakes ───────────────────────────────────────────────────────────────

    private sealed class FakeWindow : IWindowAutomationSurface
    {
        public int FocusCalls;
        public Task<string?> FocusAsync(string p, string? t, CancellationToken c) { FocusCalls++; return Task.FromResult<string?>(null); }
        public Task<string?> MoveAsync(IntPtr h, int x, int y, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> ResizeAsync(IntPtr h, int w, int hh, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> SetStateAsync(IntPtr h, WindowState s, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> SwitchAppAsync(string p, CancellationToken c) => Task.FromResult<string?>(null);
    }

    private sealed class FakeInput : IInputAutomationSurface
    {
        public int TypeCalls;
        public int ClickCalls;
        public string? NextError;
        private string? Pop() { var e = NextError; NextError = null; return e; }
        public Task<string?> SendShortcutAsync(string a, CancellationToken c) => Task.FromResult(Pop());
        public Task<string?> TypeAsync(string t, CancellationToken c) { TypeCalls++; return Task.FromResult(Pop()); }
        public Task<string?> PasteAsync(string t, CancellationToken c) => Task.FromResult(Pop());
        public Task<string?> PressKeyAsync(string k, CancellationToken c) => Task.FromResult(Pop());
        public Task<string?> MoveCursorAsync(int x, int y, CancellationToken c) => Task.FromResult(Pop());
        public Task<string?> ClickAsync(int x, int y, MouseButtonKind b, int n, CancellationToken c) { ClickCalls++; return Task.FromResult(Pop()); }
        public Task<string?> ScrollAsync(int dx, int dy, CancellationToken c) => Task.FromResult(Pop());
    }

    private sealed class FakeFile : IFileAutomationSurface
    {
        public Task<string?> OpenAppAsync(string e, string? a, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> OpenFileAsync(string p, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> RevealAsync(string p, CancellationToken c) => Task.FromResult<string?>(null);
        public Task<string?> CreateDraftAsync(string p, string ct, bool o, CancellationToken c) => Task.FromResult<string?>(null);
    }

    private sealed class FakeBrowser : IBrowserCommandSurface
    {
        public bool IsAvailable => true;
        public BrowserCommand? LastCommand;
        public Task<string?> SendAsync(BrowserCommand command, CancellationToken c) { LastCommand = command; return Task.FromResult<string?>(null); }
        public Task<BrowserAck> SendWithAckAsync(BrowserCommand command, TimeSpan timeout, CancellationToken c)
        {
            LastCommand = command;
            return Task.FromResult(new BrowserAck(
                CommandId: command.CommandId ?? "ack",
                Accepted: true,
                Completed: true,
                Matches: command.Type == "dryRun" ? 1 : null,
                ResultingUrl: command.Url));
        }
    }

    private sealed class RecordingGate : IApprovalGate
    {
        public int Calls;
        public Task<ApprovalDecision> RequestAsync(AutomationIntent intent, AutomationPlan plan, CancellationToken c)
        { Calls++; return Task.FromResult(new ApprovalDecision(ApprovalOutcome.Approved, "test")); }
    }

    private sealed class DenyingGate : IApprovalGate
    {
        public Task<ApprovalDecision> RequestAsync(AutomationIntent intent, AutomationPlan plan, CancellationToken c)
            => Task.FromResult(new ApprovalDecision(ApprovalOutcome.Denied, "user denied"));
    }
}
