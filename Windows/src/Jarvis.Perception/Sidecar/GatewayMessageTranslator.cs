using System.Text.Json;
using System.Text.Json.Serialization;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Translates between <see cref="SidecarFrame"/> (internal Windows contract) and
/// <see cref="GatewayMessage"/> (daemon wire format). All mapping lives here so the
/// rest of the codebase stays unaware of the canonical gateway envelope.
///
/// Outbound: SidecarFrame → GatewayMessage  (called by MacBridgeCoordinator send path)
/// Inbound:  GatewayMessage → SidecarFrame  (called by MacBridgeCoordinator receive path)
/// </summary>
internal static class GatewayMessageTranslator
{
    private static readonly JsonSerializerOptions Opts = new()
    {
        PropertyNamingPolicy    = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition  = JsonIgnoreCondition.WhenWritingNull
    };

    // ── Outbound ──────────────────────────────────────────────────────────────

    public static GatewayMessage ToGateway(SidecarFrame frame, string deviceId)
    {
        var gatewayType = GatewayMessageTypes.ToGatewayType(frame.Type, frame.Outcome);
        var msg = new GatewayMessage
        {
            Id             = frame.Id ?? Guid.NewGuid().ToString("N"),
            Type           = gatewayType,
            SourceDeviceId = frame.DeviceId ?? deviceId,
            SourcePlatform = "windows",
            Target         = DetermineTarget(gatewayType),
            Timestamp      = frame.At ?? DateTimeOffset.UtcNow,
            Seq            = frame.Seq,
            ReplyTo        = frame.ReplyTo
        };

        var payload = BuildOutboundPayload(frame, gatewayType, deviceId);
        if (payload is not null)
            msg.Payload = JsonSerializer.SerializeToElement(payload, Opts);

        return msg;
    }

    // ── Inbound ───────────────────────────────────────────────────────────────

    public static SidecarFrame FromGateway(GatewayMessage msg)
    {
        var internalType = GatewayMessageTypes.FromGatewayType(msg.Type);
        var frame = new SidecarFrame
        {
            Type     = internalType,
            Id       = msg.Id,
            At       = msg.Timestamp,
            Seq      = msg.Seq,
            ReplyTo  = msg.ReplyTo,
            DeviceId = msg.SourceDeviceId
        };

        if (msg.Payload.HasValue)
            UnpackInboundPayload(frame, msg.Type, msg.Payload.Value);

        return frame;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static string DetermineTarget(string gatewayType) => gatewayType switch
    {
        GatewayMessageTypes.DeviceHello      => "daemon",
        GatewayMessageTypes.Heartbeat        => "daemon",
        GatewayMessageTypes.PresenceUpdate   => "daemon",
        GatewayMessageTypes.CapabilityUpdate => "daemon",
        GatewayMessageTypes.ReplayBegin      => "daemon",
        GatewayMessageTypes.ReplayEnd        => "daemon",
        _                                    => "macApp"
    };

    private static object? BuildOutboundPayload(SidecarFrame frame, string gatewayType, string deviceId)
    {
        switch (gatewayType)
        {
            case GatewayMessageTypes.DeviceHello:
                return new
                {
                    deviceName   = frame.DeviceId ?? deviceId,
                    appVersion   = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "1.0.0",
                    capabilities = WindowsCapabilities.Enabled
                };

            case GatewayMessageTypes.TranscriptFinal:
            case "transcript.partial":
                return new
                {
                    text            = frame.Text,
                    origin          = "windows",
                    locale          = frame.Lang ?? "en-GB",
                    confidence      = frame.Confidence,
                    sessionId       = frame.SessionId,
                    wakeAlias       = frame.WakeAlias,
                    captureDeviceId = frame.CaptureDeviceId
                };

            case GatewayMessageTypes.Heartbeat:
                return new { at = (frame.At ?? DateTimeOffset.UtcNow).ToString("O") };

            case GatewayMessageTypes.PresenceUpdate:
                var ctx = frame.Context;
                if (ctx is null) return null;
                return new
                {
                    attentionMode      = ctx.AttentionMode,
                    attentionIntensity = ctx.AttentionIntensity,
                    idleSeconds        = ctx.IdleSeconds,
                    foregroundApp      = ctx.ForegroundApp,
                    workflow           = ctx.Workflow
                };

            case GatewayMessageTypes.ExecutionResult:
                return new
                {
                    commandId = frame.CommandId,
                    success   = true,
                    command   = frame.IntentKind,
                    result    = frame.Message
                };

            case GatewayMessageTypes.ExecutionError:
                return new
                {
                    commandId = frame.CommandId,
                    success   = false,
                    command   = frame.IntentKind,
                    error     = frame.Message ?? frame.Outcome
                };

            case GatewayMessageTypes.CapabilityUpdate:
                return new { capabilities = WindowsCapabilities.Enabled };

            default:
                return null;
        }
    }

    private static void UnpackInboundPayload(SidecarFrame frame, string gatewayType, JsonElement payload)
    {
        static string? Str(JsonElement e, string key) =>
            e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

        switch (gatewayType)
        {
            case GatewayMessageTypes.ReplyPartial:
            case GatewayMessageTypes.ReplyFinal:
                frame.Text      = Str(payload, "text");
                frame.SessionId = Str(payload, "sessionId") ?? Str(payload, "replyTo");
                break;

            case GatewayMessageTypes.ExecutionRequest:
                frame.CommandId  = Str(payload, "commandId") ?? Str(payload, "id") ?? frame.Id;
                frame.IntentKind = Str(payload, "command") ?? Str(payload, "capability");
                frame.IntentJson = payload.GetRawText();
                break;

            case GatewayMessageTypes.Nack:
                frame.Reason  = Str(payload, "reason");
                frame.Message = Str(payload, "message");
                break;

            case GatewayMessageTypes.Heartbeat:
                // Timestamp already set from msg.Timestamp in FromGateway.
                break;

            case GatewayMessageTypes.PresenceUpdate:
                // Inbound presence from another device — preserved as-is in the frame.
                break;
        }
    }

    // ── Factory helpers for internal-only messages ────────────────────────────

    /// <summary>Build the capability.update GatewayMessage sent after hello.</summary>
    public static GatewayMessage BuildCapabilityUpdate(string deviceId) => new()
    {
        Type           = GatewayMessageTypes.CapabilityUpdate,
        SourceDeviceId = deviceId,
        SourcePlatform = "windows",
        Target         = "daemon",
        Timestamp      = DateTimeOffset.UtcNow,
        Payload        = JsonSerializer.SerializeToElement(new { capabilities = WindowsCapabilities.Enabled }, Opts)
    };
}
