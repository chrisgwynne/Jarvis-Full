using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;

namespace Jarvis.Perception.Conversation.Providers;

/// <summary>
/// OpenAI Chat Completions (and any OpenAI-compatible server like vLLM, LM Studio,
/// llama.cpp's server, Together, Groq, …). Streams via SSE, parses <c>choices[0].delta.content</c>.
/// </summary>
public sealed class OpenAiLlmClient : ILlmClient
{
    private static readonly JsonSerializerOptions JsonOpts = new() { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };

    private readonly Func<LlmSettings> _settings;
    private readonly HttpClient _http;
    public OpenAiLlmClient(Func<LlmSettings> settings, HttpClient? http = null)
    {
        _settings = settings;
        _http = http ?? new HttpClient();
    }

    public bool IsConfigured
    {
        get
        {
            var s = _settings();
            return s.Provider == LlmProviderType.OpenAi
                && !string.IsNullOrEmpty(s.Model)
                && (!string.IsNullOrEmpty(s.ApiKey) || !string.IsNullOrEmpty(s.BaseUrl));
        }
    }

    public async IAsyncEnumerable<string> StreamAsync(LlmRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var s = _settings();
        if (!IsConfigured)
        {
            yield return "_(OpenAI provider not configured — set Settings.Llm.{ApiKey, Model}.)_";
            yield break;
        }
        var baseUrl = string.IsNullOrEmpty(s.BaseUrl) ? "https://api.openai.com" : s.BaseUrl.TrimEnd('/');
        var url = baseUrl + "/v1/chat/completions";

        var body = BuildBody(request, s);
        using var http = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json")
        };
        if (!string.IsNullOrEmpty(s.ApiKey))
            http.Headers.Authorization = new AuthenticationHeaderValue("Bearer", s.ApiKey);

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(TimeSpan.FromSeconds(Math.Max(5, s.TimeoutSeconds)));

        using var response = await _http.SendAsync(http, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            yield return $"_(OpenAI error {(int)response.StatusCode}: {await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false)})_";
            yield break;
        }
        await using var stream = await response.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false);
        await foreach (var data in SseLineReader.ReadAsync(stream, cts.Token).ConfigureAwait(false))
        {
            if (data == "[DONE]") yield break;
            string? piece;
            try
            {
                var node = JsonNode.Parse(data);
                piece = node?["choices"]?[0]?["delta"]?["content"]?.GetValue<string>();
            }
            catch { piece = null; }
            if (!string.IsNullOrEmpty(piece)) yield return piece!;
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

        var body = new JsonObject
        {
            ["model"] = s.Model,
            ["messages"] = messages,
            ["temperature"] = s.Temperature,
            ["max_tokens"] = s.MaxTokens,
            ["stream"] = s.Stream
        };
        return body.ToJsonString(JsonOpts);
    }
}
