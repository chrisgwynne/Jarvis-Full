import Foundation
import SwiftUI

// MARK: - GestureType

/// The physical hand gesture a user performs.
enum GestureType: String, CaseIterable, Codable {
    case pinch      = "pinch"
    case pinchHold  = "pinchHold"
    case openPalm   = "openPalm"
    case fist       = "fist"
    case twoHand    = "twoHand"
    case palmAway   = "palmAway"
    case shake      = "shake"
    case hoverDwell = "hoverDwell"

    var displayName: String {
        switch self {
        case .pinch:      return "Pinch"
        case .pinchHold:  return "Pinch + Hold"
        case .openPalm:   return "Open Palm"
        case .fist:       return "Fist"
        case .twoHand:    return "Two Hands"
        case .palmAway:   return "Palm Away"
        case .shake:      return "Shake"
        case .hoverDwell: return "Hover Dwell"
        }
    }

    var systemImage: String {
        switch self {
        case .pinch:      return "hand.pinch"
        case .pinchHold:  return "hand.pinch.fill"
        case .openPalm:   return "hand.raised"
        case .fist:       return "hand.fist"
        case .twoHand:    return "hands.sparkles"
        case .palmAway:   return "hand.thumbsdown"
        case .shake:      return "waveform"
        case .hoverDwell: return "cursorarrow.motionlines.click"
        }
    }
}

// MARK: - GestureAction

/// What happens when a gesture is recognised.
enum GestureAction: String, CaseIterable, Codable {
    case selectOrDrag     = "selectOrDrag"
    case grabWindow       = "grabWindow"
    case activateTracking = "activateTracking"
    case pauseTracking    = "pauseTracking"
    case resize           = "resize"
    case dismissHUD       = "dismissHUD"
    case openHUD          = "openHUD"
    case dwellClick       = "dwellClick"
    case none             = "none"

    var displayName: String {
        switch self {
        case .selectOrDrag:     return "Select / Drag"
        case .grabWindow:       return "Grab Window"
        case .activateTracking: return "Activate Tracking"
        case .pauseTracking:    return "Pause Tracking"
        case .resize:           return "Resize"
        case .dismissHUD:       return "Dismiss HUD"
        case .openHUD:          return "Open HUD"
        case .dwellClick:       return "Dwell Click"
        case .none:             return "None (disabled)"
        }
    }
}

// MARK: - GestureMapping

struct GestureMapping: Identifiable, Codable {
    var id:            UUID        = UUID()
    var gestureType:   GestureType
    var action:        GestureAction
    var isEnabled:     Bool        = true
    /// User-editable label shown in the HUD and debug overlay.
    var hudLabel:      String
    /// Optional voice phrase that triggers this gesture action.
    var commandPhrase: String      = ""
}

// MARK: - HUDItemConfig

struct HUDItemConfig: Identifiable, Codable {
    var id:          UUID   = UUID()
    var key:         String         // stable, never changes
    var label:       String         // user-editable
    var systemImage: String
    var isEnabled:   Bool   = true
}

// MARK: - SensitivityPreset

enum SensitivityPreset: String, CaseIterable, Codable {
    case calm       = "calm"
    case balanced   = "balanced"
    case responsive = "responsive"

    var displayName: String {
        switch self {
        case .calm:       return "Calm"
        case .balanced:   return "Balanced"
        case .responsive: return "Responsive"
        }
    }

    var description: String {
        switch self {
        case .calm:       return "Slowest, most deliberate — best for users with high tremor"
        case .balanced:   return "Default — works well for most users"
        case .responsive: return "Fastest — best for very precise, steady hands"
        }
    }

    /// Multiplier applied on top of the calibration-adapted pointer sensitivity.
    var sensitivityMultiplier: Double {
        switch self {
        case .calm:       return 0.70
        case .balanced:   return 1.00
        case .responsive: return 1.35
        }
    }

    /// Extra smoothing applied on top of calibration smoothing.
    var smoothingBoost: Double {
        switch self {
        case .calm:       return -0.03   // more aggressive smoothing (lower alpha)
        case .balanced:   return  0.00
        case .responsive: return +0.03   // less smoothing (higher alpha)
        }
    }
}

// MARK: - GestureCommandRegistry

/// Centralised store for gesture→action mappings, HUD labels, and related
/// user-editable configuration.  Persisted to
/// `~/Library/Application Support/JarvisMac/gesture_commands.json`.
@MainActor
final class GestureCommandRegistry: ObservableObject {
    static let shared = GestureCommandRegistry()

    @Published var mappings:          [GestureMapping]
    @Published var hudItems:          [HUDItemConfig]
    @Published var sensitivityPreset: SensitivityPreset = .balanced

    private let fileURL: URL

    // MARK: - Defaults

    static let defaultMappings: [GestureMapping] = [
        GestureMapping(gestureType: .pinch,      action: .selectOrDrag,     hudLabel: "Select"),
        GestureMapping(gestureType: .pinchHold,  action: .grabWindow,       hudLabel: "Grab"),
        GestureMapping(gestureType: .openPalm,   action: .activateTracking, hudLabel: "Activate"),
        GestureMapping(gestureType: .fist,       action: .pauseTracking,    hudLabel: "Pause"),
        GestureMapping(gestureType: .twoHand,    action: .resize,           hudLabel: "Resize"),
        GestureMapping(gestureType: .palmAway,   action: .dismissHUD,       hudLabel: "Dismiss"),
        GestureMapping(gestureType: .shake,      action: .none,             isEnabled: false,  hudLabel: "Shake"),
        GestureMapping(gestureType: .hoverDwell, action: .dwellClick,       hudLabel: "Dwell Click"),
    ]

    static let defaultHUDItems: [HUDItemConfig] = [
        HUDItemConfig(key: "news",    label: "News",    systemImage: "newspaper.fill"),
        HUDItemConfig(key: "camera",  label: "Camera",  systemImage: "camera.fill"),
        HUDItemConfig(key: "memory",  label: "Memory",  systemImage: "brain.head.profile"),
        HUDItemConfig(key: "debug",   label: "Debug",   systemImage: "cpu.fill"),
        HUDItemConfig(key: "close",   label: "Close",   systemImage: "xmark.circle.fill"),
        HUDItemConfig(key: "reset",   label: "Reset",   systemImage: "arrow.counterclockwise"),
        HUDItemConfig(key: "pin",     label: "Pin",     systemImage: "pin.fill"),
        HUDItemConfig(key: "expand",  label: "Expand",  systemImage: "arrow.up.left.and.arrow.down.right"),
    ]

    // MARK: - Init

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir  = support.appendingPathComponent("JarvisMac", isDirectory: true)
        fileURL  = dir.appendingPathComponent("gesture_commands.json")

        if let data    = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(RegistryStore.self, from: data) {
            mappings          = decoded.mappings
            hudItems          = decoded.hudItems
            sensitivityPreset = decoded.sensitivityPreset
        } else {
            mappings          = Self.defaultMappings
            hudItems          = Self.defaultHUDItems
            sensitivityPreset = .balanced
        }
    }

    // MARK: - Queries

    func action(for gesture: GestureType) -> GestureAction {
        mappings.first { $0.gestureType == gesture && $0.isEnabled }?.action ?? .none
    }

    func isEnabled(_ gesture: GestureType) -> Bool {
        mappings.first { $0.gestureType == gesture }?.isEnabled ?? false
    }

    func hudLabel(for gesture: GestureType) -> String {
        mappings.first { $0.gestureType == gesture }?.hudLabel ?? gesture.rawValue
    }

    /// HUD item label looked up by stable key (falls back to key if not found).
    func hudItemLabel(key: String) -> String {
        hudItems.first { $0.key == key }?.label ?? key
    }

    var enabledHUDItems: [HUDItemConfig] { hudItems.filter(\.isEnabled) }

    // MARK: - Editing

    func updateMapping(_ mapping: GestureMapping) {
        if let i = mappings.firstIndex(where: { $0.id == mapping.id }) {
            mappings[i] = mapping
        }
        save()
    }

    func updateHUDItem(_ item: HUDItemConfig) {
        if let i = hudItems.firstIndex(where: { $0.id == item.id }) {
            hudItems[i] = item
        }
        save()
    }

    func applyPreset(_ preset: SensitivityPreset) {
        sensitivityPreset = preset
        let cal = GestureCalibrationStore.shared.profile
        let base = cal.adaptedPointerSensitivity
        SpatialInteractionConfig.shared.pointerSensitivity = CGFloat(
            (base * preset.sensitivityMultiplier).clamped(to: 0.35...1.20)
        )
        let baseAlpha = cal.adaptedSmoothingAlpha
        let newAlpha = (baseAlpha + preset.smoothingBoost).clamped(to: 0.04...0.22)
        SpatialInteractionConfig.shared.smoothingAlpha = CGFloat(newAlpha)
        save()
    }

    func resetToDefaults() {
        mappings          = Self.defaultMappings
        hudItems          = Self.defaultHUDItems
        sensitivityPreset = .balanced
        save()
    }

    // MARK: - Persistence

    private struct RegistryStore: Codable {
        var mappings:          [GestureMapping]
        var hudItems:          [HUDItemConfig]
        var sensitivityPreset: SensitivityPreset
    }

    func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = RegistryStore(mappings: mappings,
                                  hudItems: hudItems,
                                  sensitivityPreset: sensitivityPreset)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Double clamped helper (file-private)

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double {
        Swift.max(r.lowerBound, Swift.min(r.upperBound, self))
    }
}
