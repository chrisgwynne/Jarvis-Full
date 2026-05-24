using System.IO;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;

namespace Jarvis.Perception.Conversation.Providers;

/// <summary>
/// Ollama <c>/api/chat</c>. Body shape mirrors OpenAI's "messages" array but the
/// response is line-delimited JSON, not SSE. Each line has a <c>message.content</c>
/// chunk and a <c>done</c> flag.
/// </summary>
public sealed class OllamaLlmClient : ILlmClient
{
    private static readonly JsonSerializerOptions JsonOpts = new() { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };

    private readonly Func<LlmSettings> _settings;
    private readonly HttpClient _http;
    public OllamaLlmClient(Func<LlmSettings> settings, HttpClient? http = null)
    {
        _settings = settings;
        _http = http ?? new HttpClient();
    }

    public bool IsConfigured
    {
        get
        {
            var s = _settings();
            return s.Provider == LlmProviderType.Ollama && !string.IsNullOrEmpty(s.Model);
        }
    }

    public async IAsyncEnumerable<string> StreamAsync(LlmRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var s = _settings();
        if (!IsConfigured)
        {
            yield return "_(Ollama provider not configured — set Settings.Llm.Model.)_";
            yield break;
        }
        var baseUrl = string.IsNullOrEmpty(s.BaseUrl) ? "http://127.0.0.1:11434" : s.BaseUrl.TrimEnd('/');
        var url = baseUrl + "/api/chat";

        var body = BuildBody(request, s);
        using var http = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json")
        };
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(TimeSpan.FromSeconds(Math.Max(5, s.TimeoutSeconds)));

        using var response = await _http.SendAsync(http, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            yield return $"_(Ollama error {(int)response.StatusCode}: {await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false)})_";
            yield break;
        }
        await using var stream = await response.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false);
        using var reader = new StreamReader(stream);
        while (!reader.EndOfStream)
        {
            cts.Token.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(cts.Token).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(line)) continue;
            string? piece;
            bool done = false;
            try
            {
                var node = JsonNode.Parse(line);
                piece = node?["message"]?["content"]?.GetValue<string>();
                done = node?["done"]?.GetValue<bool>() ?? false;
            }
            catch { piece = null; }
            if (!string.IsNullOrEmpty(piece)) yield return piece!;
            if (done) break;
        }
    }

    internal static string BuildBody(LlmRequest request, LlmSettings s)
    {
        var messages = new JsonArray
        {
            new JsonObject { ["role"] = "system", ["content"] = LlmContextSerializer.BuildSystemMessage(request.SystemPrompt, request.Context) }
        };
        foreach (var m in request.History)
        {
            messages.Add(new JsonObject
            {
                ["role"] = m.Role switch { ChatRole.User => "user", ChatRole.Assistant => "assistant", _ => "system" },
                ["content"] = m.Content
            });
        }
        messages.Add(new JsonObject { ["role"] = "user", ["content"] = request.UserMessage });

        return new JsonObject
        {
            ["model"] = s.Model,
            ["messages"] = messages,
            ["stream"] = s.Stream,
            ["options"] = new JsonObject
            {
                ["temperature"] = s.Temperature,
                ["num_predict"] = s.MaxTokens
            }
        }.ToJsonString(JsonOpts);
    }
}
