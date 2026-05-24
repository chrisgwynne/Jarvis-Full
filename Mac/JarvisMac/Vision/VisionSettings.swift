import Foundation
import SwiftUI

// MARK: - VisionSettings

/// Persistent configuration for the entire Person-of-Interest visual intelligence system.
///
/// All properties are @Observable. Callers are responsible for calling `save()` after
/// mutating values (typically in a `.onChange` modifier or dedicated settings view action).
/// `load()` is called automatically in `init()`.
@MainActor @Observable final class VisionSettings {

    // MARK: - Singleton

    static let shared = VisionSettings()

    // MARK: - Master enable

    var surveillanceEnabled: Bool = false

    // MARK: - Detection

    var personDetectionEnabled: Bool = true
    var faceDetectionEnabled: Bool = true
    /// Requires a CoreML model to be present at `coreMLModelPath`.
    var objectDetectionEnabled: Bool = false
    /// Absolute path to a YOLOv8 `.mlpackage` bundle.
    var coreMLModelPath: String? = nil

    // MARK: - Performance

    /// Process 1 out of every N frames. Range: 1 (every frame) … 8 (every 8th).
    var processEveryNthFrame: Int = 4
    /// Maximum number of simultaneous feeds the pipeline services.
    var maxSimultaneousFeeds: Int = 4
    /// Automatically reduces frame cadence during low-motion periods.
    var adaptiveFPSEnabled: Bool = true

    // MARK: - Thresholds

    var personConfidenceThreshold: Float = 0.55
    var faceConfidenceThreshold: Float = 0.60
    /// How long (seconds) a threat-level target remains visible after its last detection.
    var threatLingerSeconds: TimeInterval = 30.0

    // MARK: - Visual style

    var showScanlines: Bool = true
    var showGrid: Bool = true
    var showMotionZones: Bool = false
    var showConfidenceValues: Bool = true
    var showVelocityVectors: Bool = false
    /// 0.0 (fully transparent) … 1.0 (fully opaque) for the detection overlay.
    var overlayOpacity: Double = 0.92

    // MARK: - Alerts

    var alertsEnabled: Bool = true
    var alertOnNewPerson: Bool = true
    var alertOnSuspicious: Bool = true
    var alertOnAlert: Bool = true
    var quietHoursEnabled: Bool = false
    /// Quiet-hours window start, in 24-hour clock (0–23).
    var quietHoursStart: Int = 23
    /// Quiet-hours window end, in 24-hour clock (0–23).
    var quietHoursEnd: Int = 7

    // MARK: - Camera feeds & motion zones (persisted)

    var feeds: [CameraFeedDescriptor] = []
    var motionZones: [MotionZoneDescriptor] = []

    // MARK: - Persistence

    private let persistURL: URL

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        let directory = appSupport.appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        persistURL = directory.appendingPathComponent("vision_settings.json")
        load()
    }

    // MARK: - Save

    func save() {
        let persisted = PersistedSettings(
            surveillanceEnabled: surveillanceEnabled,
            personDetectionEnabled: personDetectionEnabled,
            faceDetectionEnabled: faceDetectionEnabled,
            objectDetectionEnabled: objectDetectionEnabled,
            coreMLModelPath: coreMLModelPath,
            processEveryNthFrame: processEveryNthFrame,
            maxSimultaneousFeeds: maxSimultaneousFeeds,
            adaptiveFPSEnabled: adaptiveFPSEnabled,
            personConfidenceThreshold: personConfidenceThreshold,
            faceConfidenceThreshold: faceConfidenceThreshold,
            threatLingerSeconds: threatLingerSeconds,
            showScanlines: showScanlines,
            showGrid: showGrid,
            showMotionZones: showMotionZones,
            showConfidenceValues: showConfidenceValues,
            showVelocityVectors: showVelocityVectors,
            overlayOpacity: overlayOpacity,
            alertsEnabled: alertsEnabled,
            alertOnNewPerson: alertOnNewPerson,
            alertOnSuspicious: alertOnSuspicious,
            alertOnAlert: alertOnAlert,
            quietHoursEnabled: quietHoursEnabled,
            quietHoursStart: quietHoursStart,
            quietHoursEnd: quietHoursEnd,
            feeds: feeds,
            motionZones: motionZones
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(persisted)
            try data.write(to: persistURL, options: .atomic)
        } catch {
            Log.vision.error("[VisionSettings] save failed: \(error)")
        }
    }

    // MARK: - Load

    func load() {
        guard FileManager.default.fileExists(atPath: persistURL.path) else { return }

        do {
            let data = try Data(contentsOf: persistURL)
            let persisted = try JSONDecoder().decode(PersistedSettings.self, from: data)
            apply(persisted)
        } catch {
            Log.vision.warning("[VisionSettings] load failed (using defaults): \(error)")
        }
    }

    // MARK: - Private helpers

    private func apply(_ p: PersistedSettings) {
        surveillanceEnabled        = p.surveillanceEnabled
        personDetectionEnabled     = p.personDetectionEnabled
        faceDetectionEnabled       = p.faceDetectionEnabled
        objectDetectionEnabled     = p.objectDetectionEnabled
        coreMLModelPath            = p.coreMLModelPath
        processEveryNthFrame       = p.processEveryNthFrame
        maxSimultaneousFeeds       = p.maxSimultaneousFeeds
        adaptiveFPSEnabled         = p.adaptiveFPSEnabled
        personConfidenceThreshold  = p.personConfidenceThreshold
        faceConfidenceThreshold    = p.faceConfidenceThreshold
        threatLingerSeconds        = p.threatLingerSeconds
        showScanlines              = p.showScanlines
        showGrid                   = p.showGrid
        showMotionZones            = p.showMotionZones
        showConfidenceValues       = p.showConfidenceValues
        showVelocityVectors        = p.showVelocityVectors
        overlayOpacity             = p.overlayOpacity
        alertsEnabled              = p.alertsEnabled
        alertOnNewPerson           = p.alertOnNewPerson
        alertOnSuspicious          = p.alertOnSuspicious
        alertOnAlert               = p.alertOnAlert
        quietHoursEnabled          = p.quietHoursEnabled
        quietHoursStart            = p.quietHoursStart
        quietHoursEnd              = p.quietHoursEnd
        feeds                      = p.feeds
        motionZones                = p.motionZones
    }

    // MARK: - Codable bridge

    private struct PersistedSettings: Codable {
        // Detection
        var surveillanceEnabled: Bool
        var personDetectionEnabled: Bool
        var faceDetectionEnabled: Bool
        var objectDetectionEnabled: Bool
        var coreMLModelPath: String?

        // Performance
        var processEveryNthFrame: Int
        var maxSimultaneousFeeds: Int
        var adaptiveFPSEnabled: Bool

        // Thresholds
        var personConfidenceThreshold: Float
        var faceConfidenceThreshold: Float
        var threatLingerSeconds: TimeInterval

        // Visual style
        var showScanlines: Bool
        var showGrid: Bool
        var showMotionZones: Bool
        var showConfidenceValues: Bool
        var showVelocityVectors: Bool
        var overlayOpacity: Double

        // Alerts
        var alertsEnabled: Bool
        var alertOnNewPerson: Bool
        var alertOnSuspicious: Bool
        var alertOnAlert: Bool
        var quietHoursEnabled: Bool
        var quietHoursStart: Int
        var quietHoursEnd: Int

        // Feeds & zones
        var feeds: [CameraFeedDescriptor]
        var motionZones: [MotionZoneDescriptor]
    }
}
