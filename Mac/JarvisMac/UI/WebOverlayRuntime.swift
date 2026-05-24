import SwiftUI
import WebKit

// MARK: - Bridge message types

/// Messages the web overlay can send to the native Swift layer.
enum WebBridgeInbound: String, CaseIterable {
    case closeOverlay   = "closeOverlay"
    case speakText      = "speakText"
    case requestContext = "requestContext"
    case requestNews    = "requestNews"
    case openURL        = "openURL"
}

// MARK: - WebOverlayBridge

/// Receives JavaScript messages from any WKWebView registered with it.
/// One instance is created by JarvisController and shared.
///
/// JS usage:
///   `window.jarvis.send("closeOverlay")`
///   `window.jarvis.send("speakText", {text: "Hello"})`
@Observable
@MainActor
final class WebOverlayBridge: NSObject, WKScriptMessageHandler {

    /// Called on main thread for every valid inbound message.
    var onMessage: ((WebBridgeInbound, [String: Any]?) -> Void)?

    // Diagnostics
    private(set) var totalMessageCount: Int = 0
    private(set) var lastMessageType: String = ""
    private(set) var lastError: String? = nil
    private(set) var activeWebViewCount: Int = 0

    func webViewDidOpen()  { activeWebViewCount += 1 }
    func webViewDidClose() { activeWebViewCount = max(0, activeWebViewCount - 1) }
    func recordError(_ msg: String) { lastError = msg }

    nonisolated func userContentController(_ ucc: WKUserContentController,
                                            didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let typeStr = body["type"] as? String else {
            Task { @MainActor [weak self] in
                self?.lastError = "Invalid bridge message: \(message.body)"
            }
            return
        }
        let payload = body["payload"] as? [String: Any]
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.totalMessageCount += 1
            self.lastMessageType = typeStr
            guard let type = WebBridgeInbound(rawValue: typeStr) else {
                self.lastError = "Unknown message type: \(typeStr)"
                return
            }
            self.onMessage?(type, payload)
        }
    }

    // MARK: - Outbound

    /// Sends a typed event to a specific web view.
    static func push(to webView: WKWebView, type: String, payload: [String: Any] = [:]) {
        guard let data = try? JSONSerialization.data(
                withJSONObject: ["type": type, "payload": payload], options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "if(typeof window.jarvisReceive==='function'){window.jarvisReceive(\(json));}"
        DispatchQueue.main.async { webView.evaluateJavaScript(js, completionHandler: nil) }
    }
}

// MARK: - EmbeddedWebView

/// General-purpose embedded WKWebView for overlay content.
///
/// Source can be:
///   - `.bundleHTML("overlay-name.html")` — loaded from `WebAssets/overlays/` in bundle
///   - `.remoteURL(URL)` — remote URL, only allowed when prefs permit
///   - `.inlineHTML(String)` — HTML string injected directly
///
/// On `dismantleNSView` stops all media and loads `about:blank` to
/// prevent lingering GPU/decoder processes.
struct EmbeddedWebView: NSViewRepresentable {

    enum Source: Equatable {
        case bundleHTML(String)
        case remoteURL(URL)
        case inlineHTML(String)
    }

    let source: Source
    var bridge: WebOverlayBridge?
    /// Optional container — when set the NSView is registered so the container
    /// can push typed events back to the page via `container.push(type:payload:)`.
    var container: WebOverlayContainer?
    var debugEnabled: Bool = false

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if let bridge {
            config.userContentController.add(
                BridgeProxy(bridge: bridge), name: "jarvis")
            config.userContentController.addUserScript(
                WKUserScript(source: Self.bridgeHelperJS,
                              injectionTime: .atDocumentStart,
                              forMainFrameOnly: false))
        }
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(true, forKey: "drawsBackground")
        wv.layer?.backgroundColor = NSColor(red: 0.03, green: 0.05,
                                             blue: 0.09, alpha: 1.0).cgColor
        if debugEnabled {
            wv.configuration.preferences.setValue(true,
                forKey: "developerExtrasEnabled")
        }
        wv.navigationDelegate = context.coordinator
        loadSource(source, into: wv)
        bridge?.webViewDidOpen()
        // Register with the container so push(type:payload:) can reach this view.
        container?.registerWebView(wv)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(function(m){m.pause();m.src='';m.load();});",
            completionHandler: nil)
        nsView.load(URLRequest(url: URL(string: "about:blank")!))
        coordinator.bridge?.webViewDidClose()
        coordinator.container?.unregisterWebView()
    }

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge, container: container) }

    // MARK: - Loading

    private func loadSource(_ source: Source, into wv: WKWebView) {
        switch source {
        case .bundleHTML(let name):
            if let url = Bundle.main.url(forResource: name, withExtension: nil,
                                          subdirectory: "WebAssets/overlays") {
                wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                wv.loadHTMLString(
                    "<html><body style='background:#050810;color:#ff4444;font-family:monospace;padding:20px'>"
                    + "WebAsset not found: \(name)</body></html>", baseURL: nil)
            }
        case .remoteURL(let url):
            // File URLs need loadFileURL to grant read-access to the parent directory.
            if url.isFileURL {
                wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                wv.load(URLRequest(url: url))
            }
        case .inlineHTML(let html):
            wv.loadHTMLString(html, baseURL: nil)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        let bridge: WebOverlayBridge?
        let container: WebOverlayContainer?
        init(bridge: WebOverlayBridge?, container: WebOverlayContainer?) {
            self.bridge = bridge
            self.container = container
        }

        func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url,
               action.navigationType == .linkActivated,
               !url.isFileURL, url.scheme != "about" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ wv: WKWebView, didFail _: WKNavigation!, withError err: Error) {
            Task { @MainActor [weak bridge, weak container] in
                let msg = "WebView nav failed: \(err.localizedDescription)"
                bridge?.recordError(msg)
                container?.markError(msg)
            }
        }

        func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
            Task { @MainActor [weak container] in
                container?.markLoaded(true)
            }
        }
    }

    // MARK: - Bridge proxy (allows nonisolated message handler to forward to @MainActor)

    private final class BridgeProxy: NSObject, WKScriptMessageHandler {
        let bridge: WebOverlayBridge
        init(bridge: WebOverlayBridge) { self.bridge = bridge }
        func userContentController(_ ucc: WKUserContentController,
                                    didReceive message: WKScriptMessage) {
            bridge.userContentController(ucc, didReceive: message)
        }
    }

    // MARK: - JS helper injected into every page

    /// Exposes `window.jarvis.send(type, payload?)` to web pages.
    static let bridgeHelperJS = """
    (function() {
      window.jarvis = {
        send: function(type, payload) {
          try {
            window.webkit.messageHandlers.jarvis.postMessage(
              { type: type, payload: payload || {} }
            );
          } catch(e) { console.warn('[Jarvis bridge] send failed:', e); }
        },
        close: function() { this.send('closeOverlay'); },
        speak: function(text) { this.send('speakText', { text: String(text) }); }
      };
      window.jarvisReceive = null;
    })();
    """
}

// MARK: - OverlayManifest

/// Decoded from `overlay.json` in each overlay bundle directory.
///
/// Example `overlay.json`:
/// ```json
/// {
///   "id": "news-overlay",
///   "name": "News",
///   "entry": "index.html",
///   "version": "1.0",
///   "renderMode": "hybrid",
///   "permissions": ["speak", "context", "news"]
/// }
/// ```
struct OverlayManifest: Codable {
    let id: String
    let name: String
    let entry: String
    let version: String?
    let renderMode: String?
    let permissions: [String]?

    /// Resolved `OverlayRenderType` from the `renderMode` string field.
    var resolvedRenderMode: OverlayRenderType {
        switch renderMode {
        case "webView": return .webView
        case "hybrid":  return .hybrid
        default:        return .nativeSwiftUI
        }
    }
}

// MARK: - WebOverlayLoader

/// Locates and loads web overlay assets from two sources (in priority order):
///   1. **User-installed**: `~/Library/Application Support/JarvisMac/WebOverlays/<id>/`
///   2. **Bundled**: `WebAssets/overlays/<id>/` inside the app bundle
///
/// Each overlay directory must contain an `overlay.json` manifest and an
/// HTML entry point named by `manifest.entry` (typically `index.html`).
enum WebOverlayLoader {

    /// Root directory for user-installed overlays.
    static var userOverlaysDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JarvisMac/WebOverlays", isDirectory: true)
    }

    /// Creates the user overlays directory if it doesn't exist.
    static func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: userOverlaysDirectory,
            withIntermediateDirectories: true,
            attributes: nil)
    }

    /// Returns an `EmbeddedWebView.Source` for the given overlay ID, or `nil`
    /// if no matching asset is found in either the user directory or bundle.
    static func source(for overlayId: String) -> EmbeddedWebView.Source? {
        // 1. User-installed overlay
        let userDir = userOverlaysDirectory.appendingPathComponent(overlayId)
        if let m = manifest(at: userDir) {
            let entryURL = userDir.appendingPathComponent(m.entry)
            if FileManager.default.fileExists(atPath: entryURL.path) {
                return .remoteURL(entryURL)   // file:// — EmbeddedWebView grants read-access
            }
        }
        // 2. Bundled overlay — WebAssets/overlays/<id>/index.html
        if let url = Bundle.main.url(forResource: "index",
                                      withExtension: "html",
                                      subdirectory: "WebAssets/overlays/\(overlayId)") {
            return .remoteURL(url)
        }
        // 3. Legacy single-file bundle asset
        if Bundle.main.url(forResource: overlayId, withExtension: "html",
                            subdirectory: "WebAssets/overlays") != nil {
            return .bundleHTML("\(overlayId).html")
        }
        return nil
    }

    /// Loads and decodes the manifest for the given overlay ID.
    static func manifest(for overlayId: String) -> OverlayManifest? {
        let userDir = userOverlaysDirectory.appendingPathComponent(overlayId)
        if let m = manifest(at: userDir) { return m }
        if let url = Bundle.main.url(forResource: "overlay",
                                      withExtension: "json",
                                      subdirectory: "WebAssets/overlays/\(overlayId)"),
           let data = try? Data(contentsOf: url) {
            return try? JSONDecoder().decode(OverlayManifest.self, from: data)
        }
        return nil
    }

    /// Returns manifests for all user-installed overlays.
    static func installedOverlays() -> [OverlayManifest] {
        ensureDirectoryExists()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: userOverlaysDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles)
        else { return [] }
        return contents.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            return manifest(at: url)
        }
    }

    // MARK: Private

    private static func manifest(at directory: URL) -> OverlayManifest? {
        let url = directory.appendingPathComponent("overlay.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OverlayManifest.self, from: data)
    }
}

// MARK: - WebOverlayContainer

/// Manages the lifecycle of a single web overlay — its source, bridge, and
/// a weak reference to the live WKWebView so callers can push typed events.
///
/// Created by `WebOverlayManager.open(kind:source:)`. The WKWebView reference
/// is registered by `EmbeddedWebView.makeNSView` and cleared on dismantleNSView.
@Observable
@MainActor
final class WebOverlayContainer: Identifiable {
    let id = UUID()
    let kind: OverlayKind
    let source: EmbeddedWebView.Source
    let bridge: WebOverlayBridge

    private(set) var isLoaded: Bool = false
    private(set) var lastError: String? = nil

    /// Weak reference to the live WKWebView — set by EmbeddedWebView.
    private weak var webView: WKWebView? = nil

    init(kind: OverlayKind,
         source: EmbeddedWebView.Source,
         bridge: WebOverlayBridge) {
        self.kind   = kind
        self.source = source
        self.bridge = bridge
    }

    // Called by EmbeddedWebView makeNSView / dismantleNSView
    func registerWebView(_ wv: WKWebView)  { webView = wv }
    func unregisterWebView()               { webView = nil }
    func markLoaded(_ v: Bool)             { isLoaded = v }
    func markError(_ e: String?)           { lastError = e }

    /// Push a typed event to the overlay's JavaScript layer.
    /// No-op if the WKWebView is not yet created or has been dismantled.
    func push(type: String, payload: [String: Any] = [:]) {
        guard let wv = webView else { return }
        WebOverlayBridge.push(to: wv, type: type, payload: payload)
    }
}

// MARK: - WebOverlayManager

/// Owns all active web overlay containers and routes bridge messages.
///
/// One instance is created by `JarvisController` and passed to views that
/// need to open/close managed web overlays.
///
/// Enforces one container per `OverlayKind` — opening the same kind twice
/// returns (and reuses) the existing container.
@Observable
@MainActor
final class WebOverlayManager {

    /// Shared WKScriptMessageHandler bridge. All web overlays managed by
    /// this instance share one bridge; messages are tagged by type so the
    /// handler can route them appropriately.
    let bridge: WebOverlayBridge

    private(set) var containers: [OverlayKind: WebOverlayContainer] = [:]

    /// Wired by JarvisController to receive inbound bridge messages.
    var onBridgeMessage: ((WebBridgeInbound, [String: Any]?) -> Void)?

    init() {
        let b = WebOverlayBridge()
        self.bridge = b
        b.onMessage = { [weak b] type, payload in
            // Forward diagnostics update is handled externally via onBridgeMessage.
            _ = b   // suppress unused capture warning
        }
        // Override onMessage to also invoke the external handler.
        b.onMessage = { [weak self] type, payload in
            self?.onBridgeMessage?(type, payload)
        }
    }

    // MARK: Container lifecycle

    /// Opens (or reuses) a web overlay container for the given kind.
    /// Returns the container — new or existing.
    @discardableResult
    func open(kind: OverlayKind, source: EmbeddedWebView.Source) -> WebOverlayContainer {
        if let existing = containers[kind] { return existing }
        let container = WebOverlayContainer(kind: kind, source: source, bridge: bridge)
        containers[kind] = container
        Log.ui.info("webOverlay open: \(kind.rawValue)")
        return container
    }

    /// Closes and removes the container for `kind`.
    func close(kind: OverlayKind) {
        containers.removeValue(forKey: kind)
        Log.ui.info("webOverlay close: \(kind.rawValue)")
    }

    /// Returns the active container for `kind`, or `nil` if none is open.
    func container(for kind: OverlayKind) -> WebOverlayContainer? {
        containers[kind]
    }

    // MARK: Push helpers

    /// Push a typed event to a specific overlay's JavaScript layer.
    func push(to kind: OverlayKind, type: String, payload: [String: Any] = [:]) {
        containers[kind]?.push(type: type, payload: payload)
    }

    // MARK: Diagnostics

    var activeCount: Int            { containers.count }
    var totalBridgeMessages: Int    { bridge.totalMessageCount }
    var bridgeLastMessage: String   { bridge.lastMessageType }
    var bridgeLastError: String?    { bridge.lastError }
    var bridgeActiveWebViews: Int   { bridge.activeWebViewCount }
}

// MARK: - WebOverlayHost

/// SwiftUI view that renders a managed web overlay from `WebOverlayManager`.
///
/// If no container is open for `kind`, shows a placeholder. The container
/// is NOT automatically created here — the caller must call
/// `manager.open(kind:source:)` before presenting this view.
///
/// The view passes the container to `EmbeddedWebView` so the container's
/// `push(type:payload:)` method is wired up on first render.
struct WebOverlayHost: View {
    let kind: OverlayKind
    let manager: WebOverlayManager
    var debugEnabled: Bool = false

    var body: some View {
        if let container = manager.container(for: kind) {
            EmbeddedWebView(
                source: container.source,
                bridge: container.bridge,
                container: container,
                debugEnabled: debugEnabled
            )
        } else {
            noContentPlaceholder
        }
    }

    private var noContentPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No web content")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(kind.rawValue)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
