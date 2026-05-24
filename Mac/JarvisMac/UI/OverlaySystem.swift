import SwiftUI
import AVFoundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - OverlayRenderType

/// Describes how an overlay's content is rendered.
/// Used by OverlayManager and JarvisController for bridge routing and
/// future hybrid-mode overlay support.
enum OverlayRenderType {
    /// Content is pure SwiftUI — default for most panels.
    case nativeSwiftUI
    /// Content is fully rendered by a WKWebView (e.g. article viewer).
    case webView
    /// Native lifecycle and chrome (title bar, open/close); content panel
    /// can be SwiftUI or WKWebView depending on whether a web asset is installed.
    case hybrid
}

// MARK: - OverlayKind

enum OverlayKind: String, Equatable, CaseIterable, Codable {
    case test            // status / debug overlay
    case memory          // long-term memory browser
    case screen          // screen awareness / OCR results
    case camera          // webcam awareness — cinematic fullscreen popup
    case chat            // conversation history + typed input
    case timeline        // activity timeline
    case reasoning       // intent reasoning / debug
    case news            // news/RSS feed browser + live channel
    case article         // in-app web view of a single article URL
    case notifications   // proactivity notification tray
    case proactiveAlert  // generic fallback for sources without a dedicated overlay
    case calendar        // Today's events timeline
    case tasks           // Todoist task list
    case github          // GitHub notifications overlay
    case home            // Smart home entity grid
    case shopify         // Shopify orders / revenue dashboard
    case obsidian        // Obsidian vault browser + note viewer
    case androidBridge   // Android bridge diagnostics + status
    case phone           // Active call UI: answer / decline / hang-up / speaker
    case help            // Living-documentation help overlay
    case reddit          // Reddit feed / subreddit / post / comments browser
    case brain               // Brain long-term memory browser + episode viewer
    case ambientContext       // AmbientContextEngine debug / developer overlay
    case runtimeDiagnostics  // RuntimeCoordinator subsystem health + EventStore
    case spatialHUD          // in-app hand-gesture spatial interaction panel
    case haCamera            // Home Assistant camera snapshot viewer
    case haAllCameras        // Grid of all HA cameras
    case haDiagnostics       // Home Assistant integration diagnostics
    case surveillance        // POI visual intelligence dashboard
    case pingPong            // hand-tracked ping pong game

    var title: String {
        switch self {
        case .test:            return "Status"
        case .help:            return "Help"
        case .memory:          return "Memory"
        case .screen:          return "Screen"
        case .camera:          return "Camera"
        case .chat:            return "Chat"
        case .timeline:        return "Timeline"
        case .reasoning:       return "Reasoning"
        case .news:            return "News"
        case .article:         return "Article"
        case .notifications:   return "Notifications"
        case .proactiveAlert:  return "Alert"
        case .calendar:        return "Calendar"
        case .tasks:           return "Tasks"
        case .github:          return "GitHub"
        case .home:            return "Home"
        case .shopify:         return "Shopify"
        case .obsidian:        return "Obsidian"
        case .androidBridge:   return "Android"
        case .phone:           return "Phone"
        case .reddit:          return "Reddit"
        case .brain:                return "Brain"
        case .ambientContext:       return "Ambient"
        case .runtimeDiagnostics:  return "Runtime"
        case .spatialHUD:           return "Spatial"
        case .haCamera:             return "Camera"
        case .haAllCameras:         return "Cameras"
        case .haDiagnostics:        return "HA Diagnostics"
        case .surveillance:         return "Surveillance"
        case .pingPong:             return "Ping Pong"
        }
    }
    var systemImage: String {
        switch self {
        case .test:            return "info.circle.fill"
        case .help:            return "questionmark.circle.fill"
        case .memory:          return "brain.head.profile"
        case .screen:          return "display"
        case .camera:          return "camera.fill"
        case .chat:            return "bubble.left.and.bubble.right.fill"
        case .timeline:        return "clock.arrow.circlepath"
        case .reasoning:       return "questionmark.bubble.fill"
        case .news:            return "newspaper.fill"
        case .article:         return "doc.text.fill"
        case .notifications:   return "bell.fill"
        case .proactiveAlert:  return "bell.badge.fill"
        case .calendar:        return "calendar"
        case .tasks:           return "checkmark.circle.fill"
        case .github:          return "chevron.left.forwardslash.chevron.right"
        case .home:            return "house.fill"
        case .shopify:         return "bag.fill"
        case .obsidian:        return "note.text"
        case .androidBridge:   return "antenna.radiowaves.left.and.right"
        case .phone:           return "phone.fill"
        case .reddit:          return "bubble.left.and.text.bubble.right"
        case .brain:                return "brain"
        case .ambientContext:       return "eye.circle.fill"
        case .runtimeDiagnostics:  return "cpu.fill"
        case .spatialHUD:           return "hand.raised.fill"
        case .haCamera:             return "camera.fill"
        case .haAllCameras:         return "camera.on.rectangle.fill"
        case .haDiagnostics:        return "house.circle.fill"
        case .surveillance:         return "eye.trianglebadge.exclamationmark"
        case .pingPong:             return "gamecontroller.fill"
        }
    }
    var defaultSize: OverlaySize {
        switch self {
        case .test:            return .compact
        case .help:            return .large
        case .memory:          return .medium
        case .screen:          return .medium
        case .camera:          return .cinema
        case .chat:            return .large
        case .timeline:        return .large
        case .reasoning:       return .medium
        case .news:            return .large
        case .article:         return .large
        case .notifications:   return .medium
        case .proactiveAlert:  return .compact
        case .calendar:        return .large
        case .tasks:           return .large
        case .github:          return .large
        case .home:            return .large
        case .shopify:         return .large
        case .obsidian:        return .large
        case .androidBridge:   return .medium
        case .phone:           return .medium
        case .reddit:          return .large
        case .brain:                return .large
        case .ambientContext:       return .compact
        case .runtimeDiagnostics:  return .medium
        case .spatialHUD:           return .large
        case .haCamera:             return .large
        case .haAllCameras:         return .large
        case .haDiagnostics:        return .medium
        case .surveillance:         return .large
        case .pingPong:             return .cinema
        }
    }
    var accentColor: Color {
        switch self {
        case .test:            return .purple
        case .help:            return .cyan
        case .memory:          return .cyan
        case .screen:          return .teal
        case .camera:          return .cyan
        case .chat:            return .cyan
        case .timeline:        return .orange
        case .reasoning:       return .purple
        case .news:            return .cyan
        case .article:         return .cyan
        case .notifications:   return .orange
        case .proactiveAlert:  return .orange
        case .calendar:        return .blue
        case .tasks:           return .red
        case .github:          return .purple
        case .home:            return .yellow
        case .shopify:         return .green
        case .obsidian:        return .purple
        case .androidBridge:   return .green
        case .phone:           return .green
        case .reddit:          return .orange
        case .brain:                return .indigo
        case .ambientContext:       return .teal
        case .runtimeDiagnostics:  return .indigo
        case .spatialHUD:           return .cyan
        case .haCamera:             return .orange
        case .haAllCameras:         return .orange
        case .haDiagnostics:        return .yellow
        case .surveillance:         return .yellow
        case .pingPong:             return .green
        }
    }

    /// How this overlay's content is (or can be) rendered.
    var renderType: OverlayRenderType {
        switch self {
        case .article: return .webView   // WKWebView article reader
        case .news:    return .hybrid    // native layout + optional web headline pane
        default:       return .nativeSwiftUI
        }
    }

    /// Whether this overlay has a dedicated full implementation.
    /// Overlays returning `false` are rendered as a `ProactiveAlertOverlayContent`
    /// generic fallback until a real implementation is added.
    var isImplemented: Bool {
        switch self {
        case .test, .memory, .screen, .camera, .chat,
             .timeline, .reasoning, .news, .article,
             .notifications, .proactiveAlert, .calendar, .tasks,
             .github, .home, .shopify, .obsidian, .androidBridge, .phone,
             .help, .reddit, .brain, .ambientContext, .runtimeDiagnostics, .spatialHUD,
             .haCamera, .haAllCameras, .haDiagnostics, .surveillance,
             .pingPong:
            return true
        }
    }

    /// True for overlays that play back audio/video (YouTube, news streams, Reddit
    /// video) — while these are open, STT should not be active to avoid the media
    /// audio being picked up as voice commands.
    var containsAudio: Bool {
        switch self {
        case .news, .article, .reddit: return true
        default: return false
        }
    }
}

// MARK: - OverlaySize

enum OverlaySize: Equatable {
    case compact  // 400 × 320
    case medium   // 560 × 480
    case large    // 720 × 580
    case cinema   // 80 % × 80 % of screen

    func dimensions(screen: CGSize) -> CGSize {
        switch self {
        case .compact: return CGSize(width: 400,              height: 320)
        case .medium:  return CGSize(width: 560,              height: 480)
        case .large:   return CGSize(width: 720,              height: 580)
        case .cinema:  return CGSize(width: screen.width * 0.8,
                                     height: screen.height * 0.8)
        }
    }

    /// Next size up when the user says "make this bigger".
    func enlarged() -> OverlaySize {
        switch self {
        case .compact: return .medium
        case .medium:  return .large
        case .large:   return .large   // already max standard
        case .cinema:  return .cinema
        }
    }
}

// MARK: - OverlayState

struct OverlayState: Identifiable, Equatable {
    let id: UUID
    let kind: OverlayKind
    var size: OverlaySize
    var isMinimized: Bool
    var isPinned: Bool
    /// Whether this overlay is currently maximised (fills the usable stage area).
    var isMaximised: Bool
    /// Manual frame set by the user via drag/resize. `nil` = use auto layout.
    var manualFrame: CGRect?
    /// Manual frame saved before a maximise — restored on un-maximise.
    var previousManualFrame: CGRect?

    init(kind: OverlayKind) {
        self.id = UUID()
        self.kind = kind
        self.size = kind.defaultSize
        self.isMinimized = false
        self.isPinned = false
        self.isMaximised = false
        self.manualFrame = nil
        self.previousManualFrame = nil
    }
}

// MARK: - OverlayManager

@Observable
@MainActor
final class OverlayManager {
    private(set) var overlays: [OverlayState] = []
    /// Persisted manual frames keyed by OverlayKind.rawValue. Loaded once at init.
    private var savedFrames: [String: CGRect] = [:]

    init() {
        savedFrames = OverlayLayoutPersistence.shared.load()
    }

    /// Top-most (focused) overlay if any. Insertion order = focus order.
    var topOverlay: OverlayState? { overlays.last }

    /// Kind of the focused overlay, for "close that" friendly responses.
    var latestKind: OverlayKind? { overlays.last?.kind }

    /// Returns true when an overlay of `kind` is currently in the stack.
    func isOpen(_ kind: OverlayKind) -> Bool {
        overlays.contains(where: { $0.kind == kind })
    }

    /// Open the overlay if not already in the stack. If it exists, bring it
    /// to the top (focus it) and un-minimize. Returns true if a NEW overlay
    /// was created, false if an existing one was focused.
    @discardableResult
    func open(_ kind: OverlayKind) -> Bool {
        if let i = overlays.firstIndex(where: { $0.kind == kind }) {
            // Already open — focus + un-minimize.
            if overlays[i].isMinimized { overlays[i].isMinimized = false }
            let existing = overlays.remove(at: i)
            overlays.append(existing)
            Log.ui.info("overlay focus: \(kind.rawValue)")
            JarvisTelemetry.shared.record(.overlayOpened, [
                "kind": kind.rawValue, "action": "focus",
            ])
            return false
        }
        var newState = OverlayState(kind: kind)
        // Restore a previously saved manual frame for this kind, if any.
        newState.manualFrame = savedFrames[kind.rawValue]
        overlays.append(newState)
        Log.ui.info("overlay open: \(kind.rawValue)")
        JarvisTelemetry.shared.record(.overlayOpened, [
            "kind": kind.rawValue, "action": "open",
        ])
        SystemBus.shared.publish(OverlayOpenedEvent(overlayKind: kind.rawValue))
        return true
    }

    /// Move an overlay to the top of the stack (focus). No-op if already on top.
    func focus(_ kind: OverlayKind) {
        guard let i = overlays.firstIndex(where: { $0.kind == kind }) else { return }
        guard i != overlays.count - 1 else { return }   // already focused
        let item = overlays.remove(at: i)
        overlays.append(item)
    }

    /// Close the overlay with `kind`. Returns true if a removal happened.
    @discardableResult
    func close(_ kind: OverlayKind) -> Bool {
        let before = overlays.count
        overlays.removeAll { $0.kind == kind }
        if overlays.count < before {
            Log.ui.info("overlay close: \(kind.rawValue)")
            SystemBus.shared.publish(OverlayClosedEvent(overlayKind: kind.rawValue))
            return true
        }
        return false
    }

    /// Close the focused (top-most) overlay. Pinned overlays are skipped —
    /// voice "close that" commands will not remove a pinned overlay.
    /// Returns the kind that closed, or nil if none was open / all are pinned.
    @discardableResult
    func closeTop() -> OverlayKind? {
        guard let top = overlays.last(where: { !$0.isPinned }) else { return nil }
        close(top.kind)
        return top.kind
    }

    /// Pin the top-most overlay so it survives voice close commands.
    func pinTopOverlay() {
        guard !overlays.isEmpty else { return }
        overlays[overlays.count - 1].isPinned = true
    }

    /// Unpin the top-most overlay so it closes normally.
    func unpinTopOverlay() {
        guard !overlays.isEmpty else { return }
        overlays[overlays.count - 1].isPinned = false
    }

    /// Toggle the pinned state of the overlay with the given id.
    func togglePin(id: UUID) {
        if let i = overlays.firstIndex(where: { $0.id == id }) {
            overlays[i].isPinned.toggle()
        }
    }

    func closeAll() {
        overlays.removeAll()
        Log.ui.info("overlay: closed all")
    }

    func minimize(_ kind: OverlayKind) {
        if let i = overlays.firstIndex(where: { $0.kind == kind }) {
            overlays[i].isMinimized.toggle()
        }
    }

    func minimizeTop() {
        guard let top = topOverlay else { return }
        minimize(top.kind)
    }

    func enlargeTop() {
        guard let i = overlays.indices.last else { return }
        overlays[i].size = overlays[i].size.enlarged()
        // Clear manual frame so the updated size takes effect via auto-layout.
        let kind = overlays[i].kind
        overlays[i].manualFrame = nil
        savedFrames.removeValue(forKey: kind.rawValue)
        OverlayLayoutPersistence.shared.scheduleSave(overlays: overlays)
    }

    /// Toggle between maximised (fills the usable stage) and the previous frame/layout.
    func toggleMaximize(id: UUID) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        if overlays[i].isMaximised {
            overlays[i].isMaximised = false
            overlays[i].manualFrame = overlays[i].previousManualFrame
        } else {
            overlays[i].previousManualFrame = overlays[i].manualFrame
            overlays[i].isMaximised         = true
            overlays[i].isMinimized         = false
        }
    }

    // MARK: - Manual frame management

    /// Set a manual frame for an overlay (committed on drag-end or resize-end).
    func setManualFrame(id: UUID, frame: CGRect) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].manualFrame = frame
        savedFrames[overlays[i].kind.rawValue] = frame
        OverlayLayoutPersistence.shared.scheduleSave(overlays: overlays)
    }

    /// Remove the manual frame for an overlay, returning it to auto-layout.
    func clearManualFrame(id: UUID) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        let kind = overlays[i].kind
        overlays[i].manualFrame = nil
        savedFrames.removeValue(forKey: kind.rawValue)
        OverlayLayoutPersistence.shared.scheduleSave(overlays: overlays)
    }

    /// Reset all manual frames — every overlay returns to auto-layout.
    func resetLayout() {
        for i in overlays.indices {
            overlays[i].manualFrame = nil
            overlays[i].isMaximised = false
        }
        savedFrames = [:]
        OverlayLayoutPersistence.shared.scheduleSave(overlays: overlays)
        Log.ui.info("overlay layout reset")
    }
}

// MARK: - OverlayHostView

/// Full-screen ZStack. Frames are computed by OverlayLayoutEngine and passed to
/// each panel as an absolute CGRect in stage coordinates (top-left origin).
struct OverlayHostView: View {
    let state: AppState
    let controller: JarvisController
    let manager: OverlayManager

    /// Cached stage size so `onChange` handlers can recompute frames without
    /// a GeometryReader — avoids re-entering the body during geometry changes.
    @State private var cachedStageSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            // Compute all frames once per render pass.
            let frames = OverlayLayoutEngine.compute(stageSize: geo.size,
                                                     overlays: manager.overlays)
            ZStack {
                ForEach(Array(manager.overlays.enumerated()), id: \.element.id) { idx, overlay in
                    if let frame = frames[overlay.id] {
                        OverlayPanelView(
                            state:      state,
                            controller: controller,
                            overlay:    overlay,
                            manager:    manager,
                            stageSize:  geo.size,
                            frame:      frame
                        )
                        .zIndex(Double(idx))
                        .transition(.scale(scale: 0.90, anchor: .center)
                            .combined(with: .opacity))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // ── Push overlay frames to spatial coordinator ─────────────────
            // The spatial layer needs to know where overlays live so it can
            // detect hover targets and start pinch-to-drag gestures.
            .onAppear {
                cachedStageSize = geo.size
                pushSpatialContext(frames: frames)
            }
            .onChange(of: geo.size) { _, size in
                cachedStageSize = size
                let f = OverlayLayoutEngine.compute(stageSize: size, overlays: manager.overlays)
                pushSpatialContext(frames: f)
            }
            .onChange(of: manager.overlays) { _, newOverlays in
                let f = OverlayLayoutEngine.compute(stageSize: cachedStageSize, overlays: newOverlays)
                pushSpatialContext(frames: f)
            }
        }
        .animation(.spring(duration: 0.28, bounce: 0.18), value: manager.overlays.count)
        // Escape key closes the top non-pinned overlay — idiomatic SwiftUI-on-macOS
        // shortcut capture without an NSEvent monitor (works on macOS 13+).
        .background(
            Group {
                if let top = manager.overlays.last(where: { !$0.isPinned }) {
                    Button("Close top overlay") {
                        withAnimation { _ = manager.close(top.kind) }
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
                }
            }
        )
    }

    private func pushSpatialContext(frames: [UUID: CGRect]) {
        controller.spatialCoordinator.updateSpatialContext(
            overlayFrames: frames,
            focusedID:     manager.topOverlay?.id
        )
    }
}

// MARK: - OverlayPanelView

private struct OverlayPanelView: View {
    let state: AppState
    let controller: JarvisController
    let overlay: OverlayState
    let manager: OverlayManager
    /// Full stage size — used for clamping drag/resize within bounds.
    let stageSize: CGSize
    /// Absolute frame in stage coordinates (top-left origin), computed by OverlayLayoutEngine.
    let frame: CGRect

    // ── Gesture state (@GestureState auto-resets to .zero when the gesture ends) ──
    @GestureState private var dragDelta:   CGSize = .zero
    @GestureState private var resizeDelta: CGSize = .zero

    @State private var titleBarHovered:    Bool = false
    @State private var resizeHovered:      Bool = false
    /// True when the spatial cursor is hovering over this panel (from hand tracking).
    @State private var isSpatiallyHovered: Bool = false

    private var accent:       Color   { overlay.kind.accentColor }
    private var cornerRadius: CGFloat { overlay.isMaximised ? 12 : 16 }

    /// True while the user is actively dragging the panel.
    private var isDragging: Bool { dragDelta  != .zero }
    /// True while the user is actively resizing the panel.
    private var isResizing: Bool { resizeDelta != .zero }

    /// Live frame during an in-progress gesture — otherwise equals `frame`.
    private var liveFrame: CGRect {
        var f = frame
        if isDragging {
            f = f.offsetBy(dx: dragDelta.width, dy: dragDelta.height)
        }
        if isResizing {
            let w = max(OverlayLayoutEngine.minWidth,  f.width  + resizeDelta.width)
            let h = max(OverlayLayoutEngine.minHeight, f.height + resizeDelta.height)
            f = CGRect(x: f.minX, y: f.minY, width: w, height: h)
        }
        return f
    }

    private let titleBarH = OverlayLayoutEngine.titleBarHeight

    /// Effective frame accounting for the minimized (title-bar-only) state.
    private var effectiveFrame: CGRect {
        guard overlay.isMinimized else { return liveFrame }
        return CGRect(x: liveFrame.minX, y: liveFrame.minY,
                      width: liveFrame.width, height: titleBarH)
    }

    var body: some View {
        // Panels are placed absolutely in the stage ZStack via .position(),
        // which sets the view's centre at (midX, midY) in stage coordinates.
        // Drag/resize gestures update liveFrame in real-time via @GestureState
        // and commit to OverlayManager.manualFrame only on gesture end.
        Group {
            if overlay.kind == .camera {
                minimalCameraPanel
            } else {
                standardPanel
            }
        }
        .frame(width: effectiveFrame.width, height: effectiveFrame.height)
        .position(x: effectiveFrame.midX, y: effectiveFrame.midY)
        // ── Spatial hover glow ─────────────────────────────────────────────
        // Cyan border appears when the hand-tracking cursor enters this panel.
        .overlay(spatialHoverGlow)
        .onReceive(controller.spatialCoordinator.$hoveredOverlayID) { hid in
            withAnimation(.easeInOut(duration: 0.20)) {
                isSpatiallyHovered = (hid == overlay.id)
            }
        }
        // Suppress position animation during active gestures (follows finger exactly).
        // Re-enable smooth spring transitions between auto-layout reflows.
        .animation(isDragging || isResizing ? nil : .spring(duration: 0.3, bounce: 0.08),
                   value: frame)
        .animation(.spring(duration: 0.25), value: overlay.isMinimized)
        .animation(.spring(duration: 0.32, bounce: 0.06), value: overlay.isMaximised)
    }

    // MARK: - Spatial hover glow

    /// Cyan border that appears when the hand-tracking cursor is inside this panel.
    /// Drawn as an outer overlay so it never clips the panel's own content.
    @ViewBuilder
    private var spatialHoverGlow: some View {
        if isSpatiallyHovered {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.85), Color.cyan.opacity(0.40)],
                        startPoint: .topLeading,
                        endPoint:   .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .shadow(color: .cyan.opacity(0.35), radius: 10)
        }
    }

    // MARK: - Standard panel

    private var standardPanel: some View {
        VStack(spacing: 0) {
            premiumTitleBar
                .gesture(dragGesture)   // drag only from the title bar

            if !overlay.isMinimized {
                standardContent
                    .frame(height: max(0, liveFrame.height - titleBarH))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .clipped()
            }
        }
        .frame(width: effectiveFrame.width)
        .background(glassMorphicBackground(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.72), radius: 22, x: 0, y: 8)
        // Resize handle — bottom-right corner grip, hidden when maximised or minimised.
        .overlay(alignment: .bottomTrailing) {
            if !overlay.isMinimized && !overlay.isMaximised {
                resizeHandle
            }
        }
    }

    // MARK: - Resize handle (3×3 dot grip)

    private var resizeHandle: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Color.white.opacity(resizeHovered ? 0.55 : 0.20))
                            .frame(width: 2.5, height: 2.5)
                    }
                }
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .gesture(resizeGesture)
        .onHover { resizeHovered = $0 }
        .padding(8)
        // Ensure the resize handle sits on top of content and receives all hits.
        .allowsHitTesting(true)
    }

    // MARK: - Premium title bar with traffic-light controls

    private var premiumTitleBar: some View {
        HStack(spacing: 0) {
            // ── Traffic lights (left) ──────────────────────────────────────
            HStack(spacing: 7) {
                trafficLight(
                    base: Color(red: 1.0, green: 0.37, blue: 0.34),
                    icon: "xmark"
                ) {
                    withAnimation(.spring(duration: 0.22)) {
                        _ = manager.close(overlay.kind)
                    }
                }
                trafficLight(
                    base: Color(red: 1.0, green: 0.73, blue: 0.18),
                    icon: "minus"
                ) {
                    withAnimation(.spring(duration: 0.25)) {
                        manager.minimize(overlay.kind)
                    }
                }
                trafficLight(
                    base: Color(red: 0.20, green: 0.80, blue: 0.34),
                    icon: overlay.isMaximised
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                ) {
                    withAnimation(.spring(duration: 0.32, bounce: 0.06)) {
                        manager.toggleMaximize(id: overlay.id)
                    }
                }
            }
            .padding(.leading, 13)

            Spacer()

            // ── Centred title ──────────────────────────────────────────────
            HStack(spacing: 5) {
                Image(systemName: overlay.kind.systemImage)
                    .font(.system(size: 9.5))
                    .foregroundStyle(accent.opacity(0.75))
                Text(overlay.kind.title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.65))
                    .tracking(1.8)
            }

            Spacer()

            // ── Pin indicator (right) — mirrors traffic-light width ────────
            HStack(spacing: 7) {
                // Two invisible spacers mirror the close + minimize dots so
                // the title stays truly centred between the two clusters.
                Color.clear.frame(width: 13, height: 13)
                Color.clear.frame(width: 13, height: 13)
                // Pin dot — only shown when pinned, otherwise a ghost placeholder
                Button { manager.togglePin(id: overlay.id) } label: {
                    ZStack {
                        Circle()
                            .fill(overlay.isPinned
                                  ? Color(red: 1.0, green: 0.73, blue: 0.18).opacity(0.85)
                                  : (titleBarHovered
                                     ? Color.white.opacity(0.15)
                                     : Color.white.opacity(0.05)))
                            .frame(width: 13, height: 13)
                        if titleBarHovered || overlay.isPinned {
                            Image(systemName: overlay.isPinned ? "pin.fill" : "pin")
                                .font(.system(size: 6.5, weight: .bold))
                                .foregroundColor(overlay.isPinned ? .black.opacity(0.55) : .white.opacity(0.55))
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(overlay.isPinned ? "Unpin (let voice close it)" : "Pin (voice close ignored)")
            }
            .padding(.trailing, 13)
        }
        .frame(height: titleBarH)
        .background(
            LinearGradient(
                colors: [Color(white: 1, opacity: 0.065), Color(white: 1, opacity: 0.02)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius:  cornerRadius,
            topTrailingRadius: cornerRadius))
        .contentShape(Rectangle())  // makes the full bar a hit-test target for drag
        .onHover { titleBarHovered = $0 }
    }

    /// A single traffic-light circle. Dims when the title bar is not hovered;
    /// shows a glyph icon on hover so the action is always discoverable.
    @ViewBuilder
    private func trafficLight(base: Color,
                               icon: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(titleBarHovered ? base : base.opacity(0.28))
                    .frame(width: 13, height: 13)
                if titleBarHovered {
                    Image(systemName: icon)
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundColor(.black.opacity(0.52))
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var standardContent: some View {
        switch overlay.kind {
        case .test:      TestOverlayContent(state: state)
        case .memory:    MemoryOverlayContent(state: state)
        case .screen:    ScreenOverlayContent(state: state)
        case .camera:    EmptyView() // handled by minimalCameraPanel
        case .chat:      ChatOverlayView(state: state, controller: controller)
        case .timeline:  TimelineOverlayView(store: controller.activityTimeline,
                                             activeApp: state.activeApp)
        case .reasoning: ReasoningOverlayView(store: controller.reasoning)
        case .news:      NewsOverlayView(store: controller.newsStore,
                                         scheduler: controller.newsScheduler,
                                         channelStore: controller.newsChannelStore,
                                         controller: controller,
                                         state: state)
        case .article:       WebOverlayContent(state: state, controller: controller)
        case .notifications: NotificationTrayView(
                                 proactivity: controller.proactivity,
                                 overlayManager: manager,
                                 onOpenArticle: { signalID in
                                     // Look up the signal by ID, find its article, and open.
                                     if let signal = controller.proactivity.pendingSignals
                                         .first(where: { $0.id == signalID }),
                                        let articleID = signal.sourceArticleID {
                                         Task {
                                             if let article = await controller.newsStore.article(id: articleID) {
                                                 controller.openArticle(article)
                                                 manager.open(.news)
                                             }
                                         }
                                     }
                                 }
                             )
        case .proactiveAlert:
            ProactiveAlertOverlayContent(
                engine: controller.proactivity,
                manager: manager,
                onMuteSource: { source in
                    controller.proactivity.mute(source, for: 3600)
                }
            )
        case .calendar:
            CalendarOverlayView(calendarService: controller.calendarService)
        case .tasks:
            TasksOverlayView(todoistClient: controller.todoistClient)
        case .github:
            if let module = controller.githubModule {
                GitHubDashboardView(module: module)
            } else {
                ContentUnavailableView(
                    "GitHub Not Connected",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    description: Text("Add your GitHub personal access token in Settings")
                )
                .padding()
            }
        case .home:
            HomeOverlayView(haClient: controller.smartHome)
        case .shopify:
            ShopifyOverlayView(prefs: controller.prefs)
        case .obsidian:
            ObsidianOverlayView(vault: controller.obsidianVault, prefs: controller.prefs)
        case .androidBridge:
            AndroidOverlayView(
                bridge: controller.androidBridge,
                eventReceiver: controller.androidEventReceiver,
                state: controller.state
            )
        case .phone:
            PhoneOverlayView(
                bridge: controller.androidBridge,
                receiver: controller.androidEventReceiver,
                state: controller.state
            )
        case .help:
            HelpOverlayView()
        case .reddit:
            RedditOverlayView(
                store: controller.redditStore,
                controller: controller,
                state: state)
        case .brain:
            BrainOverlayView()
        case .ambientContext:
            AmbientContextOverlayView(engine: controller.ambientContext)
        case .runtimeDiagnostics:
            RuntimeDiagnosticsOverlayView()
        case .spatialHUD:
            // Spatial interaction is now ambient and always running.
            // This overlay shows read-only diagnostics for the live coordinator.
            SpatialDiagnosticsOverlay(
                coordinator: controller.spatialCoordinator
            )

        // MARK: Home Assistant camera overlays

        case .haCamera:
            HASnapshotOverlayView(
                entityID:     state.haCameraEntityID,
                friendlyName: state.haCameraFriendlyName,
                baseURL:      controller.prefs.current.smartHomeBaseURL ?? "",
                token:        controller.prefs.smartHomeToken ?? ""
            )

        case .haAllCameras:
            HAAllCamerasOverlayView(
                cameras:   controller.haEntityRegistry.cameras,
                baseURL:   controller.prefs.current.smartHomeBaseURL ?? "",
                token:     controller.prefs.smartHomeToken ?? "",
                onSelectCamera: { camera in
                    controller.state.haCameraEntityID     = camera.entityID
                    controller.state.haCameraFriendlyName = camera.displayName
                    controller.overlayManager.open(.haCamera)
                }
            )

        case .haDiagnostics:
            HADiagnosticsOverlayView(
                entityRegistry: controller.haEntityRegistry,
                motionMapper:   controller.haMotionMapper,
                isWSConnected:  state.haWebSocketConnected,
                lastEventText:  state.haLastEventDescription,
                lastAlertText:  state.haLastAlertDescription
            )

        case .surveillance:
            POIHUDView()

        case .pingPong:
            PingPongOverlayView(coordinator: controller.spatialCoordinator)
        }
    }

    // MARK: Minimal camera panel
    //
    // Renders ONLY the live camera image with edges fading to transparent,
    // plus a small close X in the top-right. No title bar, no info strip,
    // no hard frame. The radial-gradient mask makes the image appear to
    // float against the blueprint background.

    private var minimalCameraPanel: some View {
        ZStack(alignment: .topTrailing) {
            cameraImage
                .contentShape(Rectangle())
                .gesture(dragGesture)   // drag from the image area
            closeButton
                .padding(.top, 18)
                .padding(.trailing, 28)
                .opacity(overlay.isMinimized ? 0 : 1)
        }
        .frame(width: liveFrame.width, height: liveFrame.height)
    }

    @ViewBuilder
    private var cameraImage: some View {
        if state.cameraStatus.isHealthy {
            // Soft edge is rendered by a CAGradientLayer mask inside the
            // NSView — see CameraPreviewNSView. SwiftUI .mask() does not
            // reliably affect AVCaptureVideoPreviewLayer compositing.
            CameraPreviewNSView(previewLayer: controller.camera.previewLayer,
                                softEdge: true)
                .frame(width: liveFrame.width, height: liveFrame.height)
                .shadow(color: .cyan.opacity(0.10), radius: 32)
                .shadow(color: .black.opacity(0.45), radius: 18)
        } else {
            // No camera available — placeholder with a SwiftUI-side
            // radial mask (works on simple shapes, no CALayer issue).
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.06, green: 0.08, blue: 0.12))
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.cyan.opacity(0.45))
                        Text("Camera unavailable")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                )
                .frame(width: liveFrame.width * 0.6, height: liveFrame.height * 0.6)
                .mask(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .black,               location: 0.0),
                            .init(color: .black,               location: 0.55),
                            .init(color: .black.opacity(0.4),  location: 0.85),
                            .init(color: .clear,               location: 1.0)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: max(liveFrame.width, liveFrame.height) * 0.45
                    )
                )
        }
    }

    /// Single small close control — top-right corner of the camera view.
    /// Voice users can also say "close camera" or "close that".
    private var closeButton: some View {
        Button {
            withAnimation { _ = manager.close(.camera) }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.45))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
                )
        }
        .buttonStyle(.plain)
        .help("Close camera")
    }

    // MARK: Shared helpers

    private func glassMorphicBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            // Safe mode: solid dark fill. The .ultraThinMaterial blur
            // kernel must be composited by WindowServer on every frame —
            // under high overlay count or with camera/video behind the
            // panel this saturates the GPU and causes watchdog panics.
            // A solid fill is visually near-identical on a dark background
            // and costs a single blit rather than a per-frame blur pass.
            .fill(state.safeMode
                  ? Color(red: 0.06, green: 0.09, blue: 0.16, opacity: 0.97)
                  : Color.clear)
            .background(
                state.safeMode ? nil :
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(state.safeMode ? 0.12 : 0.18),
                                     Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
    }

    private func cornerBrackets(length: CGFloat, color: Color) -> some View {
        CornerBracketsView(length: length, color: color, lineWidth: 1.5)
    }

    // MARK: - Drag gesture (@GestureState — no race on commit, auto-resets on end)

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            // Update the @GestureState live — SwiftUI resets it to .zero when the
            // gesture ends, so `liveFrame` returns to the committed frame automatically.
            .updating($dragDelta) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let newFrame = frame
                    .offsetBy(dx: value.translation.width, dy: value.translation.height)
                    .clamped(to: CGRect(origin: .zero, size: stageSize)
                        .insetBy(dx: OverlayLayoutEngine.margin,
                                 dy: OverlayLayoutEngine.margin))
                manager.setManualFrame(id: overlay.id, frame: newFrame)
                // Bring the dragged overlay to the front.
                manager.focus(overlay.kind)
            }
    }

    // MARK: - Resize gesture

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($resizeDelta) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let newW = max(OverlayLayoutEngine.minWidth,
                               frame.width  + value.translation.width)
                let newH = max(OverlayLayoutEngine.minHeight,
                               frame.height + value.translation.height)
                let newFrame = CGRect(x: frame.minX, y: frame.minY,
                                     width: newW, height: newH)
                    .clamped(to: CGRect(origin: .zero, size: stageSize)
                        .insetBy(dx: OverlayLayoutEngine.margin,
                                 dy: OverlayLayoutEngine.margin))
                manager.setManualFrame(id: overlay.id, frame: newFrame)
            }
    }
}

// MARK: - CornerBracketsView

private struct CornerBracketsView: View {
    let length: CGFloat
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Canvas { ctx, _ in
                for (origin, dx, dy) in [
                    (CGPoint(x: 0,   y: 0),    length,  length),
                    (CGPoint(x: w,   y: 0),   -length,  length),
                    (CGPoint(x: 0,   y: h),    length, -length),
                    (CGPoint(x: w,   y: h),   -length, -length)
                ] as [(CGPoint, CGFloat, CGFloat)] {
                    var path = Path()
                    path.move(to: CGPoint(x: origin.x + dx, y: origin.y))
                    path.addLine(to: origin)
                    path.addLine(to: CGPoint(x: origin.x, y: origin.y + dy))
                    ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
                }
            }
        }
    }
}

// MARK: - CameraPreviewNSView

/// Camera preview backed by AVCaptureVideoPreviewLayer.
///
/// `softEdge=true` applies a rectangular feathered mask to the host
/// view's CALayer. The mask is a CoreGraphics-rendered rounded-rect
/// blurred with CIGaussianBlur, so the camera image stays rectangular
/// in shape but the four edges fade smoothly into transparency rather
/// than ending in hard lines. SwiftUI's `.mask()` modifier cannot mask
/// an AVCaptureVideoPreviewLayer reliably — masking must happen at the
/// CALayer level.
private struct CameraPreviewNSView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    var softEdge: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = SoftEdgeNSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.clear.cgColor

        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(previewLayer)

        if softEdge {
            view.enableSoftEdgeMask()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        previewLayer.frame = nsView.bounds
        (nsView as? SoftEdgeNSView)?.refreshSoftEdgeMaskIfNeeded()
    }

    /// NSView subclass that owns a CALayer mask whose contents is a
    /// blurred white rounded-rect — opaque at the centre, fading to
    /// transparent at every edge. Regenerates the mask image whenever
    /// the bounds change meaningfully.
    final class SoftEdgeNSView: NSView {
        private var maskLayer: CALayer?
        private var lastMaskSize: CGSize = .zero

        /// Shared CIContext — creating a new Metal-backed CIContext on
        /// every mask resize was allocating GPU resources on each resize.
        /// One context shared across all instances is sufficient.
        private static let sharedCIContext = CIContext(
            options: [.useSoftwareRenderer: false, .cacheIntermediates: false]
        )

        func enableSoftEdgeMask() {
            wantsLayer = true
            let m = CALayer()
            m.frame = bounds
            m.contentsGravity = .resize
            layer?.mask = m
            maskLayer = m
            refreshSoftEdgeMaskIfNeeded(force: true)
        }

        func refreshSoftEdgeMaskIfNeeded(force: Bool = false) {
            guard let m = maskLayer else { return }
            let size = bounds.size
            guard size.width > 1, size.height > 1 else { return }
            // Skip if size has barely changed — Gaussian-blurring a
            // ~1.4 MP rect is cheap but still pointless on every tick.
            if !force
               && abs(size.width  - lastMaskSize.width)  < 1
               && abs(size.height - lastMaskSize.height) < 1 {
                return
            }
            lastMaskSize = size

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            m.frame = bounds
            m.contents = Self.makeSoftEdgeRectMask(size: size)
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            refreshSoftEdgeMaskIfNeeded()
        }

        /// Render a soft-edged rectangular alpha mask the size of the
        /// view. Steps:
        ///   1. Draw an opaque white rounded rectangle inset from the
        ///      bounds. Inset is small (~3% of min dimension) so the
        ///      final visible area stays close to the full rectangle.
        ///   2. Apply CIGaussianBlur with a radius ~9% of min dim.
        ///   3. Crop the blurred output back to the original extent
        ///      (blur naturally expands the image).
        /// The resulting CGImage's alpha channel = mask alpha.
        private static func makeSoftEdgeRectMask(size: CGSize) -> CGImage? {
            let minDim = min(size.width, size.height)
            // Large inset + large blur = very soft transparent edges on all sides.
            // inset = 22 % of min dim — the white rect starts well inside the bounds.
            // blurRadius = 25 % of min dim — the Gaussian spreads the fade ~1.5× the inset.
            // Not clamping before blur lets CIGaussianBlur sample transparent pixels
            // outside the image extent, so every edge genuinely fades to clear rather
            // than repeating the boundary colour.
            let inset:        CGFloat = max(50, minDim * 0.22)
            let cornerRadius: CGFloat = max(24, minDim * 0.10)
            let blurRadius:   CGFloat = max(80, minDim * 0.25)

            let w = Int(size.width.rounded())
            let h = Int(size.height.rounded())
            guard w > 0, h > 0 else { return nil }

            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

            let inner = CGRect(
                x: inset, y: inset,
                width:  max(0, size.width  - 2 * inset),
                height: max(0, size.height - 2 * inset)
            )
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            let path = CGPath(
                roundedRect: inner,
                cornerWidth:  cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
            ctx.addPath(path)
            ctx.fillPath()

            guard let base = ctx.makeImage() else { return nil }

            let ci = CIImage(cgImage: base)
            // Do NOT clamp — clamping repeats the boundary colour outward,
            // which prevents the blur from fading to transparent at the edges.
            // Without clamping, CIGaussianBlur samples zero-alpha pixels outside
            // the image extent, so the white rectangle blurs into true transparency.
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = ci
            blur.radius = Float(blurRadius)
            guard let out = blur.outputImage else { return base }

            return sharedCIContext.createCGImage(out,
                                                from: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Memory overlay

private struct MemoryOverlayContent: View {
    let state: AppState

    private var hasSearch:        Bool { !state.memorySearchResults.isEmpty }
    private var hasMemories:      Bool { !state.memoryRows.isEmpty }
    private var hasConversations: Bool { !state.recentConversations.isEmpty }
    private var hasSnapshots:     Bool { !state.recentSnapshots.isEmpty }
    private var isEmpty: Bool { !hasSearch && !hasMemories && !hasConversations && !hasSnapshots }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if hasSearch {
                            sectionHeader("Search: \"\(state.lastSearchQuery)\"",
                                         icon: "magnifyingglass",
                                         count: state.memorySearchResults.count)
                            ForEach(state.memorySearchResults) { result in
                                memoryCard(
                                    text: result.text, ts: result.ts,
                                    accent: result.kind == .memory ? .cyan : .teal,
                                    badge: result.role == "user" ? "You"
                                         : result.role == "assistant" ? "Jarvis" : nil
                                )
                            }
                        }

                        if hasMemories {
                            sectionHeader("Saved Memories",
                                         icon: "brain.head.profile",
                                         count: state.memoryRows.count)
                            ForEach(state.memoryRows.prefix(20), id: \.id) { row in
                                memoryCard(text: row.text, ts: row.ts,
                                           accent: .cyan, badge: nil)
                            }
                        }

                        if hasSnapshots {
                            sectionHeader("Recent Activity",
                                         icon: "clock.arrow.circlepath",
                                         count: state.recentSnapshots.count)
                            ForEach(state.recentSnapshots.prefix(8), id: \.id) { snap in
                                let text = snap.lastResponse.isEmpty
                                    ? snap.lastIntent : snap.lastResponse
                                if !text.isEmpty {
                                    memoryCard(text: text, ts: snap.ts,
                                               accent: .purple, badge: "Jarvis")
                                }
                            }
                        }

                        if hasConversations && !hasSnapshots {
                            sectionHeader("Recent Conversations",
                                         icon: "bubble.left.and.bubble.right",
                                         count: state.recentConversations.count)
                            ForEach(state.recentConversations.prefix(10), id: \.id) { row in
                                memoryCard(
                                    text: row.text, ts: row.ts,
                                    accent: row.role == "user" ? .teal : .yellow,
                                    badge: row.role == "user" ? "You" : "Jarvis"
                                )
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.title2).foregroundStyle(.secondary)
            Text("No memories yet")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text("Say \"remember…\" to save something.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func sectionHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10).padding(.bottom, 4)
    }

    private func memoryCard(text: String, ts: Date, accent: Color, badge: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.15)))
                }
                Text(text)
                    .font(.caption).foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(ts, style: .relative)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle().fill(accent.opacity(0.28)).frame(width: 2),
            alignment: .leading
        )
    }
}

// MARK: - Screen overlay

private struct ScreenOverlayContent: View {
    let state: AppState

    private var summary: ScreenSummary { state.screenSummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.screenWatchActive {
                watchBanner
            }

            if summary.assistantSummary.isEmpty && state.activeApp.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !state.activeApp.isEmpty {
                            row("Active", state.activeApp, .cyan)
                        }
                        if !summary.assistantSummary.isEmpty {
                            if !summary.appName.isEmpty && summary.appName != state.activeApp {
                                row("Captured", summary.appName, .teal)
                            }
                            if !summary.windowTitle.isEmpty {
                                row("Window", summary.windowTitle, .secondary)
                            }
                            Divider().overlay(Color.white.opacity(0.08))
                            if summary.recognizedText.isEmpty {
                                row("Text", "None detected", .secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Text (\(summary.recognizedText.count) lines)")
                                        .foregroundStyle(.secondary)
                                    ForEach(summary.recognizedText.prefix(6), id: \.self) { line in
                                        Text("· \(line)").foregroundStyle(.mint).lineLimit(1)
                                    }
                                }
                            }
                            Divider().overlay(Color.white.opacity(0.08))
                            HStack(spacing: 4) {
                                Image(systemName: state.screenWatchActive
                                      ? "eye.fill" : "eye.slash")
                                    .font(.caption2)
                                    .foregroundStyle(state.screenWatchActive ? .green : .secondary)
                                Text(state.screenWatchActive ? "Watching" : "Idle")
                                    .foregroundStyle(state.screenWatchActive ? .green : .secondary)
                                Spacer()
                                Text(summary.timestamp, style: .relative)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .font(.caption)
    }

    private var watchBanner: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text("Watching").font(.caption2.weight(.semibold)).foregroundStyle(.green)
            Spacer()
            Text("Live").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color.green.opacity(0.07))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "display").font(.title2).foregroundStyle(.secondary)
            Text("No capture yet").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text("Say \"what am I looking at?\" or \"watch this screen\"")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(24)
    }

    private func row(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(value).foregroundStyle(color).lineLimit(1)
        }
    }
}

// MARK: - Test / Status overlay

private struct TestOverlayContent: View {
    let state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                row("Phase",     state.phase.rawValue,            state.phase.accentColor)
                row("Listening", yn(state.isListening),           state.isListening ? .green : .secondary)
                row("Speaking",  yn(state.isSpeaking),            state.isSpeaking ? .yellow : .secondary)
                row("Engine",    state.speechEngine.displayName,  .purple)
                row("Mic",       state.activeMicrophoneName ?? "—", .cyan)
                if !state.lastFinalTranscript.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    row("Last said", state.lastFinalTranscript, .mint)
                }
                if let intent = state.lastIntent {
                    row("Intent", String(String(describing: intent).prefix(30)), .purple)
                }
                if !state.lastSpoken.isEmpty {
                    row("Spoken", state.lastSpoken, .yellow)
                }
                if let err = state.lastError {
                    Divider().overlay(Color.white.opacity(0.08))
                    row("Error", err, .red)
                }
            }
            .padding(14)
        }
        .font(.caption)
    }

    private func yn(_ b: Bool) -> String { b ? "yes" : "no" }

    private func row(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(value).foregroundStyle(color).lineLimit(1)
        }
    }
}

// MARK: - Proactive Alert overlay (generic fallback)

/// Shown for proactivity signals from sources that don't have a dedicated
/// overlay yet (Shopify, Todoist, Calendar, Email, GitHub, Home Assistant).
/// Displays the signal title, body, source, and action buttons.
private struct ProactiveAlertOverlayContent: View {
    let engine: ProactivityEngine
    let manager: OverlayManager
    let onMuteSource: (SignalSource) -> Void

    private var presentation: ProactivityPresentation? {
        engine.latestPresentation
    }

    var body: some View {
        if let p = presentation {
            alertBody(p)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func alertBody(_ p: ProactivityPresentation) -> some View {
        let signal = p.signal
        let accent = accentColor(for: signal.source)

        VStack(alignment: .leading, spacing: 0) {
            // Source + priority header
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: signal.source.systemImage)
                        .font(.title3)
                        .foregroundStyle(accent)
                        .frame(width: 40, height: 40)
                        .background(accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if signal.priority >= .urgent {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                            .offset(x: 3, y: 3)
                    } else if signal.priority >= .high {
                        Circle()
                            .fill(.orange)
                            .frame(width: 10, height: 10)
                            .offset(x: 3, y: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(signal.source.displayName.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                        .tracking(1.5)
                    Text(signal.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                // Priority badge
                Text(signal.priority.displayName)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(accent.opacity(0.18)))
                    .foregroundStyle(accent)
                    .tracking(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.12)

            // Title + body
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(signal.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(4)

                    if !signal.body.isEmpty {
                        Text(signal.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                    }

                    if !signal.category.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "tag.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(signal.category.capitalized)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider().opacity(0.12)

            // Action buttons
            HStack(spacing: 8) {
                Spacer()
                actionButton("Dismiss", icon: "xmark", primary: false, accent: accent) {
                    engine.dismiss(signal.id)
                    manager.close(.proactiveAlert)
                }
                actionButton("Mute Source", icon: "speaker.slash.fill", primary: false,
                             accent: accent) {
                    onMuteSource(signal.source)
                    engine.dismiss(signal.id)
                    manager.close(.proactiveAlert)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash.fill")
                .font(.title2).foregroundStyle(.secondary)
            Text("No alert to show")
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func actionButton(_ label: String, icon: String, primary: Bool,
                               accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption.weight(primary ? .semibold : .regular))
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(
                Capsule().fill(primary ? accent.opacity(0.22) : Color.white.opacity(0.07))
            )
            .overlay(Capsule().strokeBorder(
                primary ? accent.opacity(0.5) : Color.white.opacity(0.12),
                lineWidth: 1))
            .foregroundStyle(primary ? accent : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func accentColor(for source: SignalSource) -> Color {
        switch source.accentColor {
        case "cyan":   return .cyan
        case "green":  return .green
        case "red":    return .red
        case "blue":   return .blue
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "teal":   return .teal
        case "indigo": return .indigo
        default:       return .orange
        }
    }
}
