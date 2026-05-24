import Foundation
import SwiftUI
import AVFoundation

// MARK: - VisionModule
// Central coordinator for the POI visual intelligence system.
// Owned by JarvisController. Exposes state to SwiftUI via @Observable.

@MainActor @Observable final class VisionModule {

    static let shared = VisionModule()

    // MARK: Sub-services (readable from UI)

    let cameraFeedManager = CameraFeedManager()
    let rtspStreamManager = RTSPStreamManager()
    let tracker = ObjectTracker()
    let smoother = DetectionSmoother()
    let sceneMemory = SceneMemoryStore.shared
    let threatClassifier = ThreatClassifier()
    let motionZoneEngine = MotionZoneEngine()
    let settings = VisionSettings.shared

    // MARK: State

    private(set) var isRunning: Bool = false
    private(set) var activeFeedCount: Int = 0
    private(set) var allActiveTargets: [TrackedTarget] = []

    // Per-feed targets (feedID → targets)
    private var feedTargets: [UUID: [TrackedTarget]] = [:]

    // Pipeline actor
    private let pipeline: VisionDetectionPipeline

    // Scene event debounce
    private var lastEventDate: [UUID: Date] = [:]
    private let eventDebounce: TimeInterval = 8.0

    // Threat escalation tracking — fires onThreatEscalated only when level increases
    // and respects a per-level cooldown to prevent per-frame alert spam.
    private var lastCommittedThreatLevel: ThreatLevel = .normal
    private var lastThreatEscalationTime: Date = .distantPast
    private let threatEscalationCooldown: TimeInterval = 30.0

    // MARK: Init

    private init() {
        pipeline = VisionDetectionPipeline(processEveryNthFrame: VisionSettings.shared.processEveryNthFrame)

        // Wire detection callback back to MainActor
        Task { [weak self] in
            guard let self = self else { return }
            await self.pipeline.setDetectionCallback { [weak self] frame in
                Task { @MainActor [weak self] in
                    self?.handleDetectionFrame(frame)
                }
            }
        }

        // Wire camera feed manager to pipeline
        cameraFeedManager.pipeline = pipeline

        // Wire RTSP manager to pipeline
        rtspStreamManager.pipeline = pipeline

        // Wire motion zone callback
        Task { [weak self] in
            guard let self = self else { return }
            await self.motionZoneEngine.setCallback { [weak self] zone, intensity in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // Proactivity signal for motion
                    self.handleMotionZoneTrigger(zone: zone, intensity: intensity)
                }
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        print("[VisionModule] Starting — feeds: \(cameraFeedManager.feeds.count)")
        isRunning = true
        loadConfiguredFeeds()
        cameraFeedManager.startAll()
        startRTSPFeeds()
        updateFeedCount()
    }

    func stop() {
        print("[VisionModule] Stopping — active RTSP loops: \(rtspStreamManager.activeLoopCount)")
        guard isRunning else { return }
        isRunning = false
        cameraFeedManager.stopAll()
        rtspStreamManager.stopAllDetectionLoops()
        tracker.reset()
        feedTargets.removeAll()
        allActiveTargets = []
        activeFeedCount = 0
        lastCommittedThreatLevel = .normal
        lastThreatEscalationTime = .distantPast
        print("[VisionModule] Stopped")
    }

    func toggleSurveillance() {
        if isRunning { stop() } else { start() }
    }

    // MARK: - Feed Management

    private func loadConfiguredFeeds() {
        let configured = settings.feeds
        if configured.isEmpty {
            // Add default webcam feed
            let defaultFeed = cameraFeedManager.makeDefaultWebcamFeed()
            cameraFeedManager.addFeed(defaultFeed)
        } else {
            for feed in configured {
                switch feed.source {
                case .localWebcam:
                    cameraFeedManager.addFeed(feed)
                case .rtsp(let url):
                    cameraFeedManager.addFeed(feed)
                    rtspStreamManager.addStream(feedID: feed.id, url: url)
                case .homeAssistant:
                    cameraFeedManager.addFeed(feed) // HA snapshot-based
                }
            }
        }
    }

    private func startRTSPFeeds() {
        for feed in settings.feeds {
            if case .rtsp(let url) = feed.source {
                rtspStreamManager.addStream(feedID: feed.id, url: url)
                rtspStreamManager.startDetectionLoop(feedID: feed.id, intervalSeconds: 0.5)
            }
        }
    }

    func addRTSPFeed(name: String, url: String, location: String) {
        let feed = CameraFeedDescriptor(
            id: UUID(),
            name: name,
            source: .rtsp(url: url),
            location: location,
            isEnabled: true
        )
        settings.feeds.append(feed)
        settings.save()
        if isRunning {
            rtspStreamManager.addStream(feedID: feed.id, url: url)
            rtspStreamManager.startDetectionLoop(feedID: feed.id, intervalSeconds: 0.5)
        }
    }

    func removeRTSPFeed(id: UUID) {
        settings.feeds.removeAll { $0.id == id }
        settings.save()
        rtspStreamManager.removeStream(feedID: id)
    }

    private func updateFeedCount() {
        activeFeedCount = cameraFeedManager.feeds.filter { $0.isEnabled }.count
    }

    // MARK: - Detection Handling

    private func handleDetectionFrame(_ frame: DetectionFrame) {
        guard isRunning else { return }
        // 1. Update tracker
        tracker.update(with: frame)
        // 2. Smoother pass on tracker targets
        var updatedTargets = tracker.allTargets(for: frame.cameraFeedID)
        updatedTargets = updatedTargets.filter { t in
            var mut = t
            return smoother.update(target: &mut)
        }
        // 3. Threat classification
        updatedTargets = threatClassifier.classify(targets: updatedTargets)
        // 3a. Threat escalation callback — fire when scene threat level increases
        //     and the per-level cooldown has expired, preventing per-frame spam.
        maybeTriggerThreatEscalation(feedID: frame.cameraFeedID)
        // 4. Store per-feed
        feedTargets[frame.cameraFeedID] = updatedTargets
        // 5. Update flat allActiveTargets
        allActiveTargets = feedTargets.values.flatMap { $0 }
        // 6. Scene event logging (debounced)
        maybeLogSceneEvent(feedID: frame.cameraFeedID, targets: updatedTargets, motionIntensity: frame.motionIntensity)
        // 7. Motion zones
        guard isRunning else { return }
        Task {
            await motionZoneEngine.evaluate(
                detections: frame.rawDetections,
                motionIntensity: frame.motionIntensity,
                timestamp: frame.timestamp
            )
        }
    }

    private func maybeLogSceneEvent(feedID: UUID, targets: [TrackedTarget], motionIntensity: Float) {
        guard !targets.filter({ !$0.isGhost }).isEmpty else { return }
        let now = Date()
        let lastEvent = lastEventDate[feedID] ?? .distantPast
        guard now.timeIntervalSince(lastEvent) > eventDebounce else { return }
        lastEventDate[feedID] = now

        let feedName = settings.feeds.first(where: { $0.id == feedID })?.name
            ?? cameraFeedManager.feeds.first(where: { $0.id == feedID })?.name
            ?? "Camera"
        let event = sceneMemory.makeEvent(
            cameraFeedID: feedID,
            cameraName: feedName,
            targets: targets.filter { !$0.isGhost },
            motionIntensity: motionIntensity
        )
        sceneMemory.record(event)
    }

    private func handleMotionZoneTrigger(zone: MotionZoneDescriptor, intensity: Float) {
        // Surface as proactivity signal (connected by JarvisController)
        onMotionZoneTriggered?(zone, intensity)
    }

    /// Fire `onThreatEscalated` when the scene threat level has risen above the last
    /// committed level AND the cooldown period has elapsed since the previous escalation.
    ///
    /// - Only fires for `.suspicious` and above (never for `.normal`).
    /// - Only fires on a level *increase* so a sustained threat doesn't re-fire every frame.
    /// - The 30-second cooldown prevents alert spam if the level fluctuates rapidly around
    ///   a boundary (e.g. `.normal` ↔ `.suspicious` on consecutive frames).
    private func maybeTriggerThreatEscalation(feedID: UUID) {
        let currentLevel = threatClassifier.sceneThreatLevel

        // Only escalate — never fire for .normal, never fire if level hasn't increased.
        guard currentLevel >= .suspicious,
              currentLevel > lastCommittedThreatLevel else {
            // If the threat has dropped back to normal, reset the committed level so a
            // future rise will fire again even if the cooldown hasn't expired.
            if currentLevel == .normal {
                lastCommittedThreatLevel = .normal
            }
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastThreatEscalationTime) > threatEscalationCooldown else {
            return
        }

        // Build a description that includes the camera feed name and the classifier's reason.
        let feedName = settings.feeds.first(where: { $0.id == feedID })?.name
            ?? cameraFeedManager.feeds.first(where: { $0.id == feedID })?.name
            ?? "Camera"
        let reason = threatClassifier.threatReason.isEmpty
            ? "\(currentLevel.label) detected on \(feedName)"
            : "\(threatClassifier.threatReason) — \(feedName)"

        // Commit state before invoking callback so re-entrant calls are safe.
        lastCommittedThreatLevel = currentLevel
        lastThreatEscalationTime = now

        onThreatEscalated?(currentLevel, reason)
    }

    // Callback set by JarvisController to bridge into ProactivityEngine
    var onMotionZoneTriggered: ((MotionZoneDescriptor, Float) -> Void)? = nil
    var onThreatEscalated: ((ThreatLevel, String) -> Void)? = nil

    // MARK: - Query API (for JarvisController conversational responses)

    func targets(for feedID: UUID) -> [TrackedTarget] {
        feedTargets[feedID] ?? []
    }

    func latestFrame(for feedID: UUID) -> CGImage? {
        cameraFeedManager.latestFrames[feedID]
    }

    var activeFeedDescriptors: [CameraFeedDescriptor] {
        cameraFeedManager.feeds.filter { $0.isEnabled }
    }

    /// Describe current scene in natural language (for LLM / spoken response)
    func describeCurrentScene() -> String {
        let targets = allActiveTargets.filter { !$0.isGhost }
        if targets.isEmpty {
            return "No activity detected on any camera feed."
        }

        var classCounts: [DetectionClass: Int] = [:]
        for t in targets { classCounts[t.cls, default: 0] += 1 }

        let parts = classCounts.sorted(by: { $0.key.label < $1.key.label }).map { cls, count in
            "\(count) \(cls.label.lowercased())\(count > 1 ? "s" : "")"
        }.joined(separator: ", ")

        let threat = threatClassifier.sceneThreatLevel
        let suffix = threat > .normal ? " Threat level: \(threat.label)." : ""
        return "I can see \(parts) across \(activeFeedCount) camera feed\(activeFeedCount == 1 ? "" : "s").\(suffix)"
    }

    /// Answer "who is at the door?" style queries
    func describeActivity(at location: String) -> String {
        let matchedFeeds = settings.feeds.filter {
            $0.location.localizedCaseInsensitiveContains(location)
        }
        guard !matchedFeeds.isEmpty else {
            return "I don't have a camera configured for \(location)."
        }
        let targets = matchedFeeds.flatMap { [self] feed in self.targets(for: feed.id) }.filter { !$0.isGhost }
        if targets.isEmpty {
            return "Nothing detected at \(location) right now."
        }
        var classCounts: [DetectionClass: Int] = [:]
        for t in targets { classCounts[t.cls, default: 0] += 1 }
        let parts = classCounts.map { "\($1) \($0.label.lowercased())" }.joined(separator: ", ")
        return "At \(location): \(parts)."
    }

    /// Recent event summary for LLM context injection
    func recentActivitySummary() -> String {
        sceneMemory.recentSummary(limit: 6)
    }

    // MARK: - RTSP diagnostics

    var activeRTSPLoopCount: Int { rtspStreamManager.activeLoopCount }
    var activeRTSPFeedIDs: [UUID] { rtspStreamManager.activeLoopFeedIDs }

    // MARK: - CoreML model loading

    func loadCoreMLModel(at path: String) {
        let url = URL(fileURLWithPath: path)
        Task {
            try? await pipeline.loadCoreMLModel(at: url)
        }
    }

    // MARK: - Stop all RTSP loops

    private func stopAllRTSPLoops() {
        for feed in settings.feeds {
            if case .rtsp = feed.source {
                rtspStreamManager.stopDetectionLoop(feedID: feed.id)
            }
        }
    }
}

// RTSPStreamManager.stopAllDetectionLoops() is defined in RTSPStreamManager.swift
