using System.Net.Http;
using System.Runtime.CompilerServices;
using Jarvis.Core.Conversation;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;

namespace Jarvis.Perception.Conversation.Providers;

/// <summary>
/// Picks the active <see cref="ILlmClient"/> from settings each call. Holds one
/// <see cref="HttpClient"/> across providers so connection pooling works. Returns
/// <see cref="EchoLlmClient"/> when nothing is configured, so the chat UI never
/// silently breaks.
/// </summary>
public sealed class LlmProviderManager : ILlmProviderManager
{
    private readonly Func<LlmSettings> _settings;
    private readonly IDiagnostics? _diagnostics;
    private readonly HttpClient _http = new();
    private readonly EchoLlmClient _echo = new();

    public LlmProviderManager(Func<LlmSettings> settings, IDiagnostics? diagnostics = null)
    {
        _settings = settings;
        _diagnostics = diagnostics;
    }

    public bool IsConfigured => Pick() is not EchoLlmClient;

    public ProviderStatus Status
    {
        get
        {
            var s = _settings();
            var picked = Pick();
            return new ProviderStatus(s.Provider, s.Model, picked is not EchoLlmClient,
                picked is EchoLlmClient ? "echo stub" : $"{s.Provider}/{s.Model}");
        }
    }

    public async IAsyncEnumerable<string> StreamAsync(LlmRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var stripper = new ThinkingTagStripper();
        var picked = Pick();
        _diagnostics?.Record(DiagnosticLevel.Debug, "llm", "stream begin",
            new Dictionary<string, object?> { ["provider"] = picked.GetType().Name });

        await foreach (var raw in picked.StreamAsync(request, cancellationToken).ConfigureAwait(false))
        {
            var visible = stripper.Push(raw);
            if (visible.Length > 0) yield return visible;
        }
        var tail = stripper.Flush();
        if (tail.Length > 0) yield return tail;
    }

    public async Task<ProviderConnectionResult> TestAsync(CancellationToken cancellationToken = default)
    {
        var picked = Pick();
        if (picked is EchoLlmClient) return new ProviderConnectionResult(false, "No provider configured.");
        try
        {
            var ping = new LlmRequest(
                SystemPrompt: "You are a connectivity test responder.",
                History: Array.Empty<ChatMessage>(),
                UserMessage: "Reply with the single word OK.",
                Context: ConversationContext.Empty);
            await foreach (var _ in picked.StreamAsync(ping, cancellationToken).WithCancellation(cancellationToken))
            {
                return new ProviderConnectionResult(true, "Provider responded.");
            }
            return new ProviderConnectionResult(false, "Provider produced no output.");
        }
        catch (Exception ex)
        {
            return new ProviderConnectionResult(false, ex.Message);
        }
    }

    private ILlmClient Pick()
    {
        var s = _settings();
        return s.Provider switch
        {
            LlmProviderType.OpenAi when !string.IsNullOrEmpty(s.Model)
                && (!string.IsNullOrEmpty(s.ApiKey) || !string.IsNullOrEmpty(s.BaseUrl))
                => new OpenAiLlmClient(_settings, _http),
            LlmProviderType.Ollama when !string.IsNullOrEmpty(s.Model)
                => new OllamaLlmClient(_settings, _http),
            LlmProviderType.MiniMax when !string.IsNullOrEmpty(s.Model) && !string.IsNullOrEmpty(s.ApiKey)
                => new MiniMaxLlmClient(_settings, _http),
            _ => _echo
        };
    }
}
