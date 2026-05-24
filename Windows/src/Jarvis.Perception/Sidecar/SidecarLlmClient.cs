using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Jarvis.Core.Conversation;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// An <see cref="ILlmClient"/> that asks the Mac brain to answer the user's message.
/// The bridge protocol sends a <c>chat.reply.partial</c> stream followed by
/// <c>chat.reply.final</c>. This client buffers those into the async-enumerable
/// shape the existing <see cref="ConversationService"/> expects.
///
/// Note: <see cref="IsConfigured"/> returns true only when the bridge is in the
/// <see cref="BridgeState.Connected"/> state. <see cref="DegradedModeRouter"/> uses that
/// to decide whether to forward to this client or to the local provider.
/// </summary>
public sealed class SidecarLlmClient : ILlmClient
{
    private readonly IMacBridgeCoordinator _bridge;
    private readonly ConcurrentDictionary<string, Channel<string>> _replyChannels = new();

    public SidecarLlmClient(IMacBridgeCoordinator bridge)
    {
        _bridge = bridge;
        _bridge.FrameReceived += OnFrame;
    }

    public bool IsConfigured => _bridge.Status.State == BridgeState.Connected;

    public async IAsyncEnumerable<string> StreamAsync(LlmRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (!IsConfigured)
        {
            yield return "_(Mac bridge not connected.)_";
            yield break;
        }
        var sessionId = Guid.NewGuid().ToString("N");
        var channel = Channel.CreateUnbounded<string>(new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = false
        });
        _replyChannels[sessionId] = channel;

        // Mac sees this as a transcript.final so the brain treats it as a typed message.
        await _bridge.SendAsync(new SidecarFrame
        {
            Type = SidecarFrameTypes.TranscriptFinal,
            SessionId = sessionId,
            Text = request.UserMessage,
            Confidence = 1.0,
            IsFinal = true,
            SnapshotHash = request.Context.SnapshotHash,
            At = DateTimeOffset.UtcNow
        }, cancellationToken).ConfigureAwait(false);

        try
        {
            while (await channel.Reader.WaitToReadAsync(cancellationToken).ConfigureAwait(false))
            {
                while (channel.Reader.TryRead(out var chunk))
                {
                    if (chunk.Length == 0) yield break; // sentinel: final frame received
                    yield return chunk;
                }
            }
        }
        finally
        {
            _replyChannels.TryRemove(sessionId, out _);
        }
    }

    private void OnFrame(object? sender, SidecarFrame frame)
    {
        if (string.IsNullOrEmpty(frame.SessionId)) return;
        if (!_replyChannels.TryGetValue(frame.SessionId, out var channel)) return;
        switch (frame.Type)
        {
            case SidecarFrameTypes.ChatReplyPartial when !string.IsNullOrEmpty(frame.Text):
                channel.Writer.TryWrite(frame.Text);
                break;
            case SidecarFrameTypes.ChatReplyFinal:
                if (!string.IsNullOrEmpty(frame.Text)) channel.Writer.TryWrite(frame.Text);
                channel.Writer.TryWrite(string.Empty); // sentinel
                channel.Writer.TryComplete();
                break;
            // Daemon nack — Mac brain unavailable; surface a message and close the channel
            // so the DegradedModeRouter can retry via local LLM on the next request.
            case GatewayMessageTypes.Nack:
                var reason = frame.Reason ?? frame.Message ?? "brain unavailable";
                channel.Writer.TryWrite($"_(Mac brain not available: {reason})_");
                channel.Writer.TryWrite(string.Empty); // sentinel
                channel.Writer.TryComplete();
                break;
        }
    }
}
