using Jarvis.Core.Logging;
using Jarvis.Core.Sidecar;

namespace Jarvis.Settings;

/// <summary>
/// Decorator for <see cref="ILocalTtsService"/> that logs every spoken reply
/// to <see cref="IReplyLogger"/> before delegating to the real TTS engine.
/// Source is always <see cref="ReplySource.System"/> at the TTS layer — callers
/// that know the semantic source (command, llm, tool) should call
/// <see cref="IReplyLogger.Append"/> directly before invoking SpeakAsync.
/// This decorator acts as a catch-all safety net for any path that doesn't tag itself.
/// </summary>
public sealed class LoggingTtsService : ILocalTtsService
{
    private readonly ILocalTtsService _inner;
    private readonly IReplyLogger _logger;

    public LoggingTtsService(ILocalTtsService inner, IReplyLogger logger)
    {
        _inner = inner;
        _logger = logger;
    }

    public bool IsSpeaking => _inner.IsSpeaking;

    public async Task<bool> SpeakAsync(string text, CancellationToken cancellationToken = default)
    {
        if (!string.IsNullOrWhiteSpace(text))
            _logger.Append(ReplySource.System, text, editableFlag: false);
        return await _inner.SpeakAsync(text, cancellationToken).ConfigureAwait(false);
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
        => _inner.StopAsync(cancellationToken);
}
