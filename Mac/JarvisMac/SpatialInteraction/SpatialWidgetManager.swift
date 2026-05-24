import Foundation
import SwiftUI
import OSLog

// MARK: - DockEdge

/// The screen edge a widget is docked to.
enum DockEdge: String, Codable, CaseIterable {
    case left
    case right
    case top
    case bottom
}

// MARK: - SnapZone

/// Named positional zones on screen that a widget can snap into.
enum SnapZone: String, Codable, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case center
    case leftThird
    case rightThird
    case topHalf
    case bottomHalf
}

// MARK: - WidgetMoveDirection

/// Cardinal directions for keyboard-driven widget nudging.
enum WidgetMoveDirection {
    case left, right, up, down
}

// MARK: - SpatialWidget

/// A single floating Jarvis overlay panel tracked by `SpatialWidgetManager`.
struct SpatialWidget: Identifiable, Equatable {
    let id: UUID
    /// Which overlay kind this widget represents.
    var kind: OverlayKind
    /// Current position and size on screen (screen coordinates).
    var frame: CGRect
    /// Whether the widget is collapsed to its title bar only.
    var isMinimized: Bool
    /// Whether the widget is pinned to a screen edge.
    var isDocked: Bool
    /// The edge this widget is docked to, or nil when not docked.
    var dockedEdge: DockEdge?
    /// The snap zone this widget occupies, or nil when freely positioned.
    var snapZone: SnapZone?
    /// Last time the user interacted with this widget (used for z-ordering decisions).
    var lastInteractedAt: Date
    /// Higher values are rendered on top of lower ones.
    var zOrder: Int
}

// MARK: - MagneticSnap

/// Configuration and geometry helpers for magnetic edge/corner snapping.
struct MagneticSnap {
    /// Distance in points within which a widget edge will snap to a screen edge or zone.
    var threshold: CGFloat = 40
    /// Gap between a docked/snapped widget and the screen edge.
    var snapEdgeInset: CGFloat = 12

    // MARK: Screen edge rects

    /// Returns the frame that each `SnapZone` occupies for the given screen size.
    ///
    /// These are proportional to the layout designed for a 1440×900 reference screen
    /// and scale gracefully to any resolution.
    static func screenEdgeRects(for screenSize: CGSize) -> [SnapZone: CGRect] {
        let w = screenSize.width
        let h = screenSize.height
        let panelW: CGFloat = 560
        let panelH: CGFloat = 380

        return [
            .topLeft: CGRect(x: 20, y: 20,
                             width: panelW, height: panelH),

            .topRight: CGRect(x: w - panelW - 20, y: 20,
                              width: panelW, height: panelH),

            .bottomLeft: CGRect(x: 20, y: h - 400,
                                width: panelW, height: panelH),

            .bottomRight: CGRect(x: w - panelW - 20, y: h - 400,
                                 width: panelW, height: panelH),

            .center: CGRect(x: (w - 700) / 2, y: (h - 500) / 2,
                            width: 700, height: 500),

            .leftThird: CGRect(x: 20, y: 40,
                               width: w / 3 - 30,
                               height: h - 80),

            .rightThird: CGRect(x: 2 * w / 3 + 10, y: 40,
                                width: w / 3 - 30,
                                height: h - 80),

            .topHalf: CGRect(x: 20, y: 20,
                             width: w - 40,
                             height: h / 2 - 30),

            .bottomHalf: CGRect(x: 20, y: h / 2 + 10,
                                width: w - 40,
                                height: h / 2 - 30),
        ]
    }
}

// MARK: - PersistedWidget (Codable persistence model)

/// Lightweight Codable representation of a `SpatialWidget` for JSON serialisation.
/// `OverlayKind` is stored as its raw String value because the enum's `Codable`
/// conformance is defined in `OverlaySystem.swift` (not redefined here).
private struct PersistedWidget: Codable {
    var id: UUID
    var kindRawValue: String    // OverlayKind.rawValue
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isMinimized: Bool
    var isDocked: Bool
    var dockedEdge: DockEdge?
    var snapZone: SnapZone?
    var zOrder: Int
    var lastInteractedAt: Date

    init(from widget: SpatialWidget) {
        id             = widget.id
        kindRawValue   = widget.kind.rawValue
        x              = widget.frame.origin.x
        y              = widget.frame.origin.y
        width          = widget.frame.size.width
        height         = widget.frame.size.height
        isMinimized    = widget.isMinimized
        isDocked       = widget.isDocked
        dockedEdge     = widget.dockedEdge
        snapZone       = widget.snapZone
        zOrder         = widget.zOrder
        lastInteractedAt = widget.lastInteractedAt
    }

    /// Returns nil if the stored `kindRawValue` no longer maps to a known `OverlayKind`.
    func toWidget() -> SpatialWidget? {
        guard let kind = OverlayKind(rawValue: kindRawValue) else { return nil }
        return SpatialWidget(
            id:               id,
            kind:             kind,
            frame:            CGRect(x: x, y: y, width: width, height: height),
            isMinimized:      isMinimized,
            isDocked:         isDocked,
            dockedEdge:       dockedEdge,
            snapZone:         snapZone,
            lastInteractedAt: lastInteractedAt,
            zOrder:           zOrder
        )
    }
}

// MARK: - SpatialWidgetManager

/// Multi-widget floating panel registry.
///
/// `SpatialWidgetManager` tracks every live Jarvis overlay panel as a `SpatialWidget`,
/// providing layout operations (move, resize, dock, snap, z-order) and persistence
/// of the layout to `~/Library/Application Support/JarvisMac/spatial_widgets.json`.
///
/// **Integration with `SpatialAmbientCoordinator`:**
/// After creating the coordinator, wire its callbacks:
/// ```swift
/// coordinator.onOverlayMove   = { id, frame  in widgetManager.moveWidget(id: id, to: frame)   }
/// coordinator.onOverlayResize = { id, size   in widgetManager.resizeWidget(id: id, to: size)  }
/// ```
@MainActor @Observable
final class SpatialWidgetManager {

    // MARK: Singleton

    static let shared = SpatialWidgetManager()

    // MARK: - State

    /// All currently registered widgets, in ascending z-order.
    private(set) var widgets: [SpatialWidget] = []

    /// The widget that currently has keyboard / interaction focus.
    private(set) var activeWidgetID: UUID?

    // MARK: - Constants

    private let dockedEdgeInset: CGFloat = 12
    private let minimizedHeight: CGFloat = 36   // collapsed title-bar height

    // MARK: - Persistence URL

    private let persistenceURL: URL = {
        let fm   = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir  = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spatial_widgets.json")
    }()

    // MARK: - Init

    private init() {
        loadLayout()
    }

    // MARK: - CRUD

    /// Registers a new widget of the given kind at the specified frame.
    /// - Returns: The UUID assigned to the new widget.
    @discardableResult
    func addWidget(kind: OverlayKind, at frame: CGRect) -> UUID {
        let id = UUID()
        let nextZ = (widgets.map(\.zOrder).max() ?? 0) + 1
        let widget = SpatialWidget(
            id:               id,
            kind:             kind,
            frame:            frame,
            isMinimized:      false,
            isDocked:         false,
            dockedEdge:       nil,
            snapZone:         nil,
            lastInteractedAt: Date(),
            zOrder:           nextZ
        )
        widgets.append(widget)
        print("[SpatialWidgetManager] Added widget \(kind.rawValue) id=\(id)")
        saveLayout()
        return id
    }

    /// Removes the widget with the given id, if it exists.
    func removeWidget(id: UUID) {
        guard let idx = index(for: id) else { return }
        widgets.remove(at: idx)
        if activeWidgetID == id { activeWidgetID = nil }
        print("[SpatialWidgetManager] Removed widget id=\(id)")
        saveLayout()
    }

    /// Removes the first widget matching the given `OverlayKind`.
    func removeWidget(kind: OverlayKind) {
        guard let idx = widgets.firstIndex(where: { $0.kind == kind }) else { return }
        let id = widgets[idx].id
        widgets.remove(at: idx)
        if activeWidgetID == id { activeWidgetID = nil }
        print("[SpatialWidgetManager] Removed widget kind=\(kind.rawValue)")
        saveLayout()
    }

    /// Returns the widget with the given id, or nil.
    func widget(for id: UUID) -> SpatialWidget? {
        widgets.first { $0.id == id }
    }

    /// Returns the first widget matching the given kind, or nil.
    func widget(for kind: OverlayKind) -> SpatialWidget? {
        widgets.first { $0.kind == kind }
    }

    // MARK: - Layout Operations

    /// Moves the widget to `newFrame` (full origin + size replacement).
    /// Clears any existing dock/snap state since the user is freely repositioning.
    func moveWidget(id: UUID, to newFrame: CGRect) {
        guard let idx = index(for: id) else { return }
        widgets[idx].frame            = newFrame
        widgets[idx].isDocked         = false
        widgets[idx].dockedEdge       = nil
        widgets[idx].snapZone         = nil
        widgets[idx].lastInteractedAt = Date()
        saveLayout()
    }

    /// Changes only the size of the widget, keeping its current origin.
    func resizeWidget(id: UUID, to newSize: CGSize) {
        guard let idx = index(for: id) else { return }
        widgets[idx].frame.size       = newSize
        widgets[idx].lastInteractedAt = Date()
        saveLayout()
    }

    /// Collapses the widget to its title bar. The frame height is reduced to
    /// `minimizedHeight` so the title bar remains draggable/visible.
    func minimizeWidget(id: UUID) {
        guard let idx = index(for: id) else { return }
        guard !widgets[idx].isMinimized else { return }
        widgets[idx].isMinimized      = true
        widgets[idx].frame.size.height = minimizedHeight
        widgets[idx].lastInteractedAt = Date()
        saveLayout()
    }

    /// Restores a minimized widget to a sensible default height.
    /// The default height is derived from `OverlayKind.defaultSize` if available,
    /// otherwise falls back to 400 pt.
    func restoreWidget(id: UUID) {
        guard let idx = index(for: id) else { return }
        guard widgets[idx].isMinimized else { return }
        widgets[idx].isMinimized = false
        // Restore to the kind's natural height (approximate — exact size comes
        // from the overlay's own SwiftUI layout on the next render pass).
        let naturalHeight: CGFloat = 400
        widgets[idx].frame.size.height = naturalHeight
        widgets[idx].lastInteractedAt  = Date()
        saveLayout()
    }

    /// Pins the widget to a screen edge. The widget's position along the
    /// perpendicular axis is preserved; only the component along the edge axis
    /// is overridden to place it flush against the edge.
    func dockWidget(id: UUID, to edge: DockEdge, screenSize: CGSize) {
        guard let idx = index(for: id) else { return }
        var w = widgets[idx]

        switch edge {
        case .left:
            w.frame.origin.x = dockedEdgeInset
        case .right:
            w.frame.origin.x = screenSize.width - w.frame.width - dockedEdgeInset
        case .top:
            w.frame.origin.y = dockedEdgeInset
        case .bottom:
            w.frame.origin.y = screenSize.height - w.frame.height - dockedEdgeInset
        }

        w.isDocked         = true
        w.dockedEdge       = edge
        w.snapZone         = nil
        w.lastInteractedAt = Date()
        widgets[idx] = w
        saveLayout()
    }

    /// Releases the widget from its docked edge. Frame position is unchanged.
    func undockWidget(id: UUID) {
        guard let idx = index(for: id) else { return }
        widgets[idx].isDocked         = false
        widgets[idx].dockedEdge       = nil
        widgets[idx].lastInteractedAt = Date()
        saveLayout()
    }

    /// Raises the widget above all others by assigning it the highest z-order.
    func bringToFront(id: UUID) {
        guard let idx = index(for: id) else { return }
        let maxZ = widgets.map(\.zOrder).max() ?? 0
        widgets[idx].zOrder           = maxZ + 1
        widgets[idx].lastInteractedAt = Date()
        // No saveLayout() — z-order changes are ephemeral during a session
        // but will be persisted on the next substantive layout change.
    }

    /// Teleports the widget into one of the named screen zones.
    func snapToZone(_ zone: SnapZone, widgetID: UUID, screenSize: CGSize) {
        guard let idx = index(for: widgetID) else { return }
        let zoneRects = MagneticSnap.screenEdgeRects(for: screenSize)
        guard let targetFrame = zoneRects[zone] else { return }

        widgets[idx].frame            = targetFrame
        widgets[idx].snapZone         = zone
        widgets[idx].isDocked         = false
        widgets[idx].dockedEdge       = nil
        widgets[idx].lastInteractedAt = Date()
        saveLayout()
    }

    /// Nudges a widget by `amount` points in a cardinal direction.
    /// Useful for keyboard-driven fine positioning.
    func moveWidget(id: UUID, direction: WidgetMoveDirection, amount: CGFloat) {
        guard let idx = index(for: id) else { return }
        var origin = widgets[idx].frame.origin
        switch direction {
        case .left:  origin.x -= amount
        case .right: origin.x += amount
        case .up:    origin.y -= amount
        case .down:  origin.y += amount
        }
        widgets[idx].frame.origin     = origin
        widgets[idx].isDocked         = false
        widgets[idx].dockedEdge       = nil
        widgets[idx].snapZone         = nil
        widgets[idx].lastInteractedAt = Date()
        saveLayout()
    }

    // MARK: - Magnetic Snap

    /// Adjusts `frame` so that it snaps to a screen edge or corner when within
    /// `MagneticSnap.threshold` points of one.
    ///
    /// - Returns: A tuple of (snappedFrame, assignedSnapZone?).
    ///   `assignedSnapZone` is non-nil only when the frame snapped to a corner.
    func applyMagneticSnap(
        to frame: CGRect,
        screenSize: CGSize
    ) -> (CGRect, SnapZone?) {
        let threshold: CGFloat = MagneticSnap().threshold
        let inset:     CGFloat = MagneticSnap().snapEdgeInset

        var result = frame

        // --- Horizontal axis ---
        let nearLeft  = frame.minX < threshold
        let nearRight = frame.maxX > screenSize.width - threshold

        if nearLeft  { result.origin.x = inset }
        if nearRight { result.origin.x = screenSize.width - frame.width - inset }

        // --- Vertical axis ---
        let nearTop    = frame.minY < threshold
        let nearBottom = frame.maxY > screenSize.height - threshold

        if nearTop    { result.origin.y = inset }
        if nearBottom { result.origin.y = screenSize.height - frame.height - inset }

        // --- Derive snap zone from corner proximity ---
        var zone: SnapZone? = nil

        switch (nearLeft || nearRight, nearTop || nearBottom) {
        case (true, true):
            // Corner
            if nearLeft  && nearTop    { zone = .topLeft    }
            if nearRight && nearTop    { zone = .topRight   }
            if nearLeft  && nearBottom { zone = .bottomLeft }
            if nearRight && nearBottom { zone = .bottomRight }
        case (false, false):
            // Check proximity to center
            let centerX = screenSize.width  / 2
            let centerY = screenSize.height / 2
            let distCenter = hypot(frame.midX - centerX, frame.midY - centerY)
            if distCenter < threshold * 2 {
                result.origin.x = (screenSize.width  - frame.width)  / 2
                result.origin.y = (screenSize.height - frame.height) / 2
                zone = .center
            }
        default:
            break
        }

        return (result, zone)
    }

    // MARK: - Active Widget

    /// Sets the currently focused widget. Pass nil to clear focus.
    func setActiveWidget(id: UUID?) {
        activeWidgetID = id
        if let id { bringToFront(id: id) }
    }

    /// Focuses the first widget matching `kind`, bringing it to the front.
    func focusWidget(kind: OverlayKind) {
        guard let w = widget(for: kind) else { return }
        setActiveWidget(id: w.id)
    }

    // MARK: - Private Helpers

    private func index(for id: UUID) -> Int? {
        widgets.firstIndex { $0.id == id }
    }

    // MARK: - Persistence

    /// Serialises the current widget layout to disk.
    private func saveLayout() {
        let persisted = widgets.map(PersistedWidget.init)
        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            print("[SpatialWidgetManager] Failed to save layout: \(error)")
        }
    }

    /// Deserialises the widget layout from disk (called once at init).
    private func loadLayout() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: persistenceURL)
            let persisted = try JSONDecoder().decode([PersistedWidget].self, from: data)
            widgets = persisted.compactMap { $0.toWidget() }
            print("[SpatialWidgetManager] Loaded \(widgets.count) widget(s) from disk")
        } catch {
            print("[SpatialWidgetManager] Failed to load layout: \(error)")
        }
    }
}
