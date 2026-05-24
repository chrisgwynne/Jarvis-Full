import Foundation
import SwiftUI
import Vision
import AVFoundation

// MARK: - DetectionClass

enum DetectionClass: String, Codable, CaseIterable {
    case person
    case face
    case vehicle
    case phone
    case laptop
    case backpack
    case surveillanceCamera
    case dog
    case cat
    case monitor
    case unknown

    var label: String {
        switch self {
        case .person:             return "PERSON"
        case .face:               return "FACE"
        case .vehicle:            return "VEHICLE"
        case .phone:              return "PHONE"
        case .laptop:             return "LAPTOP"
        case .backpack:           return "BACKPACK"
        case .surveillanceCamera: return "SURVEILLANCE"
        case .dog:                return "DOG"
        case .cat:                return "CAT"
        case .monitor:            return "MONITOR"
        case .unknown:            return "UNKNOWN"
        }
    }

    var poiColor: Color {
        switch self {
        case .person:             return .yellow
        case .face:               return Color(red: 0.0, green: 1.0, blue: 1.0) // cyan
        case .vehicle:            return .orange
        case .phone:              return Color(red: 0.6, green: 0.4, blue: 1.0)  // lavender
        case .laptop:             return Color(red: 0.4, green: 0.8, blue: 1.0)  // sky blue
        case .backpack:           return Color(red: 1.0, green: 0.6, blue: 0.2)  // amber
        case .surveillanceCamera: return .red
        case .dog:                return Color(red: 0.6, green: 1.0, blue: 0.4)  // lime
        case .cat:                return Color(red: 0.8, green: 0.6, blue: 1.0)  // pink-purple
        case .monitor:            return Color(red: 0.4, green: 0.9, blue: 0.8)  // teal
        case .unknown:            return .white
        }
    }

    var defaultThreat: ThreatLevel {
        switch self {
        case .surveillanceCamera: return .suspicious
        case .person:             return .normal
        case .face:               return .normal
        case .vehicle:            return .normal
        case .phone:              return .normal
        case .laptop:             return .normal
        case .backpack:           return .normal
        case .dog:                return .normal
        case .cat:                return .normal
        case .monitor:            return .normal
        case .unknown:            return .normal
        }
    }

    /// Whether this class is considered compatible with another for tracking purposes.
    func isCompatible(with other: DetectionClass) -> Bool {
        if self == other { return true }
        // face and person may overlap on the same physical target
        if (self == .face && other == .person) || (self == .person && other == .face) { return true }
        return false
    }
}

// MARK: - ThreatLevel

enum ThreatLevel: Int, Comparable, Codable, CaseIterable {
    case normal    = 0
    case suspicious = 1
    case alert     = 2

    static func < (lhs: ThreatLevel, rhs: ThreatLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: Color {
        switch self {
        case .normal:     return .yellow
        case .suspicious: return .orange
        case .alert:      return .red
        }
    }

    /// Short label shown on the bounding-box badge.
    var label: String {
        switch self {
        case .normal:     return "TRACKING"
        case .suspicious: return "SUSPICIOUS"
        case .alert:      return "ALERT"
        }
    }

    /// Longer system-level descriptor used in event logs.
    var systemLabel: String {
        switch self {
        case .normal:     return "OBSERVED"
        case .suspicious: return "CAUTION"
        case .alert:      return "THREAT"
        }
    }
}

// MARK: - RawDetection

/// A single bounding-box detection emitted from one frame of analysis.
/// `bounds` is in normalized coordinates with **top-left origin** (Vision coords already flipped).
struct RawDetection {
    let id: UUID
    let cls: DetectionClass
    /// Normalized rect, top-left origin.
    let bounds: CGRect
    let confidence: Float
    /// Monotonic host time from CACurrentMediaTime().
    let frameTimestamp: TimeInterval
    let cameraFeedID: UUID

    init(
        cls: DetectionClass,
        bounds: CGRect,
        confidence: Float,
        frameTimestamp: TimeInterval,
        cameraFeedID: UUID
    ) {
        self.id = UUID()
        self.cls = cls
        self.bounds = bounds
        self.confidence = confidence
        self.frameTimestamp = frameTimestamp
        self.cameraFeedID = cameraFeedID
    }
}

// MARK: - TrackedTarget

/// A temporally-persistent tracked object, produced and updated by `ObjectTracker`.
struct TrackedTarget: Identifiable, Equatable {
    let id: UUID
    var cls: DetectionClass
    /// Smoothed normalized bounding rect, top-left origin.
    var bounds: CGRect
    /// Lazily updated copy used for SwiftUI animation interpolation.
    var displayBounds: CGRect
    var confidence: Float
    /// Estimated velocity in normalized units per second.
    var velocity: CGVector
    var threatLevel: ThreatLevel
    let firstSeen: Date
    var lastSeen: Date
    /// True when the tracker is predicting position, not actively detecting.
    var isGhost: Bool
    var cameraFeedID: UUID
    /// Human-readable label like "UNKNOWN #3" or "TARGET 7".
    var trackLabel: String
    /// Number of consecutive frames with no matching detection.
    var missedFrames: Int

    var timeVisible: TimeInterval {
        lastSeen.timeIntervalSince(firstSeen)
    }

    static func == (lhs: TrackedTarget, rhs: TrackedTarget) -> Bool {
        lhs.id == rhs.id &&
        lhs.bounds == rhs.bounds &&
        lhs.threatLevel == rhs.threatLevel &&
        lhs.isGhost == rhs.isGhost &&
        lhs.missedFrames == rhs.missedFrames
    }

    static func makeLabel(cls: DetectionClass, sequence: Int) -> String {
        "\(cls.label) #\(sequence)"
    }
}

// MARK: - SceneEvent

/// A timestamped log entry describing what was detected in a camera feed.
struct SceneEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let cameraFeedID: UUID
    let cameraName: String
    /// Raw values of DetectionClass — stored as Strings for Codable compatibility.
    let detectedClasses: [String]
    let primaryThreat: ThreatLevel
    let description: String
    /// 0.0–1.0 magnitude of motion detected in this frame batch.
    let motionIntensity: Float

    init(
        cameraFeedID: UUID,
        cameraName: String,
        detectedClasses: [DetectionClass],
        primaryThreat: ThreatLevel,
        description: String,
        motionIntensity: Float
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.cameraFeedID = cameraFeedID
        self.cameraName = cameraName
        self.detectedClasses = detectedClasses.map { $0.rawValue }
        self.primaryThreat = primaryThreat
        self.description = description
        self.motionIntensity = motionIntensity
    }
}

// MARK: - FeedSource

enum FeedSource: Codable {
    case localWebcam(deviceUID: String?)
    case rtsp(url: String)
    case homeAssistant(entityID: String)

    // MARK: Codable

    private enum CodingKey: String, Swift.CodingKey {
        case type, deviceUID, url, entityID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKey.self)
        switch self {
        case .localWebcam(let uid):
            try container.encode("localWebcam", forKey: .type)
            try container.encodeIfPresent(uid, forKey: .deviceUID)
        case .rtsp(let url):
            try container.encode("rtsp", forKey: .type)
            try container.encode(url, forKey: .url)
        case .homeAssistant(let entityID):
            try container.encode("homeAssistant", forKey: .type)
            try container.encode(entityID, forKey: .entityID)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "localWebcam":
            let uid = try container.decodeIfPresent(String.self, forKey: .deviceUID)
            self = .localWebcam(deviceUID: uid)
        case "rtsp":
            let url = try container.decode(String.self, forKey: .url)
            self = .rtsp(url: url)
        case "homeAssistant":
            let entityID = try container.decode(String.self, forKey: .entityID)
            self = .homeAssistant(entityID: entityID)
        default:
            self = .localWebcam(deviceUID: nil)
        }
    }
}

// MARK: - CameraFeedDescriptor

struct CameraFeedDescriptor: Identifiable, Codable {
    let id: UUID
    var name: String
    var source: FeedSource
    var location: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        source: FeedSource,
        location: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.location = location
        self.isEnabled = isEnabled
    }
}

// MARK: - MotionZoneDescriptor

struct MotionZoneDescriptor: Identifiable, Codable {
    let id: UUID
    var name: String
    /// Normalized rect in top-left coordinate space.
    var normalizedRect: CGRect
    /// Motion magnitude (0–1) that triggers an alert for this zone.
    var sensitivityThreshold: Float
    var isArmed: Bool
    var cameraFeedID: UUID

    // MARK: Codable for CGRect

    private enum CodingKeys: String, CodingKey {
        case id, name, rectX, rectY, rectW, rectH, sensitivityThreshold, isArmed, cameraFeedID
    }

    init(
        id: UUID = UUID(),
        name: String,
        normalizedRect: CGRect,
        sensitivityThreshold: Float = 0.15,
        isArmed: Bool = true,
        cameraFeedID: UUID
    ) {
        self.id = id
        self.name = name
        self.normalizedRect = normalizedRect
        self.sensitivityThreshold = sensitivityThreshold
        self.isArmed = isArmed
        self.cameraFeedID = cameraFeedID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(Double(normalizedRect.origin.x), forKey: .rectX)
        try c.encode(Double(normalizedRect.origin.y), forKey: .rectY)
        try c.encode(Double(normalizedRect.size.width), forKey: .rectW)
        try c.encode(Double(normalizedRect.size.height), forKey: .rectH)
        try c.encode(sensitivityThreshold, forKey: .sensitivityThreshold)
        try c.encode(isArmed, forKey: .isArmed)
        try c.encode(cameraFeedID, forKey: .cameraFeedID)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let x = try c.decode(Double.self, forKey: .rectX)
        let y = try c.decode(Double.self, forKey: .rectY)
        let w = try c.decode(Double.self, forKey: .rectW)
        let h = try c.decode(Double.self, forKey: .rectH)
        normalizedRect = CGRect(x: x, y: y, width: w, height: h)
        sensitivityThreshold = try c.decode(Float.self, forKey: .sensitivityThreshold)
        isArmed = try c.decode(Bool.self, forKey: .isArmed)
        cameraFeedID = try c.decode(UUID.self, forKey: .cameraFeedID)
    }
}

// MARK: - DetectionFrame

/// The complete output of a single pipeline analysis pass.
struct DetectionFrame {
    let timestamp: TimeInterval
    let cameraFeedID: UUID
    let rawDetections: [RawDetection]
    /// 0.0–1.0 magnitude of pixel-level motion compared to previous frame.
    let motionIntensity: Float
}
