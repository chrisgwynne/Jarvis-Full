import Foundation

// MARK: - OverlaySceneManager

/// Legacy bridge kept for ⌘⇧S keyboard shortcut compatibility.
///
/// Spatial interaction is no longer a discrete "mode" — `SpatialAmbientCoordinator`
/// runs passively as part of `CommandCentreView` and activates automatically
/// when a hand is detected. This class now opens the spatial diagnostics overlay
/// (`.spatialHUD`) when toggled, giving the user a read-only window into the
/// live coordinator state.
///
/// Wire-up (in JarvisController bootstrap):
/// ```swift
/// spatialOverlay.overlayManager = overlayManager
/// ```
@MainActor
final class OverlaySceneManager: ObservableObject {

    var overlayManager: OverlayManager?

    var isVisible: Bool { overlayManager?.isOpen(.spatialHUD) ?? false }

    // MARK: Show / Hide / Toggle

    /// Opens the spatial diagnostics overlay (read-only).
    func show() { overlayManager?.open(.spatialHUD) }

    /// Closes the diagnostics overlay. Does NOT stop ambient tracking.
    func hide() { _ = overlayManager?.close(.spatialHUD) }

    func toggle() { isVisible ? hide() : show() }
}
