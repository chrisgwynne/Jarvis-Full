import SwiftUI
import Foundation

// MARK: - OverlayLayoutEngine

/// Pure stateless layout engine. Given the current stage size and overlay array,
/// returns an absolute CGRect (in stage coordinates, top-left origin) for every overlay.
///
/// The last entry in `overlays` is considered the focused (front-most) overlay
/// and receives the largest or most prominent frame in multi-overlay layouts.
enum OverlayLayoutEngine {

    // ── Layout constants ─────────────────────────────────────────────────────────

    /// Minimum margin from stage edges (all sides except bottom).
    static let margin:         CGFloat = 20
    /// Reserved zone at the bottom for the orb + status strip.
    static let bottomReserve:  CGFloat = 112
    /// Gap between adjacent overlay panels.
    static let gap:            CGFloat = 12
    /// Minimum panel width.
    static let minWidth:       CGFloat = 300
    /// Minimum panel height.
    static let minHeight:      CGFloat = 240
    /// Title bar height — matches the constant used in OverlayPanelView.
    static let titleBarHeight: CGFloat = 42

    // ── Entry point ──────────────────────────────────────────────────────────────

    /// Compute absolute stage frames for every overlay.
    ///
    /// Priority order:
    /// 1. Maximised overlays → full usable area frame.
    /// 2. Overlays with a `manualFrame` → that frame, clamped inside stage.
    /// 3. Everything else → auto-layout based on count and focus order.
    ///
    /// - Parameters:
    ///   - stageSize: Current stage dimensions (width × height).
    ///   - overlays:  Ordered array; last element = focused / front-most.
    /// - Returns: `[overlay.id: CGRect]` in stage coordinates.
    static func compute(stageSize: CGSize, overlays: [OverlayState]) -> [UUID: CGRect] {
        guard !overlays.isEmpty else { return [:] }

        // Usable stage rectangle — excludes outer margins and the orb/status reserve.
        let usable = CGRect(
            x:      margin,
            y:      margin,
            width:  max(0, stageSize.width  - 2 * margin),
            height: max(0, stageSize.height - margin - bottomReserve)
        )
        let stageBounds = CGRect(origin: .zero, size: stageSize)

        var result: [UUID: CGRect] = [:]

        // 1. Maximised overlays fill the usable area.
        for o in overlays where o.isMaximised {
            result[o.id] = usable
        }

        // 2. Manual frames — clamped inside the stage minus margins.
        let clampBounds = stageBounds.insetBy(dx: margin, dy: margin)
        for o in overlays where !o.isMaximised {
            if let mf = o.manualFrame {
                result[o.id] = mf.clamped(to: clampBounds)
            }
        }

        // 3. Auto-layout for every remaining overlay.
        let autoOverlays = overlays.filter { !$0.isMaximised && $0.manualFrame == nil }
        let autoFrames = autoLayout(usable: usable, stageSize: stageSize, overlays: autoOverlays)
        // Manual / maximised entries already in `result` take priority.
        for (id, f) in autoFrames {
            if result[id] == nil { result[id] = f }
        }

        return result
    }

    // MARK: - Auto layout dispatch

    private static func autoLayout(usable: CGRect,
                                   stageSize: CGSize,
                                   overlays: [OverlayState]) -> [UUID: CGRect] {
        switch overlays.count {
        case 0:  return [:]
        case 1:  return layoutOne(usable: usable, stageSize: stageSize, overlay: overlays[0])
        case 2:  return layoutTwo(usable: usable, stageSize: stageSize,
                                  back: overlays[0], front: overlays[1])
        case 3:  return layoutThree(usable: usable, stageSize: stageSize, overlays: overlays)
        default: return layoutMasonry(usable: usable, stageSize: stageSize, overlays: overlays)
        }
    }

    // MARK: - 1 overlay: dominant centred panel

    /// Single overlay: natural size, centred, slightly above the vertical midpoint.
    private static func layoutOne(usable: CGRect,
                                  stageSize: CGSize,
                                  overlay: OverlayState) -> [UUID: CGRect] {
        let natural = overlay.size.dimensions(screen: stageSize)
        let w = clamp(natural.width,  lo: minWidth,  hi: usable.width  * 0.85)
        let h = clamp(natural.height, lo: minHeight, hi: usable.height * 0.90)
        let x = usable.minX + (usable.width  - w) * 0.5
        let y = usable.minY + (usable.height - h) * 0.42   // slightly above visual centre
        return [overlay.id: CGRect(x: x, y: y, width: w, height: h)]
    }

    // MARK: - 2 overlays: side-by-side

    /// Background overlay gets 60 %, focused overlay gets the remainder.
    private static func layoutTwo(usable: CGRect,
                                  stageSize: CGSize,
                                  back: OverlayState,
                                  front: OverlayState) -> [UUID: CGRect] {
        let h      = min(usable.height, max(minHeight, usable.height * 0.86))
        let leftW  = clamp(usable.width * 0.60 - gap * 0.5, lo: minWidth, hi: usable.width * 0.66)
        let rightW = max(minWidth, usable.width - leftW - gap)
        let y      = usable.minY + (usable.height - h) * 0.50

        return [
            back.id:  CGRect(x: usable.minX,               y: y, width: leftW,  height: h),
            front.id: CGRect(x: usable.minX + leftW + gap,  y: y, width: rightW, height: h),
        ]
    }

    // MARK: - 3 overlays: two on top row, focused spans the bottom

    private static func layoutThree(usable: CGRect,
                                    stageSize: CGSize,
                                    overlays: [OverlayState]) -> [UUID: CGRect] {
        let topH    = clamp(usable.height * 0.56, lo: minHeight, hi: usable.height - minHeight - gap)
        let bottomH = max(minHeight, usable.height - topH - gap)
        let topW    = (usable.width - gap) / 2

        return [
            overlays[0].id: CGRect(x: usable.minX,              y: usable.minY,
                                   width: topW,         height: topH),
            overlays[1].id: CGRect(x: usable.minX + topW + gap,  y: usable.minY,
                                   width: topW,         height: topH),
            overlays[2].id: CGRect(x: usable.minX,              y: usable.minY + topH + gap,
                                   width: usable.width, height: bottomH),
        ]
    }

    // MARK: - 4+ overlays: masonry

    /// Focused overlay dominates a wide left column (56 %); others tile the right column.
    private static func layoutMasonry(usable: CGRect,
                                      stageSize: CGSize,
                                      overlays: [OverlayState]) -> [UUID: CGRect] {
        let focused  = overlays[overlays.count - 1]
        let rest     = Array(overlays.dropLast())

        let focusedW = max(minWidth, usable.width * 0.56)
        let sideX    = usable.minX + focusedW + gap
        let sideW    = max(minWidth, usable.maxX - sideX)

        var result: [UUID: CGRect] = [
            focused.id: CGRect(x: usable.minX, y: usable.minY,
                               width: focusedW, height: usable.height),
        ]

        let n     = rest.count
        let tileH = max(minHeight,
                        (usable.height - CGFloat(max(0, n - 1)) * gap) / CGFloat(max(1, n)))
        for (i, o) in rest.enumerated() {
            let y = usable.minY + CGFloat(i) * (tileH + gap)
            result[o.id] = CGRect(x: sideX, y: y, width: sideW, height: tileH)
        }

        return result
    }

    // MARK: - Utilities

    private static func clamp(_ v: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, v))
    }
}

// MARK: - CGRect helpers

extension CGRect {
    /// Clamp this rect so it fits entirely within `bounds`.
    /// Shrinks the size if it exceeds the bounds, then clamps the origin.
    func clamped(to bounds: CGRect) -> CGRect {
        let w = min(width,  bounds.width)
        let h = min(height, bounds.height)
        let x = max(bounds.minX, min(minX, bounds.maxX - w))
        let y = max(bounds.minY, min(minY, bounds.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(x: minX + dx, y: minY + dy, width: width, height: height)
    }
}

// MARK: - OverlayLayoutPersistence

/// Persists overlay manual frame overrides to
/// `~/Library/Application Support/JarvisMac/overlay-layout.json`.
///
/// Keyed by `OverlayKind.rawValue` — stable across sessions (UUIDs change per session).
/// Writes are debounced to 0.8 s so rapid drag events produce at most one file write.
@MainActor
final class OverlayLayoutPersistence {

    static let shared = OverlayLayoutPersistence()
    private init() {}

    // Resolve the file URL once at startup.
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        return dir.appendingPathComponent("overlay-layout.json")
    }()

    private var pendingWrite: Task<Void, Never>?

    // MARK: - Codable envelope

    private struct Envelope: Codable {
        struct Frame: Codable {
            let x, y, w, h: Double
            var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
            init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; w = r.width; h = r.height }
        }
        var frames: [String: Frame] = [:]
    }

    // MARK: - Save (debounced 0.8 s)

    func scheduleSave(overlays: [OverlayState]) {
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flush(overlays: overlays)
        }
    }

    private func flush(overlays: [OverlayState]) {
        var env = Envelope()
        for o in overlays {
            if let mf = o.manualFrame {
                env.frames[o.kind.rawValue] = .init(mf)
            }
        }
        do {
            let data = try JSONEncoder().encode(env)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.ui.warning("[OverlayLayoutPersistence] save failed: \(error)")
        }
    }

    // MARK: - Load

    /// Load persisted frames. Returns empty dict if the file doesn't exist yet.
    func load() -> [String: CGRect] {
        guard let data = try? Data(contentsOf: fileURL),
              let env  = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return [:] }
        return env.frames.mapValues { $0.cgRect }
    }
}
