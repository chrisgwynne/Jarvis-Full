using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Jarvis.Core.Automation;
using Jarvis.Core.Diagnostics;
using Microsoft.Extensions.Logging;

namespace Jarvis.Automation;

/// <summary>
/// The single entry point for "Jarvis, please do X". Coordinates:
///   1. Rate limiting     — IRateLimiter.TryAcquire
///   2. Classification    — IApprovalPolicy.Classify
///   3. Planning          — IDryRunPlanner.Plan
///   4. Elevation guard   — IElevationProbe (refuses input/window ops to elevated targets)
///   5. Approval          — IApprovalGate (skipped for Safe)
///   6. Dispatch          — per-intent surface call (browser intents wait for ACK)
///   7. Audit             — IAuditLog.AppendAsync with policy version + plan hash
/// </summary>
public sealed class AutomationExecutor : IAutomationExecutor
{
    private static readonly TimeSpan BrowserAckTimeout = TimeSpan.FromSeconds(5);

    private readonly IApprovalPolicy _policy;
    private readonly IDryRunPlanner _planner;
    private readonly IApprovalGate _gate;
    private readonly IAuditLog _audit;
    private readonly IRateLimiter? _rateLimiter;
    private readonly IElevationProbe? _elevation;
    private readonly IHighlightRenderer? _highlight;
    private readonly IWindowAutomationSurface _windows;
    private readonly IInputAutomationSurface _input;
    private readonly IFileAutomationSurface _files;
    private readonly IBrowserCommandSurface _browser;
    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<AutomationExecutor>? _logger;

    public AutomationExecutor(
        IApprovalPolicy policy,
        IDryRunPlanner planner,
        IApprovalGate gate,
        IAuditLog audit,
        IWindowAutomationSurface windows,
        IInputAutomationSurface input,
        IFileAutomationSurface files,
        IBrowserCommandSurface browser,
        IRateLimiter? rateLimiter = null,
        IElevationProbe? elevation = null,
        IHighlightRenderer? highlight = null,
        IDiagnostics? diagnostics = null,
        ILogger<AutomationExecutor>? logger = null)
    {
        _policy = policy;
        _planner = planner;
        _gate = gate;
        _audit = audit;
        _windows = windows;
        _input = input;
        _files = files;
        _browser = browser;
        _rateLimiter = rateLimiter;
        _elevation = elevation;
        _highlight = highlight;
        _diagnostics = diagnostics;
        _logger = logger;
    }

    public AutomationPlan DryRun(AutomationIntent intent) => _planner.Plan(intent);

    public async Task<AutomationResult> ExecuteAsync(AutomationIntent intent, CancellationToken cancellationToken = default)
    {
        var startedAt = DateTimeOffset.UtcNow;
        var sw = Stopwatch.StartNew();
        var plan = _planner.Plan(intent);
        var planHash = HashPlan(plan);
        string? approver = null;

        try
        {
            if (_rateLimiter is not null)
            {
                var rate = _rateLimiter.TryAcquire(intent.Kind);
                if (!rate.Allowed)
                    return await FinaliseAsync(intent, plan, planHash, AutomationOutcome.DeniedByPolicy, rate.Reason, plan.UndoHint, startedAt, sw, "rate limiter", cancellationToken).ConfigureAwait(false);
            }

            if (plan.Safety.Tier == SafetyTier.Block)
                return await FinaliseAsync(intent, plan, planHash, AutomationOutcome.DeniedByPolicy, plan.Safety.BlockReason ?? plan.Safety.Reason, plan.UndoHint, startedAt, sw, null, cancellationToken).ConfigureAwait(false);

            if (_elevation is not null && RequiresInputDelivery(intent) && _elevation.ForegroundRequiresElevation())
                return await FinaliseAsync(intent, plan, planHash, AutomationOutcome.Failed,
                    "target window is elevated; Jarvis is not — synthesized input would be silently dropped",
                    plan.UndoHint, startedAt, sw, "elevation guard", cancellationToken).ConfigureAwait(false);

            if (plan.Safety.Tier != SafetyTier.Safe)
            {
                var decision = await _gate.RequestAsync(intent, plan, cancellationToken).ConfigureAwait(false);
                approver = decision.Note;
                if (decision.Outcome == ApprovalOutcome.Denied)
                    return await FinaliseAsync(intent, plan, planHash, AutomationOutcome.DeniedByPolicy, "user denied", plan.UndoHint, startedAt, sw, approver, cancellationToken).ConfigureAwait(false);
                if (decision.Outcome == ApprovalOutcome.TimedOut)
                    return await FinaliseAsync(intent, plan, planHash, AutomationOutcome.TimedOut, "approval timed out", plan.UndoHint, startedAt, sw, approver, cancellationToken).ConfigureAwait(false);
            }
            else
            {
                approver = "auto (Safe tier)";
            }

            var dispatchError = await DispatchAsync(intent, cancellationToken).ConfigureAwait(false);
            var outcome = dispatchError is null ? AutomationOutcome.Succeeded : AutomationOutcome.Failed;
            return await FinaliseAsync(intent, plan, planHash, outcome, dispatchError, plan.UndoHint, startedAt, sw, approver, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return await FinaliseAsync(intent, plan, planHash, AutomationOutcome.CancelledByUser, "cancelled", plan.UndoHint, startedAt, sw, approver, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(ex, "Automation pipeline crashed");
            return await FinaliseAsync(intent, plan, planHash, AutomationOutcome.Failed, ex.Message, plan.UndoHint, startedAt, sw, approver, CancellationToken.None).ConfigureAwait(false);
        }
    }

    private static bool RequiresInputDelivery(AutomationIntent intent) => intent is
        SendShortcutIntent or TypeTextIntent or PasteTextIntent or PressKeyIntent or
        ClickIntent or ScrollIntent or
        FocusWindowIntent or SwitchAppIntent or MoveWindowIntent or ResizeWindowIntent or SetWindowStateIntent;

    private async Task<string?> DispatchAsync(AutomationIntent intent, CancellationToken ct) => intent switch
    {
        FocusWindowIntent f => await _windows.FocusAsync(f.Process, f.TitleSubstring, ct),
        MoveWindowIntent m => await _windows.MoveAsync(m.Hwnd, m.X, m.Y, ct),
        ResizeWindowIntent r => await _windows.ResizeAsync(r.Hwnd, r.Width, r.Height, ct),
        SetWindowStateIntent s => await _windows.SetStateAsync(s.Hwnd, s.State, ct),
        SwitchAppIntent sw => await _windows.SwitchAppAsync(sw.Process, ct),

        SendShortcutIntent sh => await _input.SendShortcutAsync(sh.Accelerator, ct),
        TypeTextIntent t => await _input.TypeAsync(t.Text, ct),
        PasteTextIntent p => await _input.PasteAsync(p.Text, ct),
        PressKeyIntent pk => await _input.PressKeyAsync(pk.Key, ct),
        MoveCursorIntent mc => await _input.MoveCursorAsync(mc.X, mc.Y, ct),
        ClickIntent ck => await _input.ClickAsync(ck.X, ck.Y, ck.Button, ck.Count, ct),
        ScrollIntent sc => await _input.ScrollAsync(sc.Dx, sc.Dy, ct),

        HighlightTargetIntent h => await DispatchHighlightAsync(h, ct),

        BrowserNavigateIntent bn => await DispatchBrowserAsync(new BrowserCommand("navigate", Url: bn.Url), ct),
        BrowserReloadIntent => await DispatchBrowserAsync(new BrowserCommand("reload"), ct),
        BrowserHistoryIntent bh => await DispatchBrowserAsync(new BrowserCommand(bh.Direction == BrowserHistoryDirection.Back ? "back" : "forward"), ct),
        BrowserFocusInputIntent bf => await DispatchBrowserAsync(new BrowserCommand("focusInput", Selector: bf.Selector), ct),
        BrowserExtractSelectionIntent => await DispatchBrowserAsync(new BrowserCommand("extractSelection"), ct),
        BrowserScrollIntent bsc => await DispatchBrowserAsync(new BrowserCommand("scroll", Dy: bsc.Dy), ct),
        BrowserClickSelectorIntent bc => await DispatchBrowserClickAsync(bc, ct),

        OpenAppIntent oa => await _files.OpenAppAsync(oa.Executable, oa.Arguments, ct),
        OpenFileIntent of => await _files.OpenFileAsync(of.Path, ct),
        RevealFileIntent rf => await _files.RevealAsync(rf.Path, ct),
        CreateDraftFileIntent cd => await _files.CreateDraftAsync(cd.Path, cd.Content, cd.Overwrite, ct),

        _ => $"no dispatcher for intent kind '{intent.Kind}'"
    };

    private async Task<string?> DispatchHighlightAsync(HighlightTargetIntent h, CancellationToken ct)
    {
        if (_highlight is null) return null;
        await _highlight.ShowAsync(h.X, h.Y, h.Width, h.Height, h.Label, TimeSpan.FromMilliseconds(1500), ct).ConfigureAwait(false);
        return null;
    }

    private async Task<string?> DispatchBrowserAsync(BrowserCommand command, CancellationToken ct)
    {
        var ack = await _browser.SendWithAckAsync(command, BrowserAckTimeout, ct).ConfigureAwait(false);
        return ack.Completed ? null : (ack.Error ?? "browser did not complete the command");
    }

    /// <summary>Two-phase browser click: dryRun the selector first; only proceed when it
    /// matches exactly one element. Prevents accidentally clicking ambiguous targets
    /// when an LLM-suggested selector is off.</summary>
    private async Task<string?> DispatchBrowserClickAsync(BrowserClickSelectorIntent bc, CancellationToken ct)
    {
        var dry = await _browser.SendWithAckAsync(new BrowserCommand("dryRun", Selector: bc.Selector), BrowserAckTimeout, ct).ConfigureAwait(false);
        if (!dry.Completed) return dry.Error ?? "selector dry-run failed";
        if (dry.Matches is null) return "selector dry-run returned no match count";
        if (dry.Matches != 1) return $"selector matched {dry.Matches} elements; refusing to click an ambiguous target";
        var ack = await _browser.SendWithAckAsync(new BrowserCommand("click", Selector: bc.Selector), BrowserAckTimeout, ct).ConfigureAwait(false);
        return ack.Completed ? null : (ack.Error ?? "browser click did not complete");
    }

    private async Task<AutomationResult> FinaliseAsync(
        AutomationIntent intent, AutomationPlan plan, string planHash, AutomationOutcome outcome,
        string? message, string? undoHint, DateTimeOffset startedAt, Stopwatch sw,
        string? approver, CancellationToken cancellationToken)
    {
        sw.Stop();
        var result = new AutomationResult(intent, plan, outcome, message, undoHint, startedAt, sw.Elapsed);
        await _audit.AppendAsync(new AuditEntry(
            At: startedAt,
            IntentKind: intent.Kind,
            IntentSummary: intent.Summary,
            Tier: plan.Safety.Tier,
            TierReason: plan.Safety.Reason,
            Outcome: outcome,
            Message: message,
            UndoHint: undoHint,
            DurationMs: sw.Elapsed.TotalMilliseconds,
            Approver: approver,
            PolicyVersion: _policy.Version,
            DryRunHash: planHash), cancellationToken).ConfigureAwait(false);
        _diagnostics?.Record(
            outcome == AutomationOutcome.Succeeded ? DiagnosticLevel.Info : DiagnosticLevel.Warn,
            "automation",
            $"{intent.Kind} {outcome}",
            new Dictionary<string, object?>
            {
                ["tier"] = plan.Safety.Tier.ToString(),
                ["ms"] = sw.Elapsed.TotalMilliseconds,
                ["msg"] = message,
                ["policy"] = _policy.Version
            });
        _diagnostics?.RecordMetric("automation.lastMs", sw.Elapsed.TotalMilliseconds);
        return result;
    }

    internal static string HashPlan(AutomationPlan plan)
    {
        var key = string.Join('|', plan.Headline, string.Join('\n', plan.Steps), plan.Target ?? "", plan.UndoHint ?? "", plan.Safety.Tier);
        var bytes = SHA1.HashData(Encoding.UTF8.GetBytes(key));
        return Convert.ToHexString(bytes)[..16];
    }
}
