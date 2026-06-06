import SwiftUI
import Combine
import os

// MARK: - OrbInteractionController

/// Manages the orb's spatial position, scale, drag state, and pin state.
///
/// Lifecycle: create once in the parent view (or JarvisController), then call
/// `updateFromCoordinator(_:)` from a `.onChange(of: coordinator.orbIsPinched)` or
/// `.onChange(of: coordinator.cursorState)` modifier so position/grab track the hand.
///
/// Position and scale are persisted to UserDefaults so the orb remembers its placement
/// across app restarts. Keys: `orb.position.x`, `orb.position.y`, `orb.scale`.
///
/// This class owns NO runtime logic — it is purely a spatial state machine.
@MainActor
final class OrbInteractionController: ObservableObject {

    // MARK: - Published state

    @Published private(set) var position: CGPoint
    @Published private(set) var scale:    CGFloat
    @Published private(set) var isGrabbed:            Bool = false
    @Published private(set) var isPinned:             Bool = false
    @Published private(set) var handTrackingActive:   Bool = false

    // MARK: - Private

    private var grabOffset: CGSize = .zero
    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()

    private static let defaultPosition = CGPoint(x: 120, y: 120)
    private static let defaultScale:    CGFloat = 1.0

    private static let posXKey   = "orb.position.x"
    private static let posYKey   = "orb.position.y"
    private static let scaleKey  = "orb.scale"
    private static let pinnedKey = "orb.pinned"

    private let log = Logger(subsystem: "Jarvis", category: "OrbInteraction")

    // MARK: - Init

    init() {
        let x: CGFloat = (UserDefaults.standard.object(forKey: Self.posXKey) as? Double)
            .map { CGFloat($0) } ?? Self.defaultPosition.x
        let y: CGFloat = (UserDefaults.standard.object(forKey: Self.posYKey) as? Double)
            .map { CGFloat($0) } ?? Self.defaultPosition.y
        let s: CGFloat = (UserDefaults.standard.object(forKey: Self.scaleKey) as? Double)
            .map { CGFloat($0) } ?? Self.defaultScale
        let pinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)

        position = CGPoint(x: x, y: y)
        scale    = min(max(s, 0.5), 2.5)
        isPinned = pinned
    }

    // MARK: - Coordinator integration

    /// Call this whenever the spatial coordinator state changes.
    /// Typically wired in a `.onChange` modifier on `coordinator.orbIsPinched` and `coordinator.cursorState`.
    func updateFromCoordinator(_ coord: SpatialAmbientCoordinator) {
        handTrackingActive = coord.isTrackingActive

        let pinching = coord.orbIsPinched || coord.cursorState.isPinching && coord.orbIsHovered
        let cursor   = coord.cursorState.position

        if pinching && !isGrabbed {
            // Grab start
            isGrabbed  = true
            grabOffset = CGSize(
                width:  position.x - cursor.x,
                height: position.y - cursor.y
            )
            log.debug("[Orb] grab started at (\(cursor.x, privacy: .public), \(cursor.y, privacy: .public))")
        } else if !pinching && isGrabbed {
            // Grab end
            isGrabbed = false
            persist()
            log.debug("[Orb] grab ended, position=(\(self.position.x, privacy: .public), \(self.position.y, privacy: .public))")
        } else if isGrabbed && pinching {
            // Dragging
            position = CGPoint(
                x: cursor.x + grabOffset.width,
                y: cursor.y + grabOffset.height
            )
        }
    }

    // MARK: - Direct drag (mouse/touch fallback)

    /// Begin a drag from the view's DragGesture.
    func dragBegan(from startLocation: CGPoint) {
        isGrabbed  = true
        grabOffset = CGSize(
            width:  position.x - startLocation.x,
            height: position.y - startLocation.y
        )
    }

    /// Update position during a drag.
    func dragChanged(to location: CGPoint) {
        guard isGrabbed else { return }
        position = CGPoint(
            x: location.x + grabOffset.width,
            y: location.y + grabOffset.height
        )
    }

    /// End the drag, persist.
    func dragEnded() {
        isGrabbed = false
        persist()
    }

    // MARK: - Pin / unpin

    func togglePin() {
        isPinned.toggle()
        defaults.set(isPinned, forKey: Self.pinnedKey)
        log.debug("[Orb] pinned=\(self.isPinned, privacy: .public)")
    }

    func pin()   { if !isPinned { togglePin() } }
    func unpin() { if  isPinned { togglePin() } }

    // MARK: - Scale

    func setScale(_ newScale: CGFloat) {
        scale = min(max(newScale, 0.5), 2.5)
        defaults.set(Double(scale), forKey: Self.scaleKey)
    }

    // MARK: - Reset

    func resetPosition() {
        position = Self.defaultPosition
        scale    = Self.defaultScale
        isPinned = false
        persist()
        log.debug("[Orb] position reset to default")
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(Double(position.x), forKey: Self.posXKey)
        defaults.set(Double(position.y), forKey: Self.posYKey)
        defaults.set(Double(scale),       forKey: Self.scaleKey)
    }
}
