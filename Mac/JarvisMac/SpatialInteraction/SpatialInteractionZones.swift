// SpatialInteractionZones.swift
// JarvisMac — SpatialInteraction
//
// Defines named spatial zones on screen and the rules that apply in each zone.
// Used by the gesture pipeline to boost/suppress gesture confidence and to
// categorise where hands are relative to the display.
//
// Coordinate convention
// ─────────────────────
// All "normalizedPoint" / "normalizedRect" values are in the [0, 1] range
// measured from the top-left corner of the screen (SwiftUI / CoreGraphics
// window coordinates).  `SpatialInteractionZoneEngine` multiplies them by
// `screenSize` to get pixel coordinates for hit testing.

import Foundation
import CoreGraphics

// MARK: - InteractionZone

/// Named regions of the screen, each with distinct gesture-recognition rules.
enum InteractionZone: String, CaseIterable, Codable {
    /// Upper 15% of screen height — face exclusion zone.
    case face

    /// Lower 25% of screen — preferred desk/tabletop interaction area.
    case desk

    /// Middle 30% vertical band — natural hover / chest-level zone.
    case chest

    /// Right 60% of screen (excluding top 5%) — high-precision screen region.
    case screen

    /// Special: active when both hands are spread apart by more than 200 pts.
    /// Has no fixed normalised rect; evaluated via `isTwoHandZone(primary:secondary:)`.
    case twoHand

    /// Far edges — within 30 pts of any screen edge; reduced precision.
    case extended
}

// MARK: - ZoneDescriptor

/// Static geometry and rules for a single `InteractionZone`.
struct ZoneDescriptor {
    /// The zone this descriptor describes.
    let zone: InteractionZone

    /// Position and size in normalised [0, 1] coordinates (of the full screen).
    /// `.twoHand` has no rect — use `SpatialInteractionZoneEngine.isTwoHandZone` instead.
    let normalizedRect: CGRect

    /// When `true`, any hand detected in this zone blocks gesture recognition entirely.
    let suppressesGestures: Bool

    /// Added to the base gesture-confidence score while a hand is in this zone.
    /// Can be negative (penalises confidence) or positive (boosts it).
    let confidenceBoost: Float

    /// Human-readable explanation of the zone's purpose.
    let description: String
}

// MARK: ZoneDescriptor static definitions

extension ZoneDescriptor {

    /// The authoritative, ordered list of zone descriptors.
    ///
    /// `.twoHand` and `.extended` are listed last because their geometry
    /// requires special-case handling in the engine.
    static let allZones: [ZoneDescriptor] = [
        // ── Face zone — awareness only, no suppression ────────────────────
        // Suppression disabled: users naturally gesture in front of their face
        // when pointing at the top of their screen. The slight confidence penalty
        // remains to deprioritise ambiguous face-region detections.
        ZoneDescriptor(
            zone:              .face,
            normalizedRect:    CGRect(x: 0, y: 0, width: 1.0, height: 0.15),
            suppressesGestures: false,
            confidenceBoost:   -0.05,
            description:       "Face zone — confidence penalty only, gestures not suppressed"
        ),

        // ── Desk interaction ──────────────────────────────────────────────
        ZoneDescriptor(
            zone:              .desk,
            normalizedRect:    CGRect(x: 0, y: 0.75, width: 1.0, height: 0.25),
            suppressesGestures: false,
            confidenceBoost:   +0.15,
            description:       "Desk zone — preferred widget interaction area"
        ),

        // ── Chest hover ───────────────────────────────────────────────────
        ZoneDescriptor(
            zone:              .chest,
            normalizedRect:    CGRect(x: 0.15, y: 0.35, width: 0.70, height: 0.30),
            suppressesGestures: false,
            confidenceBoost:   +0.10,
            description:       "Chest zone — natural hover area"
        ),

        // ── Screen precision region ───────────────────────────────────────
        ZoneDescriptor(
            zone:              .screen,
            normalizedRect:    CGRect(x: 0.40, y: 0.05, width: 0.60, height: 0.70),
            suppressesGestures: false,
            confidenceBoost:   +0.20,
            description:       "Screen interaction zone — high precision region"
        ),

        // ── Two-hand spread (no rect — geometry evaluated separately) ─────
        ZoneDescriptor(
            zone:              .twoHand,
            normalizedRect:    .zero,           // unused; see isTwoHandZone(_:_:)
            suppressesGestures: false,
            confidenceBoost:   +0.05,
            description:       "Two-hand zone — both hands detected and spread > 200 pts"
        ),

        // ── Extended reach (far screen edges) ────────────────────────────
        ZoneDescriptor(
            zone:              .extended,
            normalizedRect:    .zero,           // computed dynamically from screen edges
            suppressesGestures: false,
            confidenceBoost:   -0.10,
            description:       "Extended reach zone — reduced precision"
        ),
    ]

    /// Convenience lookup: return the descriptor for a specific zone.
    static func descriptor(for zone: InteractionZone) -> ZoneDescriptor {
        // allZones is small and fixed — linear search is fine.
        allZones.first(where: { $0.zone == zone })!
    }
}

// MARK: - SpatialInteractionZoneEngine

/// Evaluates which spatial zone(s) a normalised hand position occupies and
/// returns the gesture-recognition rules that apply.
///
/// - Thread safety: `@MainActor` — mirror whatever actor the gesture pipeline runs on.
/// - Coordinate space: all input points must be in normalised [0, 1] coordinates
///   (top-left origin, matching CoreGraphics/SwiftUI window space).
@MainActor
final class SpatialInteractionZoneEngine {

    // MARK: Properties

    /// The physical screen size in points.  Update this when the window resizes.
    var screenSize: CGSize

    // MARK: Init

    /// - Parameter screenSize: Physical screen size in points (used to convert
    ///   normalised coordinates and to evaluate the `.extended` edge zone).
    init(screenSize: CGSize) {
        self.screenSize = screenSize
    }

    // MARK: - Primary zone queries

    /// Returns the single highest-priority zone containing `normalizedPoint`,
    /// or `nil` if the point falls outside all defined zones.
    ///
    /// Priority order matches `ZoneDescriptor.allZones` (face → desk → chest → screen → extended).
    func zone(for normalizedPoint: CGPoint) -> InteractionZone? {
        zones(for: normalizedPoint).first
    }

    /// Returns every zone that contains `normalizedPoint` (can be multiple).
    ///
    /// `.twoHand` is never returned here — use `isTwoHandZone(primary:secondary:)`.
    /// `.extended` is evaluated by proximity to any screen edge (within 30 pts).
    func zones(for normalizedPoint: CGPoint) -> [InteractionZone] {
        var result: [InteractionZone] = []

        for descriptor in ZoneDescriptor.allZones {
            switch descriptor.zone {
            case .twoHand:
                // Two-hand zone has no fixed rect; skip here.
                continue
            case .extended:
                if isInExtendedZone(normalizedPoint) {
                    result.append(.extended)
                }
            default:
                let pixelRect = pixelRect(from: descriptor.normalizedRect)
                let pixelPoint = pixelPoint(from: normalizedPoint)
                if pixelRect.contains(pixelPoint) {
                    result.append(descriptor.zone)
                }
            }
        }

        return result
    }

    /// Returns the `ZoneDescriptor` for the given zone.
    func descriptor(for zone: InteractionZone) -> ZoneDescriptor {
        ZoneDescriptor.descriptor(for: zone)
    }

    // MARK: - Gesture suppression

    /// Returns `true` if any zone at `normalizedPoint` has `suppressesGestures == true`.
    func isGestureSuppressed(at normalizedPoint: CGPoint) -> Bool {
        zones(for: normalizedPoint).contains(where: {
            ZoneDescriptor.descriptor(for: $0).suppressesGestures
        })
    }

    // MARK: - Confidence modifier

    /// Returns the sum of `confidenceBoost` values for every zone that contains
    /// `normalizedPoint`.  The result is applied additively to the base gesture score.
    ///
    /// Example: a point inside both `.desk` (+0.15) and `.screen` (+0.20) returns +0.35.
    func confidenceModifier(at normalizedPoint: CGPoint) -> Float {
        zones(for: normalizedPoint).reduce(0.0) {
            $0 + ZoneDescriptor.descriptor(for: $1).confidenceBoost
        }
    }

    // MARK: - Two-hand zone

    /// Returns `true` when both hands are detected and their separation exceeds 200 pts.
    ///
    /// Both positions must be provided as normalised [0, 1] coordinates.
    /// The distance is un-normalised by `screenSize.width` before the threshold check,
    /// matching the 200-pt physical threshold documented in the spec.
    func isTwoHandZone(primaryPos: CGPoint, secondaryPos: CGPoint) -> Bool {
        // Compute Euclidean distance in normalised space then scale to screen points.
        let dx = (primaryPos.x - secondaryPos.x) * screenSize.width
        let dy = (primaryPos.y - secondaryPos.y) * screenSize.height
        let distancePts = sqrt(dx * dx + dy * dy)
        return distancePts > 200.0
    }

    // MARK: - Convenience description

    /// Returns a human-readable description of the primary zone at `normalizedPoint`,
    /// or "No zone" if the point is outside all defined zones.
    func zoneDescription(at normalizedPoint: CGPoint) -> String {
        guard let primary = zone(for: normalizedPoint) else {
            return "No zone"
        }
        return descriptor(for: primary).description
    }

    // MARK: - Private helpers

    /// Convert a normalised point to pixel coordinates.
    private func pixelPoint(from normalized: CGPoint) -> CGPoint {
        CGPoint(
            x: normalized.x * screenSize.width,
            y: normalized.y * screenSize.height
        )
    }

    /// Convert a normalised rect to pixel coordinates.
    private func pixelRect(from normalized: CGRect) -> CGRect {
        CGRect(
            x:      normalized.origin.x    * screenSize.width,
            y:      normalized.origin.y    * screenSize.height,
            width:  normalized.size.width  * screenSize.width,
            height: normalized.size.height * screenSize.height
        )
    }

    /// Returns `true` if the normalised point is within 30 pts of any screen edge.
    private func isInExtendedZone(_ normalized: CGPoint) -> Bool {
        let threshold: CGFloat = 30.0
        let px = normalized.x * screenSize.width
        let py = normalized.y * screenSize.height
        return px < threshold
            || py < threshold
            || px > (screenSize.width  - threshold)
            || py > (screenSize.height - threshold)
    }
}
