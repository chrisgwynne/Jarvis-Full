import Foundation
import SwiftUI
import Combine
import AVFoundation

// MARK: - SpatialHUDAction

/// Actions the radial HUD menu can trigger on pinch-select or dwell.
enum SpatialHUDAction: CaseIterable {
    case openNews
    case openCamera
    case openMemory
    case openDiagnostics
    case closeOverlay
    case resetView
    case pinOverlay
    case maximizeOverlay

    var label: String {
        switch self {
        case .openNews:        return "News"
        case .openCamera:      return "Camera"
        case .openMemory:      return "Memory"
        case .openDiagnostics: return "Debug"
        case .closeOverlay:    return "Close"
        case .resetView:       return "Reset"
        case .pinOverlay:      return "Pin"
        case .maximizeOverlay: return "Expand"
        }
    }

    var systemImage: String {
        switch self {
        case .openNews:        return "newspaper.fill"
        case .openCamera:      return "camera.fill"
        case .openMemory:      return "brain.head.profile"
        case .openDiagnostics: return "cpu.fill"
        case .closeOverlay:    return "xmark.circle.fill"
        case .resetView:       return "arrow.counterclockwise"
        case .pinOverlay:      return "pin.fill"
        case .maximizeOverlay: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

// MARK: - SpatialPresenceState

/// Tracks how engaged the user's hand is with the spatial layer.
enum SpatialPresenceState: Equatable {
    case noHand       // nothing detected — layer is invisible
    case handDetected // hand visible — cursor active
    case pinchActive  // pinching — cursor contracts, no HUD yet
    case hudOpen      // HUD menu visible — waiting for release
}

// MARK: - SpatialResizePhase

/// Tracks the two-hand resize gesture lifecycle.
///
/// The deliberate gating prevents accidental resize:
///   disabled → candidate : secondary hand appears with confidence + stability
///   candidate → resizing : BOTH dwell requirement met AND hands are stable
///   any → disabled       : secondary hand lost, confidence drops, or hands erratic
enum SpatialResizePhase: Equatable {
    case disabled                     // one hand, HUD open, or drag active
    case candidate(dwellFrames: Int)  // second hand eligible; counting dwell
    case resizing                     // confirmed — actively resizing
}

// MARK: - SpatialAmbientCoordinator

/// Ambient spatial interaction layer coordinator.
///
/// **Stability improvements in this version:**
/// - Gesture state machine now requires dwell frames for every state transition.
/// - Two-hand resize requires: secondary hand stable for ≥500 ms, BOTH hands
///   low-velocity for a dwell period, AND a focused overlay must be hovered.
/// - Face-contact suppression: hands overlapping the face exclusion zone are
///   ineligible for all gestures.
/// - Dominant hand lock: rapid left↔right swapping is prevented.
/// - Cursor engine now uses deadzone + jump clamp + sensitivity scaling.
@MainActor
final class SpatialAmbientCoordinator: ObservableObject {

    // MARK: - Subsystems (readable by diagnostics views)

    let tracker  = HandTrackingEngine()
    let physics  = InteractionPhysics()

    private let gestures              = GestureClassifier()
    private let cursorEngine          = SpatialCursorEngine()
    private let secondaryCursorEngine = SpatialCursorEngine()
    private let motionDetector        = AccidentalMotionDetector()
    let calibration                   = GestureCalibrationStore.shared
    let gestureRegistry               = GestureCommandRegistry.shared

    // MARK: - Published state

    @Published private(set) var presenceState: SpatialPresenceState = .noHand
    @Published private(set) var cursorState    = SpatialCursorState()
    @Published private(set) var isHUDOpen      = false
    @Published private(set) var hudAnchor      = CGPoint.zero
    @Published private(set) var highlightedItemIndex: Int? = nil
    @Published private(set) var orbIsHovered   = false
    @Published private(set) var orbIsPinched   = false

    @Published private(set) var hoveredOverlayID:   UUID? = nil
    @Published private(set) var draggingOverlayID:  UUID? = nil

    @Published private(set) var dwellItemIndex: Int?   = nil
    @Published private(set) var dwellProgress:  Double = 0

    @Published private(set) var secondaryCursorState = SpatialCursorState()
    @Published private(set) var spreadGestureActive  = false

    // Diagnostics
    @Published private(set) var trackingFPS:        Int    = 0
    @Published private(set) var trackingConfidence: Float  = 0
    @Published private(set) var cameraSource:       String = "none"
    @Published private(set) var isTrackingActive:   Bool   = false
    @Published private(set) var lastError:          String? = nil
    @Published private(set) var currentGesture:     SpatialGestureState = .idle
    @Published          var     isEnabled:           Bool   = true {
        didSet { if !isEnabled { _pauseTracking() } else { _resumeTracking() } }
    }

    /// When true, the secondary hand is ignored entirely — no resize, no second
    /// cursor. Set by overlays that use both hands for their own input (e.g. ping pong).
    var suppressSecondHandGestures: Bool = false

    // ── Calibration ────────────────────────────────────────────────────────

    /// Raw Vision-space indexTip (0–1, Y-up) for the current frame.
    /// Read by `HandCalibrationView` when the user confirms a target point.
    @Published private(set) var rawVisionPoint: CGPoint = .zero

    /// True while the calibration overlay is active.
    /// Suppresses gesture processing so pinches/HUD don't trigger.
    @Published var isCalibrating: Bool = false {
        didSet {
            if isCalibrating {
                cursorEngine.reset()
                secondaryCursorEngine.reset()
                gestures.reset()
            }
        }
    }

    // ── Debug / diagnostics (surfaced in SpatialDiagnosticsOverlay) ────────
    @Published private(set) var dbgHandCount:             Int    = 0
    @Published private(set) var dbgPrimaryConf:           Float  = 0
    @Published private(set) var dbgSecondaryConf:         Float  = 0
    @Published private(set) var dbgSecondStableFrames:    Int    = 0
    @Published private(set) var dbgResizePhase:           String = "disabled"
    @Published private(set) var dbgResizeReason:          String = "—"
    @Published private(set) var dbgFaceDetected:          Bool   = false
    @Published private(set) var dbgPrimaryFaceSuppressed: Bool   = false
    @Published private(set) var dbgSecondFaceSuppressed:  Bool   = false
    @Published private(set) var dbgFaceSuppressionReason: String = "—"
    @Published private(set) var dbgRawCursorPos:          CGPoint = .zero
    @Published private(set) var dbgSmoothedCursorPos:     CGPoint = .zero
    @Published private(set) var dbgVelocityMagnitude:     CGFloat = 0
    @Published private(set) var dbgSecondHandRejection:   String  = "—"

    // ── Adaptive scoring diagnostics ─────────────────────────────────────
    @Published private(set) var dbgEligibilityScore:      Float   = 0
    @Published private(set) var dbgIntentScore:           Float   = 0
    @Published private(set) var dbgGestureLikelihood:     Float   = 0
    @Published private(set) var dbgSuppressionReason:     String  = "—"
    @Published private(set) var dbgIsAccidentalMotion:    Bool    = false
    @Published private(set) var dbgMotionConfidence:      Float   = 0
    @Published private(set) var dbgCalibFrames:           Int     = 0
    @Published private(set) var dbgCalibAdaptedAt:        String  = "never"
    @Published private(set) var dbgLearnedPinchDist:      String  = "—"
    @Published private(set) var dbgLearnedDeadzone:       String  = "—"
    @Published private(set) var dbgLearnedSmoothing:      String  = "—"
    @Published private(set) var dbgLearnedPointerSens:    String  = "—"
    @Published private(set) var dbgLearnedSecondDwell:    String  = "—"

    // MARK: - Configuration

    var viewSize: CGSize = .zero {
        didSet {
            cursorEngine.viewSize          = viewSize
            secondaryCursorEngine.viewSize = viewSize
        }
    }
    var orbRestPosition: CGPoint = CGPoint(x: 200, y: 200)
    var hoverRadius:     CGFloat = 80

    // MARK: - Callbacks

    var onHUDAction:    ((SpatialHUDAction) -> Void)?
    var onOverlayMove:  ((UUID, CGRect) -> Void)?
    var onOverlayResize:((UUID, CGSize) -> Void)?

    // MARK: - Private — camera

    private weak var cameraManager: CameraManager?
    private var fallbackPipeline:   CameraPipeline?
    private var cancellables =      Set<AnyCancellable>()

    // MARK: - Private — adaptive FPS

    private var frameCounter: Int = 0
    private let idleFrameSkip:   Int = 12
    private let activeFrameSkip: Int = 1

    private var currentFrameSkip: Int {
        if isCalibrating { return 1 }
        return presenceState == .noHand ? idleFrameSkip : activeFrameSkip
    }

    // MARK: - Private — physics / display timer

    private var displayTimer:    Timer?
    private var lastTickTime:    Date = Date()
    private var fpsCounter:      Int  = 0
    private var fpsWindowStart:  Date = Date()

    // MARK: - Private — hand presence fade

    private var handLastSeenAt:      Date? = nil
    private let handLossFadeDuration: TimeInterval = 0.8

    // MARK: - Private — overlay context

    private var overlayFrames:    [UUID: CGRect] = [:]
    private var focusedOverlayID: UUID?           = nil

    // MARK: - Private — pinch drag state

    private var dragStartCursorPos: CGPoint? = nil
    private var dragStartFrame:     CGRect?  = nil

    // MARK: - Private — throw physics

    private struct VelocitySample { let pos: CGPoint; let time: Date }
    private var velocityHistory:  [VelocitySample] = []
    private let velocityWindowSize = 8
    private let throwThreshold: CGFloat = 300

    // MARK: - Private — dwell-click

    private var dwellStartedAt:   Date? = nil
    private var lastDwellIndex:   Int?  = nil
    private let dwellDuration:    TimeInterval = 1.5

    // MARK: - Private — two-hand resize (deliberate gating)

    private var resizePhase:       SpatialResizePhase = .disabled
    private var spreadBaseDistance: CGFloat? = nil
    private var spreadBaseSize:     CGSize?  = nil
    private var lastPointerSpeed:   CGFloat  = 0   // for stability check

    // MARK: - Private — face suppression exit dwell

    private var primaryFaceExitFrames:  Int = 0
    private var secondFaceExitFrames:   Int = 0

    // MARK: - Contextual HUD items

    var currentHUDItems: [SpatialHUDAction] {
        if focusedOverlayID != nil {
            return [.openNews, .openCamera, .openMemory,
                    .pinOverlay, .maximizeOverlay, .closeOverlay]
        }
        return [.openNews, .openCamera, .openMemory,
                .openDiagnostics, .closeOverlay, .resetView]
    }

    // MARK: - Start / Stop

    func start(cameraManager: CameraManager?) async {
        stop()
        self.cameraManager = cameraManager
        // Apply persisted spatial calibration to both cursor engines.
        if let calib = HandCalibrationStore.shared.calibration {
            cursorEngine.calibration          = calib
            secondaryCursorEngine.calibration = calib
        }
        guard isEnabled else { cameraSource = "disabled"; return }

        if let cm = cameraManager, cm.isRunning {
            cm.pixelBufferTap = { [weak self] buffer in self?.handleRawFrame(buffer) }
            cameraSource = "shared"
        } else {
            let pipeline = CameraPipeline()
            fallbackPipeline = pipeline
            await pipeline.start()
            if let err = pipeline.error {
                lastError    = err
                cameraSource = "error"
            } else {
                cameraSource = "standalone"
                observeFallbackCamera(pipeline)
            }
        }
        observeTracker()
        startPhysicsTick()
    }

    func stop() {
        cameraManager?.pixelBufferTap = nil
        cameraManager = nil
        fallbackPipeline?.stop()
        fallbackPipeline = nil
        cancellables.removeAll()
        displayTimer?.invalidate()
        displayTimer = nil

        tracker.reset()
        gestures.reset()
        cursorEngine.reset()
        secondaryCursorEngine.reset()
        motionDetector.reset()

        presenceState        = .noHand
        isHUDOpen            = false
        highlightedItemIndex = nil
        orbIsPinched         = false
        orbIsHovered         = false
        isTrackingActive     = false
        cameraSource         = "none"
        handLastSeenAt       = nil
        frameCounter         = 0

        hoveredOverlayID     = nil
        draggingOverlayID    = nil
        dragStartCursorPos   = nil
        dragStartFrame       = nil
        velocityHistory      = []

        dwellStartedAt       = nil
        lastDwellIndex       = nil
        dwellItemIndex       = nil
        dwellProgress        = 0

        secondaryCursorState = SpatialCursorState()
        spreadGestureActive  = false
        resizePhase          = .disabled
        spreadBaseDistance   = nil
        spreadBaseSize       = nil
    }

    func resetView() {
        dismissHUD()
        physics.placeOrb(at: orbRestPosition)
    }

    // MARK: - Calibration

    func startCalibration() { isCalibrating = true }

    func endCalibration() { isCalibrating = false }

    /// Called by `HandCalibrationView` after a successful calibration session.
    func applyCalibration(_ calib: AffineCalibration) {
        cursorEngine.calibration          = calib
        secondaryCursorEngine.calibration = calib
        cursorEngine.reset()
        secondaryCursorEngine.reset()
    }

    /// Restore default linear mapping (no calibration).
    func resetCalibration() {
        HandCalibrationStore.shared.reset()
        cursorEngine.calibration          = nil
        secondaryCursorEngine.calibration = nil
        cursorEngine.reset()
        secondaryCursorEngine.reset()
    }

    // MARK: - Overlay context

    func updateSpatialContext(overlayFrames: [UUID: CGRect], focusedID: UUID?) {
        self.overlayFrames    = overlayFrames
        self.focusedOverlayID = focusedID
        updateHoveredOverlay(at: cursorState.position, visible: cursorState.isVisible)
    }

    func currentOverlayFrame(for id: UUID) -> CGRect? { overlayFrames[id] }

    // MARK: - Enable / disable

    private func _pauseTracking() {
        cameraManager?.pixelBufferTap = nil
        displayTimer?.invalidate()
        displayTimer     = nil
        presenceState    = .noHand
        isHUDOpen        = false
        isTrackingActive = false
    }

    private func _resumeTracking() {
        guard let cm = cameraManager else { return }
        cm.pixelBufferTap = { [weak self] buffer in self?.handleRawFrame(buffer) }
        startPhysicsTick()
    }

    // MARK: - Raw frame ingestion

    private func handleRawFrame(_ buffer: CVPixelBuffer) {
        frameCounter &+= 1
        guard frameCounter % currentFrameSkip == 0 else { return }
        tracker.process(pixelBuffer: buffer)
    }

    // MARK: - Primary hand processing

    private func handlePose(_ pose: HandPose?) {
        let now = Date()
        let cfg = SpatialInteractionConfig.shared

        // ── Basic diagnostics ──────────────────────────────────────────────
        trackingConfidence    = pose?.confidence ?? 0
        dbgPrimaryConf        = pose?.confidence ?? 0
        dbgFaceDetected       = tracker.faceRectNorm != nil
        dbgSecondStableFrames = tracker.secondHandStableFrames
        dbgHandCount          = (pose != nil ? 1 : 0) + (tracker.secondaryHandPose != nil ? 1 : 0)

        // ── Face suppression — primary hand ────────────────────────────────
        var activePose: HandPose? = pose
        let faceNear: Bool
        if let p = pose, isHandNearFace(p) {
            primaryFaceExitFrames    = 0
            dbgPrimaryFaceSuppressed = true
            dbgFaceSuppressionReason = "primary overlaps face zone"
            activePose               = nil
            faceNear                 = true
        } else {
            primaryFaceExitFrames = min(primaryFaceExitFrames + 1, cfg.faceExitDwellFrames + 1)
            dbgPrimaryFaceSuppressed = false
            faceNear                 = false
        }

        // Face-exit dwell: hand must be off-face for N frames before eligible
        let primaryEligible = activePose != nil &&
            primaryFaceExitFrames >= cfg.faceExitDwellFrames
        let effectivePose = primaryEligible ? activePose : nil

        isTrackingActive = effectivePose != nil

        // ── Presence fade ──────────────────────────────────────────────────
        if effectivePose != nil {
            handLastSeenAt = now
            if presenceState == .noHand { presenceState = .handDetected }
        } else {
            if let lastSeen = handLastSeenAt,
               now.timeIntervalSince(lastSeen) >= handLossFadeDuration {
                handLastSeenAt = nil
                if presenceState != .noHand {
                    presenceState = .noHand
                    dismissHUD()
                    cancelDrag()
                }
            }
        }

        // ── Calibration mode fast-path ───────────────────────────────────────
        // Use raw `pose` (bypasses face-suppression + dwell gate) and a direct
        // full-range Vision→screen mapping — no Y-range remapping — so the cursor
        // faithfully shows where the hand is across the entire camera frame.
        // This lets the user physically aim at every target dot regardless of
        // their camera angle or desk setup.
        if isCalibrating {
            let calibNorm = pose?.indexTip
            rawVisionPoint = calibNorm ?? .zero
            // Direct mapping: X-mirror (camera is flipped) + Y-flip (Vision Y-up → SwiftUI Y-down).
            // Maps Vision (0,0)→screen bottom-left  and  (1,1)→screen top-right, full range.
            let calibPos: CGPoint
            if let vp = calibNorm {
                calibPos = CGPoint(
                    x: (1.0 - vp.x) * viewSize.width,
                    y: (1.0 - vp.y) * viewSize.height
                )
            } else {
                calibPos = cursorState.position
            }
            dbgRawCursorPos    = calibPos
            dbgSmoothedCursorPos = calibPos
            if pose != nil {
                handLastSeenAt = now
                presenceState  = .handDetected
            } else if let lastSeen = handLastSeenAt,
                      now.timeIntervalSince(lastSeen) >= handLossFadeDuration {
                handLastSeenAt = nil
                presenceState  = .noHand
            }
            var cs = SpatialCursorState()
            cs.position  = calibPos
            cs.isVisible = pose != nil
            cursorState  = cs
            return
        }

        // ── Velocity history (before scoring so we have up-to-date data) ──
        let rawNorm = effectivePose?.indexTip

        // Publish raw Vision point so HandCalibrationView can read it.
        rawVisionPoint = rawNorm ?? .zero

        dbgRawCursorPos = rawNorm.map { pt in
            CGPoint(x: (1.0 - pt.x) * viewSize.width, y: (1.0 - pt.y) * viewSize.height)
        } ?? cursorState.position

        // Temporarily update position for velocity measurement
        cursorEngine.sensitivityMode = draggingOverlayID != nil ? .drag : .pointer
        let smoothed = cursorEngine.update(normalizedPoint: rawNorm)
        dbgSmoothedCursorPos = smoothed ?? cursorState.position

        if velocityHistory.count >= 2 {
            let recent = velocityHistory.suffix(4)
            if let first = recent.first, let last = recent.last {
                let dt = last.time.timeIntervalSince(first.time)
                if dt > 0 {
                    lastPointerSpeed = hypot(last.pos.x - first.pos.x,
                                            last.pos.y - first.pos.y) / CGFloat(dt)
                    dbgVelocityMagnitude = lastPointerSpeed
                }
            }
        }

        // ── Accidental motion detection ────────────────────────────────────
        var motionResult = AccidentalMotionDetector.Result()
        if let pos = smoothed {
            motionResult = motionDetector.update(position: pos,
                                                 velocityMagnitude: lastPointerSpeed)
        }
        dbgIsAccidentalMotion = motionResult.isSuppressible
        dbgMotionConfidence   = motionResult.accidentalConfidence

        // ── Adaptive intent scoring ────────────────────────────────────────
        var intentScore = HandIntentScore()
        var isScoreSuppressed = false

        if let p = effectivePose {
            let recentPositions  = velocityHistory.map(\.pos)
            let recentVelocities = computeVelocityMagnitudes()
            let cal = calibration.profile

            intentScore = HandIntentScore.compute(
                pose:               p,
                recentPositions:    recentPositions,
                recentVelocities:   recentVelocities,
                isFaceNear:         faceNear,
                isDominantHand:     true,
                recentSuccessRate:  cal.recentSuccessRate,
                recentCancelRate:   cal.recentCancelRate,
                minConfidence:      cfg.handConfidenceThreshold,
                isAccidentalMotion: motionResult.isSuppressible
            )

            isScoreSuppressed = intentScore.isSuppressed ||
                (intentScore.eligibilityScore < cfg.eligibilityThreshold && effectivePose != nil)
        }

        // Update score diagnostics
        dbgEligibilityScore  = intentScore.eligibilityScore
        dbgIntentScore       = intentScore.intentScore
        dbgGestureLikelihood = intentScore.activeGestureLikelihood
        dbgSuppressionReason = intentScore.suppressionReason?.rawValue ??
            (motionResult.reason?.rawValue ?? "—")

        // ── Calibration recording (every N frames) ─────────────────────────
        let cal = calibration.profile
        if effectivePose != nil && (frameCounter % cfg.calibrationSampleInterval == 0) {
            calibration.recordPointerSpeed(Double(lastPointerSpeed))
            // Record tremor range from motion detector bounce zone
            if motionResult.isBouncing {
                calibration.recordTremorRange(Double(cfg.deadzonePts * 1.5))
            }
        }
        // Update calibration diagnostics
        dbgCalibFrames   = cal.totalFrames
        dbgCalibAdaptedAt = cal.lastAdaptedAt == .distantPast ? "never" :
            RelativeDateTimeFormatter().localizedString(for: cal.lastAdaptedAt, relativeTo: now)
        dbgLearnedPinchDist  = String(format: "%.3f", cal.adaptedPinchThreshold)
        dbgLearnedDeadzone   = String(format: "%.1f pts", cal.adaptedDeadzonePts)
        dbgLearnedSmoothing  = String(format: "α%.3f", cal.adaptedSmoothingAlpha)
        dbgLearnedPointerSens = String(format: "%.2f×", cal.adaptedPointerSensitivity)
        dbgLearnedSecondDwell = "\(cal.adaptedSecondHandDwellFrames) fr"

        // ── Gesture classification ─────────────────────────────────────────
        let gesture = gestures.classify(pose: effectivePose,
                                        isSuppressed: isScoreSuppressed)
        currentGesture = gesture

        // ── Cursor state ───────────────────────────────────────────────────
        var cs = SpatialCursorState()
        cs.position   = smoothed ?? cursorState.position
        cs.isVisible  = presenceState != .noHand && effectivePose != nil
        cs.isPinching = (gesture == .pinching || gesture == .pinchCandidate)
        cs.isSuppressed = gesture == .suppressed
        cs.eligibilityScore = intentScore.eligibilityScore
        cs.intentScore      = intentScore.intentScore
        cursorState = cs

        guard let cursorPos = smoothed else {
            updateHoveredOverlay(at: cursorState.position, visible: false)
            return
        }

        // ── Velocity history ───────────────────────────────────────────────
        velocityHistory.append(VelocitySample(pos: cursorPos, time: now))
        if velocityHistory.count > velocityWindowSize { velocityHistory.removeFirst() }

        updateHoveredOverlay(at: cursorPos, visible: cs.isVisible)

        // ── Orb hover ──────────────────────────────────────────────────────
        let distToOrb = distance(cursorPos, physics.orbPosition)
        orbIsHovered = distToOrb < hoverRadius && presenceState != .noHand
        cs.magneticScale = orbIsHovered
            ? min(1.0 + (1.0 - distToOrb / hoverRadius) * 0.4, 1.4)
            : 1.0
        cursorState = cs

        // ── Gesture routing ────────────────────────────────────────────────
        switch gesture {

        case .handCandidate:
            // Hand detected but not yet eligible — show cursor, no interaction
            break

        case .handEligible where presenceState == .noHand:
            presenceState = .handDetected

        case .suppressed:
            // Suppressed — show indicator, no interaction
            if presenceState == .pinchActive { presenceState = .handDetected }

        case .cooldown:
            // Brief pause post-gesture — allow cursor visibility but no actions
            if presenceState == .pinchActive { presenceState = .handDetected }

        case .pinchCandidate where presenceState != .noHand && draggingOverlayID == nil && !isHUDOpen:
            presenceState = .pinchActive

        case .pinching where presenceState != .noHand:
            // Gate on intent score — don't allow pinch if intent is too low
            guard intentScore.intentScore >= SpatialInteractionConfig.shared.intentThreshold ||
                  draggingOverlayID != nil || isHUDOpen else { break }

            let wasDragging = draggingOverlayID != nil
            if !wasDragging && !isHUDOpen {
                if let entry = overlayFrames.first(where: { $0.value.contains(cursorPos) }) {
                    draggingOverlayID  = entry.key
                    dragStartCursorPos = cursorPos
                    dragStartFrame     = entry.value
                    orbIsPinched       = false
                    presenceState      = .pinchActive
                    velocityHistory    = []
                } else {
                    isHUDOpen     = true
                    hudAnchor     = cursorPos
                    orbIsPinched  = true
                    presenceState = .hudOpen
                    resetDwell()
                }
            } else if wasDragging {
                if let startCursor = dragStartCursorPos,
                   let startFrame  = dragStartFrame,
                   let dragID      = draggingOverlayID {
                    let delta = CGPoint(x: cursorPos.x - startCursor.x,
                                       y: cursorPos.y - startCursor.y)
                    onOverlayMove?(dragID, startFrame.offsetBy(dx: delta.x, dy: delta.y))
                }
            } else if isHUDOpen {
                updateHighlight(at: cursorPos)
                updateDwell(at: now)
            }

        case .pinchRelease where draggingOverlayID != nil:
            if let dragID      = draggingOverlayID,
               let startCursor = dragStartCursorPos,
               let startFrame  = dragStartFrame {
                let throwVel   = computeThrowVelocity()
                let finalDelta = CGPoint(
                    x: cursorPos.x - startCursor.x + throwVel.x * 0.3,
                    y: cursorPos.y - startCursor.y + throwVel.y * 0.3
                )
                onOverlayMove?(dragID, startFrame.offsetBy(dx: finalDelta.x, dy: finalDelta.y))
            }
            cancelDrag()
            calibration.recordGestureSuccess()
            gestures.enterCooldown(frames: SpatialInteractionConfig.shared.gesturePostCooldownFrames)
            presenceState = isTrackingActive ? .handDetected : .noHand

        case .pinchRelease where isHUDOpen:
            if let idx = highlightedItemIndex {
                let items = currentHUDItems
                if idx < items.count { onHUDAction?(items[idx]) }
            }
            dismissHUD()
            calibration.recordGestureSuccess()
            gestures.enterCooldown(frames: SpatialInteractionConfig.shared.gesturePostCooldownFrames)
            presenceState = isTrackingActive ? .handDetected : .noHand

        case .idle where isHUDOpen:
            dismissHUD()

        default:
            if presenceState == .pinchActive { presenceState = .handDetected }
        }
    }

    // MARK: - Velocity magnitude history (for HandIntentScore)

    private func computeVelocityMagnitudes() -> [CGFloat] {
        guard velocityHistory.count >= 2 else { return [] }
        return zip(velocityHistory, velocityHistory.dropFirst()).map { s1, s2 in
            let dt = s2.time.timeIntervalSince(s1.time)
            guard dt > 0 else { return CGFloat(0) }
            return hypot(s2.pos.x - s1.pos.x, s2.pos.y - s1.pos.y) / CGFloat(dt)
        }
    }

    // MARK: - Secondary hand processing (resize gating)

    private func handleSecondaryPose(_ pose: HandPose?) {
        guard !suppressSecondHandGestures else {
            _cancelSecondaryHand()
            dbgSecondHandRejection = "suppressed by active overlay"
            return
        }

        let cfg = SpatialInteractionConfig.shared

        // ── Gate: need primary hand, no HUD, no drag ──────────────────────
        guard cursorState.isVisible, !isHUDOpen, draggingOverlayID == nil else {
            _cancelSecondaryHand()
            dbgSecondHandRejection = "primary ineligible / HUD / drag active"
            return
        }

        // ── Gate: need pose with sufficient confidence ─────────────────────
        guard let pose = pose,
              pose.confidence >= cfg.secondHandConfidenceThreshold else {
            _cancelSecondaryHand()
            dbgSecondHandRejection = pose == nil
                ? "no secondary hand"
                : String(format: "conf %.2f < threshold", pose?.confidence ?? 0)
            return
        }

        // ── Gate: second hand must have been stable long enough ────────────
        guard tracker.secondHandStableFrames >= cfg.secondHandDwellFrames else {
            _cancelSecondaryHand()
            dbgSecondHandRejection = "second hand dwell: \(tracker.secondHandStableFrames)/\(cfg.secondHandDwellFrames)"
            return
        }

        // ── Gate: face suppression for secondary hand ──────────────────────
        if isHandNearFace(pose) {
            secondFaceExitFrames = 0
            dbgSecondFaceSuppressed = true
            dbgSecondHandRejection  = "face overlap"
            _cancelSecondaryHand()
            return
        } else {
            secondFaceExitFrames = min(secondFaceExitFrames + 1, cfg.faceExitDwellFrames + 1)
            dbgSecondFaceSuppressed = false
        }

        guard secondFaceExitFrames >= cfg.faceExitDwellFrames else {
            dbgSecondHandRejection = "exiting face zone dwell"
            _cancelSecondaryHand()
            return
        }

        // ── Update secondary cursor ────────────────────────────────────────
        secondaryCursorEngine.sensitivityMode = .resize
        let secSmoothed = secondaryCursorEngine.update(normalizedPoint: pose.indexTip)
        var scs = SpatialCursorState()
        scs.position  = secSmoothed ?? secondaryCursorState.position
        scs.isVisible = true
        secondaryCursorState = scs
        dbgSecondHandRejection = "—"
        dbgSecondaryConf = pose.confidence

        guard let secPos = secSmoothed else { return }

        let interHandDist = distance(cursorState.position, secPos)

        // ── Resize state machine ───────────────────────────────────────────
        switch resizePhase {

        case .disabled:
            // Start candidate only if there's a focused overlay to resize
            if focusedOverlayID != nil {
                resizePhase = .candidate(dwellFrames: 1)
                dbgResizeReason = "started candidate"
            } else {
                dbgResizeReason = "no focused overlay"
            }

        case .candidate(let dwellFrames):
            let newDwell = dwellFrames + 1
            dbgResizePhase = "candidate(\(newDwell)/\(cfg.resizeDwellFrames))"

            if newDwell >= cfg.resizeDwellFrames {
                // Dwell met — check both hands are stable (low velocity)
                if isPrimaryHandStable(cfg: cfg) {
                    // Establish resize baseline
                    spreadBaseDistance = interHandDist
                    if let focusedID = focusedOverlayID,
                       let frame = overlayFrames[focusedID] {
                        spreadBaseSize = frame.size
                    }
                    resizePhase     = .resizing
                    spreadGestureActive = true
                    dbgResizeReason = "dwell met + hands stable → resizing"
                } else {
                    // Reset dwell — keep waiting until stable
                    resizePhase = .candidate(dwellFrames: 0)
                    dbgResizeReason = "candidate: hands not stable (speed \(Int(lastPointerSpeed)) pts/s)"
                }
            } else {
                resizePhase = .candidate(dwellFrames: newDwell)
            }

        case .resizing:
            dbgResizePhase = "resizing"
            guard let baseD    = spreadBaseDistance,
                  let baseSize = spreadBaseSize,
                  let focusedID = focusedOverlayID else {
                _cancelSecondaryHand()
                dbgResizeReason = "lost baseline"
                return
            }

            // Apply resize sensitivity + hysteresis threshold
            let rawFactor = interHandDist / max(baseD, 1)
            let scaledFactor = 1.0 + (rawFactor - 1.0) * cfg.resizeSensitivity

            if abs(scaledFactor - 1.0) > cfg.resizeStartThreshold {
                let newW = (baseSize.width  * scaledFactor).clamped(to: 360...1100)
                let newH = (baseSize.height * scaledFactor).clamped(to: 280...780)
                onOverlayResize?(focusedID, CGSize(width: newW, height: newH))
            }
        }
    }

    /// Cancel secondary hand state cleanly.
    private func _cancelSecondaryHand() {
        secondaryCursorState = SpatialCursorState()
        spreadGestureActive  = false
        resizePhase          = .disabled
        spreadBaseDistance   = nil
        spreadBaseSize       = nil
        dbgResizePhase       = "disabled"
        secondaryCursorEngine.reset()
    }

    // MARK: - Face suppression

    /// True when the hand's wrist or palm centre overlaps the padded face zone.
    private func isHandNearFace(_ pose: HandPose) -> Bool {
        guard let faceRect = tracker.faceRectNorm else { return false }
        let cfg = SpatialInteractionConfig.shared
        // Pad the face rect by `facePaddingNorm` in normalised Vision space
        let padded = faceRect.insetBy(dx: -cfg.facePaddingNorm, dy: -cfg.facePaddingNorm)
        return padded.contains(pose.wrist) || padded.contains(pose.palmCenter)
    }

    /// True if the primary cursor has been moving slowly enough to pass the
    /// stability gate required before resize can begin.
    private func isPrimaryHandStable(cfg: SpatialInteractionConfig) -> Bool {
        lastPointerSpeed < cfg.handStabilityMaxSpeedPts
    }

    // MARK: - HUD helpers

    private func dismissHUD() {
        isHUDOpen            = false
        highlightedItemIndex = nil
        orbIsPinched         = false
        resetDwell()
        if presenceState == .hudOpen {
            presenceState = isTrackingActive ? .handDetected : .noHand
        }
    }

    private func cancelDrag() {
        draggingOverlayID  = nil
        dragStartCursorPos = nil
        dragStartFrame     = nil
        velocityHistory    = []
    }

    private func updateHighlight(at pos: CGPoint) {
        let items    = currentHUDItems
        let snapDist: CGFloat = 90
        var minDist  = snapDist
        var nearest: Int? = nil
        for (i, _) in items.enumerated() {
            let itemPos = radialItemPosition(index: i, anchor: hudAnchor, count: items.count)
            let d = distance(pos, itemPos)
            if d < minDist { minDist = d; nearest = i }
        }
        highlightedItemIndex = nearest
    }

    private func updateHoveredOverlay(at pos: CGPoint, visible: Bool) {
        guard visible else { hoveredOverlayID = nil; return }
        hoveredOverlayID = overlayFrames.first(where: { $0.value.contains(pos) })?.key
    }

    // MARK: - Dwell-click

    private func updateDwell(at now: Date) {
        guard let idx = highlightedItemIndex else {
            resetDwell(); return
        }
        if idx != lastDwellIndex {
            dwellStartedAt = now
            lastDwellIndex = idx
            dwellProgress  = 0
            dwellItemIndex = idx
        }
        guard let startedAt = dwellStartedAt else {
            dwellStartedAt = now; return
        }
        let elapsed = now.timeIntervalSince(startedAt)
        dwellProgress  = min(elapsed / dwellDuration, 1.0)
        dwellItemIndex = idx

        if elapsed >= dwellDuration {
            let items = currentHUDItems
            if idx < items.count { onHUDAction?(items[idx]) }
            dismissHUD()
        }
    }

    private func resetDwell() {
        dwellStartedAt = nil
        lastDwellIndex = nil
        dwellItemIndex = nil
        dwellProgress  = 0
    }

    // MARK: - Throw physics

    private func computeThrowVelocity() -> CGPoint {
        guard velocityHistory.count >= 2 else { return .zero }
        let recent = Array(velocityHistory.suffix(4))
        guard let first = recent.first, let last = recent.last else { return .zero }
        let dt = last.time.timeIntervalSince(first.time)
        guard dt > 0 else { return .zero }
        let dx = (last.pos.x - first.pos.x) / CGFloat(dt)
        let dy = (last.pos.y - first.pos.y) / CGFloat(dt)
        let speed = hypot(dx, dy)
        guard speed > throwThreshold else { return .zero }
        return CGPoint(x: dx, y: dy)
    }

    // MARK: - Radial layout

    func radialItemPosition(index: Int, anchor: CGPoint, count: Int) -> CGPoint {
        let radius: CGFloat = 110
        let startAngle: Double = 180.0
        let endAngle:   Double = 360.0
        let step = (endAngle - startAngle) / Double(max(count - 1, 1))
        let angleDeg = startAngle + step * Double(index)
        let angleRad = angleDeg * .pi / 180.0
        return CGPoint(
            x: anchor.x + cos(angleRad) * radius,
            y: anchor.y + sin(angleRad) * radius
        )
    }

    // MARK: - Physics tick

    private func startPhysicsTick() {
        displayTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.physicsTick() }
        }
        RunLoop.main.add(displayTimer!, forMode: .common)
    }

    private func physicsTick() {
        let now = Date()
        let dt  = min(now.timeIntervalSince(lastTickTime), 0.05)
        lastTickTime = now

        let target = orbIsPinched ? cursorState.position : orbRestPosition
        physics.tick(dt: dt, orbTarget: target)

        fpsCounter += 1
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            trackingFPS    = Int(Double(fpsCounter) / elapsed)
            fpsCounter     = 0
            fpsWindowStart = now
        }
    }

    // MARK: - Camera observation

    private func observeFallbackCamera(_ pipeline: CameraPipeline) {
        pipeline.$latestFrame
            .compactMap { $0 }
            .sink { [weak self] buffer in self?.handleRawFrame(buffer) }
            .store(in: &cancellables)
    }

    private func observeTracker() {
        tracker.$handPose
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pose in self?.handlePose(pose) }
            .store(in: &cancellables)

        tracker.$secondaryHandPose
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pose in self?.handleSecondaryPose(pose) }
            .store(in: &cancellables)
    }

    // MARK: - Helpers

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

// MARK: - Comparable.clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
