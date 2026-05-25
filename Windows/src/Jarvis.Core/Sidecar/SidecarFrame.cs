using System.Text.Json.Serialization;

namespace Jarvis.Core.Sidecar;

/// <summary>
/// Wire envelope for the Mac↔Windows bridge. One JSON object per WebSocket text frame.
/// All optional fields default to null so unknown senders/recipients see only the
/// discriminator and ignore the rest.
///
/// Direction (W → M = Windows-emitted, M → W = Mac-emitted):
///   hello (W)            initial handshake
///   heartbeat (W,M)      keepalive
///   state (W)            pebble + mic + speaker status
///   context (W)          compact desktop snapshot (only when hash changes)
///   transcript.partial / .final (W)  STT stream from Windows mic
///   lease.request (W)    Windows wants to speak
///   lease.grant (M)      Mac authorises Windows to speak
///   lease.revoke (M)     Mac reclaims speaker authority
///   speaker.active (M,W) provided when either side begins speaking
///   speaker.silent (M,W) provided when either side stops
///   execute.intent (M)   Mac asks Windows to perform an AutomationIntent
///   execute.ack (W)      Windows reports the AutomationOutcome
///   chat.reply.partial / .final (M)  Mac's streamed response text (drives chat panel)
///   tts.text (M)         Mac asks Windows to speak this exact line (lease must be held)
/// </summary>
public sealed class SidecarFrame
{
    [JsonPropertyName("type")] public string Type { get; set; } = "";
    [JsonPropertyName("id")] public string? Id { get; set; }

    // ─── Protocol v2 envelope ───────────────────────────────────────────────────────
    //
    // The Mac brain and any sidecar agree on a protocol version so old/new combos can
    // fail closed rather than misinterpret. Sequence numbers are per-direction and
    // monotonic; the receiver uses them for replay protection (drop seq <= last seen
    // for this direction) and to detect gaps after a reconnect.
    //
    // ReplyTo correlates response frames (chat.reply.*, execute.ack) with the request
    // that triggered them, without depending on session order. Optional; legacy frames
    // simply leave it null.

    [JsonPropertyName("protocolVersion")] public int? ProtocolVersion { get; set; }
    [JsonPropertyName("seq")] public long? Seq { get; set; }
    [JsonPropertyName("replyTo")] public string? ReplyTo { get; set; }

    // Handshake / health
    [JsonPropertyName("protocol")] public string? Protocol { get; set; }
    [JsonPropertyName("version")] public string? Version { get; set; }
    [JsonPropertyName("deviceId")] public string? DeviceId { get; set; }
    [JsonPropertyName("at")] public DateTimeOffset? At { get; set; }

    // State
    [JsonPropertyName("pebble")] public string? Pebble { get; set; }
    [JsonPropertyName("micOn")] public bool? MicOn { get; set; }
    [JsonPropertyName("speakerOn")] public bool? SpeakerOn { get; set; }
    [JsonPropertyName("degraded")] public bool? Degraded { get; set; }
    [JsonPropertyName("privacy")] public bool? Privacy { get; set; }

    // Transcript
    [JsonPropertyName("sessionId")] public string? SessionId { get; set; }
    [JsonPropertyName("text")] public string? Text { get; set; }
    [JsonPropertyName("confidence")] public double? Confidence { get; set; }
    [JsonPropertyName("isFinal")] public bool? IsFinal { get; set; }
    [JsonPropertyName("lang")] public string? Lang { get; set; }
    /// <summary>The local wake alias of the sidecar that produced this transcript
    /// (e.g. "Pebble" on Windows). Mac treats all aliases as the same assistant; the
    /// field is purely for attribution and analytics.</summary>
    [JsonPropertyName("wakeAlias")] public string? WakeAlias { get; set; }
    /// <summary>Friendly device name of the captor (e.g. "Office desktop"). Distinct
    /// from the microphone id — this names the *machine*, not the input device.</summary>
    [JsonPropertyName("captureDeviceId")] public string? CaptureDeviceId { get; set; }

    // Context (compact JSON-of-context — opaque to the bridge, parsed at the brain)
    [JsonPropertyName("snapshotHash")] public string? SnapshotHash { get; set; }
    [JsonPropertyName("context")] public ContextPayload? Context { get; set; }

    // Lease / speaker
    [JsonPropertyName("leaseToken")] public string? LeaseToken { get; set; }
    [JsonPropertyName("leaseExpiresAt")] public DateTimeOffset? LeaseExpiresAt { get; set; }
    [JsonPropertyName("source")] public string? Source { get; set; }   // "mac" | "windows"
    [JsonPropertyName("reason")] public string? Reason { get; set; }

    // Execute
    [JsonPropertyName("commandId")] public string? CommandId { get; set; }
    [JsonPropertyName("intentKind")] public string? IntentKind { get; set; }
    [JsonPropertyName("intentJson")] public string? IntentJson { get; set; }
    [JsonPropertyName("outcome")] public string? Outcome { get; set; }
    [JsonPropertyName("message")] public string? Message { get; set; }
}

/// <summary>Compact desktop snapshot pushed to the Mac. Mirrors <c>ConversationContext</c>
/// but as plain DTO so it serialises straight through.</summary>
public sealed class ContextPayload
{
    [JsonPropertyName("foregroundApp")] public string? ForegroundApp { get; set; }
    [JsonPropertyName("foregroundWindowTitle")] public string? ForegroundWindowTitle { get; set; }
    [JsonPropertyName("workflow")] public string? Workflow { get; set; }
    [JsonPropertyName("selectedText")] public string? SelectedText { get; set; }
    [JsonPropertyName("clipboard")] public string? Clipboard { get; set; }
    [JsonPropertyName("browserUrl")] public string? BrowserUrl { get; set; }
    [JsonPropertyName("browserTitle")] public string? BrowserTitle { get; set; }
    [JsonPropertyName("ideEditor")] public string? IdeEditor { get; set; }
    [JsonPropertyName("ideFile")] public string? IdeFile { get; set; }
    [JsonPropertyName("ideRepo")] public string? IdeRepo { get; set; }
    [JsonPropertyName("ideBranch")] public string? IdeBranch { get; set; }
    [JsonPropertyName("recentOcr")] public string? RecentOcr { get; set; }
    [JsonPropertyName("lastHighlighted")] public string? LastHighlighted { get; set; }

    // ─── P7 GlobalPresenceState additions ─────────────────────────────────────────
    /// <summary>Resolved attention mode (Idle/Ambient/Focused/Active).</summary>
    [JsonPropertyName("attentionMode")] public string? AttentionMode { get; set; }
    /// <summary>Presence intensity 0..1.</summary>
    [JsonPropertyName("attentionIntensity")] public double? AttentionIntensity { get; set; }
    /// <summary>Seconds since the user last interacted on this device.</summary>
    [JsonPropertyName("idleSeconds")] public double? IdleSeconds { get; set; }
    /// <summary>Recent TTS interruption count (last 30 s).</summary>
    [JsonPropertyName("recentInterruptions")] public int? RecentInterruptions { get; set; }

    // ─── Context engine additions ──────────────────────────────────────────────────
    /// <summary>Recent distinct foreground process names, newest first. Privacy-safe (no titles).</summary>
    [JsonPropertyName("recentApps")] public string[]? RecentApps { get; set; }
    /// <summary>Compact workflow timeline summary, e.g. "Coding(15m)→Browsing(3m)→Coding".</summary>
    [JsonPropertyName("timelineSummary")] public string? TimelineSummary { get; set; }

    // ─── Focus / presence additions ────────────────────────────────────────────────
    [JsonPropertyName("focusMinutes")] public double? FocusMinutes { get; set; }
    [JsonPropertyName("presenceMode")] public string? PresenceMode { get; set; }
    [JsonPropertyName("productivityScore")] public double? ProductivityScore { get; set; }
    [JsonPropertyName("appSwitchesLast10Min")] public int? AppSwitchesLast10Min { get; set; }
}

public static class SidecarFrameTypes
{
    public const string Hello             = "hello";
    public const string Heartbeat         = "heartbeat";
    public const string State             = "state";
    public const string Context           = "context";
    public const string TranscriptPartial = "transcript.partial";
    public const string TranscriptFinal   = "transcript.final";
    public const string LeaseRequest      = "lease.request";
    public const string LeaseGrant        = "lease.grant";
    public const string LeaseRevoke       = "lease.revoke";
    public const string SpeakerActive     = "speaker.active";
    public const string SpeakerSilent     = "speaker.silent";
    public const string ExecuteIntent     = "execute.intent";
    public const string ExecuteAck        = "execute.ack";
    public const string ChatReplyPartial  = "chat.reply.partial";
    public const string ChatReplyFinal    = "chat.reply.final";
    public const string TtsText           = "tts.text";

    // ─── P7 distributed-brain frames ────────────────────────────────────────────
    /// <summary>Mac → device: this device should suppress proactive speech.</summary>
    public const string OrchestrateSilent   = "orchestrate.silent";
    /// <summary>Mac → device: this device should speak the next reply (lease implied).</summary>
    public const string OrchestrateSpeak    = "orchestrate.speak";
    /// <summary>Mac → device: deliver a proactive notification (visual; speech only with lease).</summary>
    public const string ProactiveNotify     = "proactive.notify";
    /// <summary>Device → Mac: presence snapshot (attention/idle/workflow). Extends context payload.</summary>
    public const string Presence            = "presence";
    /// <summary>Device → Mac: replay marker — next frame is a queued one from the disconnect window.</summary>
    public const string ReplayBegin         = "replay.begin";
    public const string ReplayEnd           = "replay.end";
}

/// <summary>Current bridge protocol version. Both sides include this on every frame.
/// If the receiver sees a version > its own it logs and continues (forwards-compatible);
/// version &lt; its own is also accepted (backwards-compatible for now).</summary>
public static class SidecarProtocol
{
    public const int Version = 2;
}
