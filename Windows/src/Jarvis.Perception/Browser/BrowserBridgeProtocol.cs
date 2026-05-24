using System.Text.Json.Serialization;

namespace Jarvis.Perception.Browser;

/// <summary>
/// Wire contract between Jarvis (host) and the Chrome/Edge extension. JSON over a
/// loopback WebSocket. Forward-compatible: unknown fields are ignored, new optional
/// fields default to null.
///
/// Direction is extension → host only (P2.5). The host never pushes commands back.
/// </summary>
public sealed class BrowserBridgeMessage
{
    /// <summary>Discriminator: "hello", "context", "ping". Lowercased.</summary>
    [JsonPropertyName("type")]
    public string Type { get; set; } = "";

    /// <summary>Extension identifier (chrome, edge, brave, …) — sent on "hello".</summary>
    [JsonPropertyName("browser")]
    public string? Browser { get; set; }

    /// <summary>Extension build/version string — sent on "hello".</summary>
    [JsonPropertyName("version")]
    public string? Version { get; set; }

    [JsonPropertyName("url")]
    public string? Url { get; set; }

    [JsonPropertyName("domain")]
    public string? Domain { get; set; }

    [JsonPropertyName("title")]
    public string? Title { get; set; }

    [JsonPropertyName("selectedText")]
    public string? SelectedText { get; set; }

    [JsonPropertyName("focusedElementRole")]
    public string? FocusedElementRole { get; set; }

    [JsonPropertyName("isTextInputFocused")]
    public bool? IsTextInputFocused { get; set; }

    // ── ACK fields (extension → host) ───────────────────────────────────────

    [JsonPropertyName("commandId")] public string? CommandId { get; set; }
    [JsonPropertyName("accepted")] public bool? Accepted { get; set; }
    [JsonPropertyName("completed")] public bool? Completed { get; set; }
    [JsonPropertyName("error")] public string? Error { get; set; }
    [JsonPropertyName("resultingUrl")] public string? ResultingUrl { get; set; }
    [JsonPropertyName("resultingTitle")] public string? ResultingTitle { get; set; }
    [JsonPropertyName("matches")] public int? Matches { get; set; }
    [JsonPropertyName("sample")] public string? Sample { get; set; }

    [JsonPropertyName("targets")] public List<BrowserDomTargetWire>? Targets { get; set; }
    [JsonPropertyName("viewport")] public BrowserViewportWire? Viewport { get; set; }
}

public sealed class BrowserViewportWire
{
    [JsonPropertyName("screenX")] public int ScreenX { get; set; }
    [JsonPropertyName("screenY")] public int ScreenY { get; set; }
    [JsonPropertyName("width")] public int Width { get; set; }
    [JsonPropertyName("height")] public int Height { get; set; }
    [JsonPropertyName("dpr")] public double DevicePixelRatio { get; set; } = 1.0;
    [JsonPropertyName("scrollX")] public int ScrollX { get; set; }
    [JsonPropertyName("scrollY")] public int ScrollY { get; set; }
}

/// <summary>Wire shape for one DOM target. Translated to the Core
/// <see cref="Jarvis.Core.Automation.BrowserDomTarget"/> record by the bridge.</summary>
public sealed class BrowserDomTargetWire
{
    [JsonPropertyName("label")]    public string? Label { get; set; }
    [JsonPropertyName("role")]     public string? Role { get; set; }
    [JsonPropertyName("selector")] public string? Selector { get; set; }
    [JsonPropertyName("x")]        public double X { get; set; }
    [JsonPropertyName("y")]        public double Y { get; set; }
    [JsonPropertyName("width")]    public double Width { get; set; }
    [JsonPropertyName("height")]   public double Height { get; set; }
    [JsonPropertyName("visible")]  public bool Visible { get; set; }
    [JsonPropertyName("enabled")]  public bool Enabled { get; set; }
}
