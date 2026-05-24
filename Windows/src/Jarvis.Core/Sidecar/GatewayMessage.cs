using System.Text.Json;
using System.Text.Json.Serialization;

namespace Jarvis.Core.Sidecar;

// ─────────────────────────────────────────────────────────────────────────────
// Canonical daemon gateway message envelope.
//
// All Windows ↔ JarvisBrainDaemon traffic on /v1/windows/ws uses this
// structure. Internal Windows code still uses SidecarFrame; the bridge
// translates at the wire boundary so existing subscribers don't change.
//
// Matching the Android client contract so the daemon sees one message format
// regardless of which client it's talking to.
// ─────────────────────────────────────────────────────────────────────────────

/// <summary>
/// Canonical daemon gateway envelope. One JSON object per WebSocket text frame.
/// The <c>payload</c> field is type-specific JSON; consumers deserialize it based
/// on <c>type</c>.
/// </summary>
public sealed class GatewayMessage
{
    [JsonPropertyName("id")]             public string Id             { get; set; } = Guid.NewGuid().ToString("N");
    [JsonPropertyName("type")]           public string Type           { get; set; } = "";
    [JsonPropertyName("sourceDeviceId")] public string? SourceDeviceId { get; set; }
    [JsonPropertyName("sourcePlatform")] public string? SourcePlatform { get; set; }
    [JsonPropertyName("target")]         public string? Target         { get; set; }
    [JsonPropertyName("timestamp")]      public DateTimeOffset Timestamp { get; set; } = DateTimeOffset.UtcNow;
    [JsonPropertyName("seq")]            public long? Seq             { get; set; }
    [JsonPropertyName("replyTo")]        public string? ReplyTo       { get; set; }
    [JsonPropertyName("payload")]        public JsonElement? Payload  { get; set; }
}

/// <summary>
/// Canonical message type names shared across all daemon clients (Android, Mac app, Windows).
/// Internal Windows routing still uses <see cref="SidecarFrameTypes"/> constants; these are
/// the wire names the JarvisBrainDaemon gateway understands.
/// </summary>
public static class GatewayMessageTypes
{
    // ── Handshake / health ────────────────────────────────────────────────────
    public const string DeviceHello      = "device.hello";
    public const string Heartbeat        = "heartbeat";

    // ── Presence / state ──────────────────────────────────────────────────────
    public const string PresenceUpdate   = "presence.update";
    public const string CapabilityUpdate = "capability.update";

    // ── Transcript ────────────────────────────────────────────────────────────
    /// <summary>Windows STT final transcript → daemon → Mac app.</summary>
    public const string TranscriptFinal  = "transcript.final";

    // ── Reply ─────────────────────────────────────────────────────────────────
    /// <summary>Mac app streamed reply partial → daemon → Windows.</summary>
    public const string ReplyPartial     = "reply.partial";
    /// <summary>Mac app complete reply → daemon → Windows.</summary>
    public const string ReplyFinal       = "reply.final";

    // ── Execution ─────────────────────────────────────────────────────────────
    /// <summary>Mac app → daemon → Windows: run a Windows-local capability.</summary>
    public const string ExecutionRequest  = "execution.request";
    /// <summary>Windows → daemon → Mac app: capability executed successfully.</summary>
    public const string ExecutionResult   = "execution.result";
    /// <summary>Windows → daemon → Mac app: capability failed or unsupported.</summary>
    public const string ExecutionError    = "execution.error";
    /// <summary>Windows → daemon: progress during long execution (optional).</summary>
    public const string ExecutionProgress = "execution.progress";

    // ── Error / control ───────────────────────────────────────────────────────
    public const string ErrorReport = "error.report";
    public const string Ack         = "ack";
    public const string Nack        = "nack";

    // ── Replay markers (sent to daemon but not re-routed by it) ──────────────
    public const string ReplayBegin = "replay.begin";
    public const string ReplayEnd   = "replay.end";

    // ── Type mapping helpers (used by GatewayMessageTranslator) ──────────────

    /// <summary>Maps an internal <see cref="SidecarFrameTypes"/> type to the gateway wire type.
    /// Returns the input unchanged for types that are already canonical or have no mapping.</summary>
    public static string ToGatewayType(string sidecarType, string? outcome = null)
    {
        // ExecuteAck maps to result or error depending on the outcome.
        if (sidecarType == SidecarFrameTypes.ExecuteAck)
            return outcome == "Succeeded" ? ExecutionResult : ExecutionError;

        return sidecarType switch
        {
            SidecarFrameTypes.Hello             => DeviceHello,
            SidecarFrameTypes.Heartbeat         => Heartbeat,
            SidecarFrameTypes.TranscriptFinal   => TranscriptFinal,
            SidecarFrameTypes.TranscriptPartial => "transcript.partial",
            SidecarFrameTypes.Presence          => PresenceUpdate,
            SidecarFrameTypes.ReplayBegin       => ReplayBegin,
            SidecarFrameTypes.ReplayEnd         => ReplayEnd,
            // Types that pass through unchanged
            SidecarFrameTypes.State             => "state",
            SidecarFrameTypes.Context           => "context",
            SidecarFrameTypes.LeaseRequest      => "lease.request",
            SidecarFrameTypes.SpeakerActive     => "speaker.active",
            SidecarFrameTypes.SpeakerSilent     => "speaker.silent",
            _ => sidecarType
        };
    }

    /// <summary>Maps an inbound gateway wire type back to an internal <see cref="SidecarFrameTypes"/> type.</summary>
    public static string FromGatewayType(string gatewayType) => gatewayType switch
    {
        DeviceHello      => SidecarFrameTypes.Hello,
        Heartbeat        => SidecarFrameTypes.Heartbeat,
        ReplyPartial     => SidecarFrameTypes.ChatReplyPartial,
        ReplyFinal       => SidecarFrameTypes.ChatReplyFinal,
        ExecutionRequest => SidecarFrameTypes.ExecuteIntent,
        ExecutionResult  => SidecarFrameTypes.ExecuteAck,
        Ack              => SidecarFrameTypes.ExecuteAck,
        PresenceUpdate   => SidecarFrameTypes.Presence,
        _ => gatewayType   // unknown types pass through as-is
    };
}
