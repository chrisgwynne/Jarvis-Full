import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Spring Configuration

struct SpringConfig {
    /// Stiffness — higher = snappier return.
    var stiffness:  Double = 180
    /// Damping — higher = less oscillation.
    var damping:    Double = 22
    /// Mass — higher = more inertia.
    var mass:       Double = 1.0

    static let orb = SpringConfig(stiffness: 160, damping: 20, mass: 1.0)
    static let snappy = SpringConfig(stiffness: 320, damping: 30, mass: 0.8)
}

// MARK: - PhysicsBody

/// A 2-D spring-damper body. Integrate it each frame with `step(dt:target:)`.
struct PhysicsBody {
    var position: CGPoint
    var velocity: CGPoint = .zero
    var config:   SpringConfig

    init(at position: CGPoint, config: SpringConfig = .orb) {
        self.position = position
        self.config   = config
    }

    /// Advance physics by `dt` seconds toward `target`.
    /// Call from a `CADisplayLink` or `TimelineView` update handler.
    mutating func step(dt: Double, target: CGPoint) {
        guard dt > 0, dt < 0.1 else { return }   // clamp runaway frames

        let k = config.stiffness
        let b = config.damping
        let m = config.mass

        // Implicit Euler integration (stable at large dt).
        let dx = position.x - target.x
        let dy = position.y - target.y

        let ax = (-k * dx - b * velocity.x) / m
        let ay = (-k * dy - b * velocity.y) / m

        velocity.x += ax * dt
        velocity.y += ay * dt
        position.x += velocity.x * dt
        position.y += velocity.y * dt
    }

    mutating func teleport(to point: CGPoint) {
        position = point
        velocity = .zero
    }

    /// Kick the body with an impulse (useful for "throw" on pinch release).
    mutating func applyImpulse(dx: Double, dy: Double) {
        velocity.x += dx / config.mass
        velocity.y += dy / config.mass
    }

    var speed: Double {
        sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
    }
}

// MARK: - InteractionPhysics

/// Owns all physics bodies in the spatial scene.
/// Call `tick(dt:)` every display refresh, then read `.orbPosition`.
@MainActor
final class InteractionPhysics: ObservableObject {

    // MARK: Published

    @Published private(set) var orbPosition: CGPoint = CGPoint(x: 200, y: 200)

    // MARK: State

    /// True while the orb is being dragged (pinch held).
    private(set) var isDragging = false

    /// Last pinch release velocity — used to impart momentum on drop.
    private var lastDragVelocity: CGPoint = .zero
    private var prevDragTarget:   CGPoint = .zero
    private var dragTargetTime:   Date?

    // MARK: Physics bodies

    private var orbBody: PhysicsBody

    // MARK: Init

    init(initialOrbPosition: CGPoint = CGPoint(x: 200, y: 200)) {
        self.orbBody = PhysicsBody(at: initialOrbPosition, config: .orb)
        self.orbPosition = initialOrbPosition
    }

    // MARK: Drag API

    func beginDrag(at point: CGPoint) {
        isDragging = true
        prevDragTarget = point
        dragTargetTime = Date()
    }

    func updateDrag(to point: CGPoint) {
        guard isDragging else { return }
        let now = Date()
        let dt = now.timeIntervalSince(dragTargetTime ?? now)
        if dt > 0.001 {
            lastDragVelocity = CGPoint(
                x: (point.x - prevDragTarget.x) / dt,
                y: (point.y - prevDragTarget.y) / dt
            )
        }
        prevDragTarget = point
        dragTargetTime = now
    }

    func endDrag() {
        isDragging = false
        // Impart release velocity so orb has momentum.
        let scale = 0.15  // tune: fraction of drag velocity carried over
        orbBody.applyImpulse(dx: lastDragVelocity.x * scale,
                              dy: lastDragVelocity.y * scale)
        lastDragVelocity = .zero
    }

    // MARK: Tick

    /// Advance physics simulation. `target` is the orb's desired resting position.
    func tick(dt: Double, orbTarget: CGPoint) {
        if isDragging {
            // While dragging, orb follows cursor with very stiff spring.
            let dragConfig = SpringConfig(stiffness: 600, damping: 35, mass: 0.6)
            orbBody.config = dragConfig
            orbBody.step(dt: dt, target: orbTarget)
        } else {
            // Released — spring back toward rest with momentum.
            orbBody.config = .orb
            orbBody.step(dt: dt, target: orbTarget)
        }
        orbPosition = orbBody.position
    }

    func placeOrb(at point: CGPoint) {
        orbBody.teleport(to: point)
        orbPosition = point
    }
}
