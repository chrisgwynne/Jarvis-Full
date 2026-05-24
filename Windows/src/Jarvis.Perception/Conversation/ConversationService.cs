using System.Diagnostics;
using System.Text;
using Jarvis.Core.Conversation;
using Jarvis.Core.Diagnostics;

namespace Jarvis.Perception.Conversation;

/// <summary>
/// Orchestrates one user turn:
///   1. Build context.
///   2. Classify intent.
///   3. Route — local handler may stream OR reply inline OR pass through to LLM.
///   4. If routed to LLM and a client is configured, stream chunks.
///   5. Emit a single assistant ChatMessage; raise events for the UI.
///
/// All state lives in <see cref="History"/>. The service holds a hard cap (default 64
/// messages) and trims the oldest pair when exceeded — keeps both ends conversational
/// without unbounded memory.
/// </summary>
public sealed class ConversationService : IConversationService
{
    private const int MaxHistory = 64;
    private const string SystemPrompt =
        "You are Jarvis, a Windows desktop assistant. Be terse, useful, and concrete. " +
        "When the user asks about their screen, the context block tells you what they're seeing. " +
        "Never claim to have clicked or moved things unless the context says you did.";

    private readonly IConversationContextBuilder _contextBuilder;
    private readonly ILocalIntentRouter _router;
    private readonly ILlmClient _llm;
    private readonly IContextBudgeter? _budgeter;
    private readonly IQuotaGuard? _quota;
    private readonly IDiagnostics? _diagnostics;
    private readonly List<ChatMessage> _history = new();
    private readonly object _gate = new();

    public ConversationService(
        IConversationContextBuilder contextBuilder,
        ILocalIntentRouter router,
        ILlmClient llm,
        IContextBudgeter? budgeter = null,
        IQuotaGuard? quota = null,
        IDiagnostics? diagnostics = null)
    {
        _contextBuilder = contextBuilder;
        _router = router;
        _llm = llm;
        _budgeter = budgeter;
        _quota = quota;
        _diagnostics = diagnostics;
    }

    public IReadOnlyList<ChatMessage> History { get { lock (_gate) return _history.ToArray(); } }
    public IReadOnlyList<ConversationDiagnostics> Diagnostics { get { lock (_gate) return _diagnosticsLog.ToArray(); } }
    private readonly List<ConversationDiagnostics> _diagnosticsLog = new();

    public event EventHandler<ChatMessage>? MessageAppended;
    public event EventHandler<ChatMessage>? StreamChunk;
    public event EventHandler<ConversationTurn>? TurnCompleted;

    public void Clear()
    {
        lock (_gate) { _history.Clear(); _diagnosticsLog.Clear(); }
    }

    public async Task<ConversationTurn> SendAsync(string userMessage, CancellationToken cancellationToken = default)
    {
        var sw = Stopwatch.StartNew();
        var userMsg = new ChatMessage(ChatRole.User, userMessage, DateTimeOffset.UtcNow);
        Append(userMsg);
        MessageAppended?.Invoke(this, userMsg);

        var context = _contextBuilder.Build();
        var intent = _router.Classify(userMessage);
        string? actionSummary = null;
        string? error = null;
        string? cancelReason = null;
        bool llmUsed = false;
        double? firstTokenMs = null;
        RedactionReport? redaction = null;
        string? providerType = null;
        string? providerModel = null;

        var assistantBuilder = new StringBuilder();
        var assistantMsg = new ChatMessage(ChatRole.Assistant, "", DateTimeOffset.UtcNow,
            RoutedIntent: intent.ToString(), Streaming: true);
        Append(assistantMsg);
        MessageAppended?.Invoke(this, assistantMsg);

        try
        {
            var routed = await _router.RouteAsync(intent, userMessage, context, cancellationToken).ConfigureAwait(false);
            actionSummary = routed.ActionSummary;

            if (routed.InlineReply is not null)
            {
                assistantBuilder.Append(routed.InlineReply);
                EmitChunk(assistantMsg, routed.InlineReply);
            }
            else if (routed.Stream is not null)
            {
                await foreach (var chunk in routed.Stream.WithCancellation(cancellationToken).ConfigureAwait(false))
                {
                    assistantBuilder.Append(chunk);
                    EmitChunk(assistantMsg, chunk);
                }
            }
            else if (routed.RequiresLlm)
            {
                llmUsed = true;
                var contextForLlm = context;
                if (_budgeter is not null)
                {
                    var (compact, report) = _budgeter.Budget(context);
                    contextForLlm = compact;
                    redaction = report;
                }
                var providerKind = Jarvis.Core.Settings.LlmProviderType.None;
                if (_llm is ILlmProviderManager mgr)
                {
                    providerType = mgr.Status.Type.ToString();
                    providerModel = mgr.Status.Model;
                    providerKind = mgr.Status.Type;
                }
                // Quota check — only blocks cloud providers (local exempted by default).
                if (_quota is not null)
                {
                    var approx = userMessage.Length + EstimateContextChars(contextForLlm);
                    var res = _quota.Reserve(providerKind, approx);
                    if (!res.Allowed)
                    {
                        actionSummary = "quota";
                        var msg = $"_(daily quota exceeded — {res.Reason}. Adjust Settings.Quota or wait for tomorrow.)_";
                        assistantBuilder.Append(msg);
                        EmitChunk(assistantMsg, msg);
                        llmUsed = false; // we didn't actually call the LLM
                        goto finish;
                    }
                }
                var request = new LlmRequest(SystemPrompt, History.SkipLast(1).ToArray(), userMessage, contextForLlm);
                var firstTokenSw = Stopwatch.StartNew();
                await foreach (var chunk in _llm.StreamAsync(request, cancellationToken).ConfigureAwait(false))
                {
                    if (firstTokenMs is null) { firstTokenSw.Stop(); firstTokenMs = firstTokenSw.Elapsed.TotalMilliseconds; }
                    assistantBuilder.Append(chunk);
                    EmitChunk(assistantMsg, chunk);
                }
                _quota?.RecordOutput(assistantBuilder.Length);
            }
            finish: ;
        }
        catch (OperationCanceledException)
        {
            cancelReason = "user cancelled";
            assistantBuilder.Append("\n\n_(cancelled)_");
            EmitChunk(assistantMsg, "\n\n_(cancelled)_");
        }
        catch (Exception ex)
        {
            error = ex.Message;
            assistantBuilder.Append($"\n\n_(error: {ex.Message})_");
            EmitChunk(assistantMsg, $"\n\n_(error: {ex.Message})_");
        }

        var finalAssistant = assistantMsg with { Content = assistantBuilder.ToString(), Streaming = false };
        ReplaceLast(finalAssistant);
        sw.Stop();
        var diag = new ConversationDiagnostics(
            At: userMsg.At,
            UserMessage: userMessage,
            Intent: intent,
            SnapshotHash: context.SnapshotHash,
            LlmUsed: llmUsed,
            TotalMs: sw.Elapsed.TotalMilliseconds,
            ActionSummary: actionSummary,
            Error: error,
            ProviderType: providerType,
            Model: providerModel,
            FirstTokenMs: firstTokenMs,
            OutputChars: assistantBuilder.Length,
            Redaction: redaction,
            CancelReason: cancelReason);
        _diagnostics?.Record(error is null ? DiagnosticLevel.Info : DiagnosticLevel.Warn,
            "conversation", "turn",
            new Dictionary<string, object?>
            {
                ["intent"] = intent.ToString(),
                ["llm"] = llmUsed,
                ["ms"] = sw.Elapsed.TotalMilliseconds,
                ["action"] = actionSummary,
                ["err"] = error
            });
        var turn = new ConversationTurn(userMsg, intent, finalAssistant, diag);
        lock (_gate) _diagnosticsLog.Add(diag);
        TurnCompleted?.Invoke(this, turn);
        return turn;
    }

    private void Append(ChatMessage msg)
    {
        lock (_gate)
        {
            _history.Add(msg);
            // Trim oldest pair when over cap.
            while (_history.Count > MaxHistory) _history.RemoveAt(0);
        }
    }

    private void ReplaceLast(ChatMessage msg)
    {
        lock (_gate)
        {
            if (_history.Count > 0) _history[^1] = msg;
        }
    }

    private void EmitChunk(ChatMessage placeholder, string chunk)
    {
        // Update the in-history message content as we stream so subscribers reading
        // History during streaming see consistent state.
        lock (_gate)
        {
            if (_history.Count > 0 && _history[^1].At == placeholder.At)
                _history[^1] = _history[^1] with { Content = _history[^1].Content + chunk };
        }
        StreamChunk?.Invoke(this, placeholder with { Content = chunk });
    }

    private static int EstimateContextChars(ConversationContext c) =>
        (c.ForegroundApp?.Length ?? 0)
      + (c.ForegroundWindowTitle?.Length ?? 0)
      + (c.SelectedText?.Length ?? 0)
      + (c.ClipboardSummary?.Length ?? 0)
      + (c.RecentOcrSummary?.Length ?? 0)
      + (c.Browser?.Url?.Length ?? 0)
      + (c.Browser?.Title?.Length ?? 0)
      + (c.Browser?.SelectedText?.Length ?? 0)
      + (c.Ide?.ActiveFile?.Length ?? 0);
}
