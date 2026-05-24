namespace Jarvis.Core.Settings;

public interface IJarvisSettingsStore
{
    JarvisSettings Current { get; }
    event EventHandler<JarvisSettings>? Changed;
    Task LoadAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(JarvisSettings settings, CancellationToken cancellationToken = default);
}

public sealed record JarvisSettings
{
    public PebbleSettings Pebble { get; init; } = new();
    public OverlaySettings Overlay { get; init; } = new();
    public AwarenessSettings Awareness { get; init; } = new();
    public PerformanceSettings Performance { get; init; } = new();
    public HotkeySettings Hotkeys { get; init; } = new();
    public LlmSettings Llm { get; init; } = new();
    public RedactionSettings Redaction { get; init; } = new();
    public QuotaSettings Quota { get; init; } = new();
    public SidecarSettings Sidecar { get; init; } = new();
    public MouseChordSettings MouseChord { get; init; } = new();
    /// <summary>Daemon gateway config. Pairing-code flow stores the session token here.
    /// When <see cref="BrainGatewayConfig.BaseUrl"/> is non-empty the bridge connects to
    /// /v1/windows/ws; when empty the bridge stays Disabled.</summary>
    public BrainGatewayConfig Gateway { get; init; } = new();

    public static JarvisSettings Defaults => new();
}

public sealed record QuotaSettings
{
    public bool Enabled { get; init; } = true;
    public int MaxRequestsPerDay { get; init; } = 200;
    public int MaxApproxCharsPerDay { get; init; } = 500_000;
    /// <summary>When true, the Echo stub and Ollama (local) don't count against the budget.</summary>
    public bool ExemptLocalProviders { get; init; } = true;
}

/// <summary>
/// Configures the left+right mouse-button chord that opens the Pebble Interaction Menu.
/// Pure additive — the detector never consumes normal clicks.
/// </summary>
public sealed record MouseChordSettings
{
    /// <summary>Master switch. When false the low-level hook is never installed.</summary>
    public bool EnableMouseChordMenu { get; init; } = true;
}

public enum SpeakerAuthorityPreference
{
    /// <summary>Mac is the speaker by default; Windows is silent unless granted a lease.</summary>
    Mac,
    /// <summary>Windows is the speaker by default; Mac informed via bridge.</summary>
    Windows
}

/// <summary>
/// Configuration for the Mac sidecar bridge. The Mac is the brain; Windows connects
/// via the pairing-code flow — users never enter or copy a bearer token.
/// Connection is always gateway-protocol-only (BrainGatewayConfig.BaseUrl + SessionToken).
/// </summary>
public sealed record SidecarSettings
{
    /// <summary>When false the bridge never starts — Windows runs as a fully standalone
    /// runtime using its local LLM provider (P5.5+ behaviour).</summary>
    public bool Enabled { get; init; } = false;

    // NOTE: BridgeUrl and BridgeToken (legacy bearer-token fields) have been removed.
    // Connection is now exclusively through BrainGatewayConfig (pairing-code flow).
    // Old JSON files that still contain these fields are silently ignored by the
    // JSON deserializer (unknown properties are discarded).

    public bool AutoReconnect { get; init; } = true;

    public bool WakeWordEnabled { get; init; } = true;
    /// <summary>Legacy field — used only as a fallback when <see cref="LocalWakeAlias"/>
    /// is empty. New code reads <see cref="EffectiveWakeAlias"/> instead.</summary>
    public string WakeWord { get; init; } = "jarvis";

    // ─── Wake-word aliasing (P6.5 follow-up) ────────────────────────────────────────
    //
    // A wake word identifies the *capture device*, not the assistant identity. Two
    // nearby sidecars listening for the same word would double-wake; each sidecar gets
    // its own local alias instead. Mac brain treats all aliases as Jarvis requests and
    // routes them to one conversation — wake aliases never fork the personality, memory
    // or session.

    /// <summary>Friendly name of this device — sent on every transcript frame so the Mac
    /// can attribute who captured what (e.g. "Office desktop", "Studio laptop").</summary>
    public string DeviceName { get; init; } = "Windows";

    /// <summary>Display name of the central assistant identity. The Mac is authoritative
    /// for the actual persona — this is shown in local UI only. Keep it the same across
    /// devices to reinforce single-identity feel.</summary>
    public string AssistantIdentityName { get; init; } = "Jarvis";

    /// <summary>The local wake alias for this device. Defaults to "Pebble" on Windows so
    /// nearby Mac brain still answering to "Jarvis" doesn't double-wake. Each sidecar
    /// should pick a distinct alias.</summary>
    public string LocalWakeAlias { get; init; } = "Pebble";

    /// <summary>Master switch for the alias system. When off, falls back to the legacy
    /// <see cref="WakeWord"/> field.</summary>
    public bool WakeAliasEnabled { get; init; } = true;

    /// <summary>Resolved wake phrase used by the recognizer. Honours the alias toggle and
    /// falls back to <see cref="WakeWord"/> if the alias is empty.</summary>
    public string EffectiveWakeAlias =>
        WakeAliasEnabled && !string.IsNullOrWhiteSpace(LocalWakeAlias) ? LocalWakeAlias
        : !string.IsNullOrWhiteSpace(WakeWord) ? WakeWord
        : "jarvis";

    /// <summary>True if the local alias collides with the assistant identity name. When
    /// nearby devices share an identity, listening on the same word is what causes the
    /// double-wake symptom — diagnostics warn on this at startup.</summary>
    public bool HasAliasCollision =>
        WakeAliasEnabled
        && !string.IsNullOrWhiteSpace(LocalWakeAlias)
        && !string.IsNullOrWhiteSpace(AssistantIdentityName)
        && string.Equals(LocalWakeAlias.Trim(), AssistantIdentityName.Trim(), StringComparison.OrdinalIgnoreCase);

    public string? MicrophoneId { get; init; }
    public string? SpeakerId { get; init; }

    /// <summary>When true, Windows can speak responses *but only when the Mac grants
    /// a TTS lease*. Set to false on shared-room setups where only the Mac should speak.</summary>
    public bool LocalTtsEnabled { get; init; } = true;

    public SpeakerAuthorityPreference PreferredSpeakerAuthority { get; init; } = SpeakerAuthorityPreference.Mac;

    /// <summary>When the bridge is down, Windows falls back to its local LLM provider
    /// (P5.5 stack) for short replies. Turn off for "Mac or silence".</summary>
    public bool OfflineDegradedModeEnabled { get; init; } = true;

    /// <summary>Suppress mic + context push when on. The pebble shows muted.</summary>
    public bool PrivacyMode { get; init; } = false;

    /// <summary>0..1 — higher rejects more "is the speaker hearing themselves" cases.</summary>
    public double EchoSuppressionStrength { get; init; } = 0.7;

    /// <summary>0..1 — energy threshold for VAD. Tunable per microphone.</summary>
    public double VadSensitivity { get; init; } = 0.5;
}

public sealed record PebbleSettings
{
    public int Size { get; init; } = 32;
    public double Opacity { get; init; } = 0.92;
    public bool AnimationsEnabled { get; init; } = true;
    public bool FollowCursor { get; init; } = true;
    /// <summary>DIPs of offset from the cursor to the window's top-left; positive X = right,
    /// positive Y = down. Small values feel tethered; the pebble core sits roughly
    /// (Size × 0.75) DIPs from the cursor after window padding + SVG centring.</summary>
    public int CursorOffsetX { get; init; } = 4;
    public int CursorOffsetY { get; init; } = 4;
    /// <summary>0..1 ease toward the cursor each frame; lower = smoother trail.</summary>
    public double FollowEasing { get; init; } = 0.18;
    /// <summary>When on, the cursor follower emits a diagnostics line per second with
    /// cursor / target / scale / ease-delta — used to debug anchor drift.</summary>
    public bool AnchorDebug { get; init; } = false;
}

public sealed record OverlaySettings
{
    public bool ClickThrough { get; init; } = true;
    public bool AlwaysOnTop { get; init; } = true;
    public int? PreferredMonitorIndex { get; init; }
    /// <summary>Cap the overlay refresh; 0 = uncapped (match display).</summary>
    public int TargetFps { get; init; } = 120;
}

public sealed record AwarenessSettings
{
    /// <summary>Foreground-window polling interval. Win32 has no cheap signal for window-title changes,
    /// so we poll. 250ms is the sweet spot: imperceptible to humans, &lt;0.1% CPU.</summary>
    public int PollIntervalMs { get; init; } = 250;
    public int IdleThresholdSeconds { get; init; } = 45;
    public bool TrackForegroundApp { get; init; } = true;
    public bool TrackIdle { get; init; } = true;
}

public sealed record PerformanceSettings
{
    public bool GpuAcceleration { get; init; } = true;
    public bool ReducedMotion { get; init; } = false;
    /// <summary>Drop animation work when battery saver is on.</summary>
    public bool RespectBatterySaver { get; init; } = true;
}

public sealed record HotkeySettings
{
    public string PushToTalk { get; init; } = "Ctrl+Space";
    public string ToggleMute { get; init; } = "Ctrl+Shift+M";
    public string ToggleVisibility { get; init; } = "Ctrl+Shift+J";
}

public enum LlmProviderType
{
    /// <summary>No real provider — falls back to the echo stub.</summary>
    None,
    /// <summary>OpenAI Chat Completions API (and any OpenAI-compatible endpoint).</summary>
    OpenAi,
    /// <summary>Ollama /api/chat — local-model server.</summary>
    Ollama,
    /// <summary>MiniMax — OpenAI-compatible chat completions at api.minimax.io.</summary>
    MiniMax
}

public sealed record LlmSettings
{
    public LlmProviderType Provider { get; init; } = LlmProviderType.None;
    /// <summary>Bearer API key. OpenAI / MiniMax send as Authorization: Bearer; Ollama needs none.</summary>
    public string? ApiKey { get; init; }
    /// <summary>Override the provider's default base URL (used for self-hosted OpenAI-compatible servers).</summary>
    public string? BaseUrl { get; init; }
    public string Model { get; init; } = "";
    public double Temperature { get; init; } = 0.4;
    public int MaxTokens { get; init; } = 1024;
    public bool Stream { get; init; } = true;
    public int TimeoutSeconds { get; init; } = 60;
    /// <summary>When false, the context block is suppressed entirely — useful for paranoid users on cloud providers.</summary>
    public bool ContextInjectionEnabled { get; init; } = true;
}

public sealed record RedactionSettings
{
    public bool Enabled { get; init; } = true;
    public bool RedactEmails { get; init; } = true;
    public bool RedactPhones { get; init; } = true;
    public bool RedactFilePaths { get; init; } = false;
    public int MaxSelectedTextChars { get; init; } = 2_000;
    public int MaxClipboardChars { get; init; } = 500;
    public int MaxOcrChars { get; init; } = 1_500;
    /// <summary>When true, the conversation diagnostics record a hashed preview of what was redacted.</summary>
    public bool ShowRedactedPreviewInDiagnostics { get; init; } = true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Daemon Gateway Config
//
// Windows connects to JarvisBrainDaemon via one place: BaseUrl (port 8765).
// No bearer token UI — authentication is handled via the pairing-code flow.
// The WebSocket URL is derived as {ws|wss}://{host}/v1/windows/ws.
// ─────────────────────────────────────────────────────────────────────────────

/// <summary>
/// Single source of truth for the Mac Brain Gateway connection.
/// When <see cref="BaseUrl"/> is non-empty and <see cref="SessionToken"/> is set
/// (obtained via pairing-code exchange), the bridge connects to /v1/windows/ws.
/// When BaseUrl is empty the bridge stays Disabled; when BaseUrl is set but no
/// SessionToken the bridge transitions to PairingRequired.
/// </summary>
public sealed record BrainGatewayConfig
{
    /// <summary>HTTP base URL of the Mac Brain Gateway, e.g. <c>http://100.64.1.5:8765</c>
    /// or <c>http://mac.tail-xxxxx.ts.net:8765</c>. Must NOT include a path.</summary>
    public string BaseUrl { get; init; } = "";

    /// <summary>Stable device identifier for this Windows install. Defaults to machine
    /// name on first run; never changes after pairing.</summary>
    public string DeviceId { get; init; } = "";

    /// <summary>Human-readable device name sent in hello + capability frames.</summary>
    public string DeviceName { get; init; } = "";

    /// <summary>Session token received after successful pairing via POST /v1/windows/pair.
    /// Encrypted at rest (DPAPI). Never log the full token.</summary>
    public string? SessionToken { get; init; }

    /// <summary>True once a successful pair has completed and a valid session token exists.</summary>
    public bool Paired { get; init; }

    /// <summary>UTC timestamp of the most recent successful WebSocket connection.</summary>
    public DateTimeOffset? LastConnectedAt { get; init; }

    // ── Derived helpers ────────────────────────────────────────────────────────

    /// <summary>WebSocket URL derived from <see cref="BaseUrl"/>. Returns null when
    /// <see cref="BaseUrl"/> is empty or unparseable.</summary>
    public string? DeriveWebSocketUrl()
    {
        if (string.IsNullOrWhiteSpace(BaseUrl)) return null;
        if (!Uri.TryCreate(BaseUrl, UriKind.Absolute, out var u)) return null;
        var wsScheme = u.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) ? "wss" : "ws";
        var port = u.IsDefaultPort ? string.Empty : $":{u.Port}";
        return $"{wsScheme}://{u.Host}{port}/v1/windows/ws";
    }

    /// <summary>HTTP pairing URL: <see cref="BaseUrl"/> + /v1/windows/pair.</summary>
    public string? DerivePairingUrl() =>
        string.IsNullOrWhiteSpace(BaseUrl) ? null
        : $"{BaseUrl.TrimEnd('/')}/v1/windows/pair";

    /// <summary>HTTP health URL: <see cref="BaseUrl"/> + /brain/health.</summary>
    public string? DeriveHealthUrl() =>
        string.IsNullOrWhiteSpace(BaseUrl) ? null
        : $"{BaseUrl.TrimEnd('/')}/brain/health";
}
