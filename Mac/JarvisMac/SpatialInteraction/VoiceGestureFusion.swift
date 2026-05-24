// VoiceGestureFusion.swift
// JarvisMac — SpatialInteraction
//
// Voice + Gesture Fusion layer.
//
// Combines a rolling 5-second window of voice intent entries with the current
// gesture hover state to produce high-confidence FusedActions.  This enables
// natural deictic interaction: the user hovers over a widget with their hand
// and says "move that left" or "make this bigger" and Jarvis resolves the
// referent from the gesture context.
//
// Design notes:
//   • No Combine, no ObservableObject.  Uses Swift 5.9 @Observable macro.
//   • All state mutations happen on the MainActor.
//   • WidgetMoveDirection, DockEdge, and SnapZone are declared below as
//     forward stubs; they will be superseded by the canonical definitions in
//     SpatialWidgetManager.swift once that file is added to the target.

import Foundation
import CoreGraphics
import Observation

// WidgetMoveDirection, DockEdge, and SnapZone are defined in SpatialWidgetManager.swift.

// ---------------------------------------------------------------------------
// MARK: - VoiceIntentEntry
// ---------------------------------------------------------------------------

/// A single voice intent captured from the speech pipeline.
struct VoiceIntentEntry: Equatable {
    /// Intent label as produced by IntentRouter / IntentMapping
    /// e.g. "moveWidgetLeft", "openCalendar".
    let intentLabel: String

    /// Raw spoken transcript associated with this intent.
    let transcript: String

    /// Moment the intent was recorded.
    let timestamp: Date

    /// Speech-recognition or routing confidence in [0, 1].
    let confidence: Float
}

// ---------------------------------------------------------------------------
// MARK: - GestureContext
// ---------------------------------------------------------------------------

/// A snapshot of the current hand / cursor state emitted by the spatial layer.
struct GestureContext: Equatable {
    /// Widget the cursor is currently hovering over, if any.
    let hoveredWidgetID: UUID?

    /// Gesture classifier label e.g. "pinch", "openPalm", "pointIndex".
    let gesture: String?

    /// Screen-space cursor position (points, origin top-left).
    let cursorPosition: CGPoint

    /// Moment this snapshot was taken.
    let timestamp: Date
}

// ---------------------------------------------------------------------------
// MARK: - FusedActionType
// ---------------------------------------------------------------------------

/// The concrete action that fusion produced.
enum FusedActionType: Equatable {
    case moveWidget(direction: WidgetMoveDirection)
    case resizeWidget(larger: Bool)
    case minimizeWidget
    case restoreWidget
    case dockWidget(edge: DockEdge)
    case snapWidget(zone: SnapZone)
    /// Raw overlay kind string (OverlayKind raw value).
    case openOverlay(kind: String)
    case closeWidget
    case unknown
}

// ---------------------------------------------------------------------------
// MARK: - FusedActionSource
// ---------------------------------------------------------------------------

/// Describes which input modalities contributed to the fused action.
enum FusedActionSource: Equatable {
    /// Decision made purely from voice context — no spatial hover was active.
    case voiceOnly
    /// Decision made purely from gesture — no recent voice intent in window.
    case gestureOnly
    /// Both a recent voice intent and a spatial hover contributed.
    case voiceAndGesture
}

// ---------------------------------------------------------------------------
// MARK: - FusedAction
// ---------------------------------------------------------------------------

/// The output of the fusion process: a resolved action with provenance.
struct FusedAction: Equatable {
    let action: FusedActionType
    /// The widget the action targets, if resolvable.
    let widgetID: UUID?
    /// Composite confidence in [0, 1].
    let confidence: Float
    let resolvedAt: Date
    let source: FusedActionSource
}

// ---------------------------------------------------------------------------
// MARK: - VoiceGestureFusion
// ---------------------------------------------------------------------------

/// Fuses rolling voice intent context with gesture hover state.
///
/// ### Typical usage
/// ```swift
/// VoiceGestureFusion.shared.onFusedAction = { action in
///     SpatialWidgetManager.shared.apply(action)
/// }
/// // From speech pipeline:
/// VoiceGestureFusion.shared.recordVoiceIntent(
///     label: "moveWidgetLeft", transcript: "move that left", confidence: 0.91)
/// // From spatial layer:
/// VoiceGestureFusion.shared.updateGestureContext(
///     hoveredWidgetID: widgetID, gesture: "openPalm", cursorPosition: pt)
/// ```
@MainActor @Observable final class VoiceGestureFusion {

    // -----------------------------------------------------------------------
    // MARK: Singleton
    // -----------------------------------------------------------------------

    static let shared = VoiceGestureFusion()

    // -----------------------------------------------------------------------
    // MARK: State (observable)
    // -----------------------------------------------------------------------

    /// Rolling buffer of voice intents from the last 5 seconds.
    private(set) var recentVoiceIntents: [VoiceIntentEntry] = []

    /// Most recent gesture context snapshot.
    private(set) var currentGestureContext: GestureContext?

    /// Most recently produced fused action.
    private(set) var lastFusedAction: FusedAction?

    /// True while a fusion computation is in flight (always synchronous today;
    /// reserved for future async expansion).
    private(set) var isFusing: Bool = false

    // -----------------------------------------------------------------------
    // MARK: Callback
    // -----------------------------------------------------------------------

    /// Called whenever fusion produces a result with confidence ≥ 0.70.
    var onFusedAction: ((FusedAction) -> Void)?

    // -----------------------------------------------------------------------
    // MARK: Constants
    // -----------------------------------------------------------------------

    /// Only voice intents within this window are eligible for fusion.
    private let voiceWindowSeconds: TimeInterval = 5.0

    /// Voice intents within this tighter window receive a proximity boost.
    private let proximityWindowSeconds: TimeInterval = 2.0

    /// Additive confidence boost when both modalities align closely.
    private let proximityBoost: Float = 0.15

    /// Multiplicative confidence boost when a hovered widget is present.
    private let hoverMultiplier: Float = 1.2

    /// Minimum confidence for `onFusedAction` to fire.
    private let autoFireThreshold: Float = 0.70

    // -----------------------------------------------------------------------
    // MARK: Init
    // -----------------------------------------------------------------------

    private init() {}

    // -----------------------------------------------------------------------
    // MARK: Inputs
    // -----------------------------------------------------------------------

    /// Record a new voice intent from the speech/routing pipeline.
    ///
    /// Trims stale entries, appends the new one, then auto-fuses if gesture
    /// context is available and the result clears the confidence threshold.
    func recordVoiceIntent(label: String, transcript: String, confidence: Float) {
        trimVoiceBuffer()

        let entry = VoiceIntentEntry(
            intentLabel: label,
            transcript: transcript,
            timestamp: Date(),
            confidence: confidence
        )
        recentVoiceIntents.append(entry)
        print("[VoiceGestureFusion] Recorded voice intent '\(label)' (conf=\(String(format: "%.2f", confidence)))")

        // Auto-fuse when gesture context is present.
        if currentGestureContext != nil {
            if let result = fuse(), result.confidence >= autoFireThreshold {
                print("[VoiceGestureFusion] Auto-fire: \(result.action) conf=\(String(format: "%.2f", result.confidence))")
                onFusedAction?(result)
            }
        }
    }

    /// Update the gesture layer's hover / cursor snapshot.
    ///
    /// This does NOT auto-fuse on its own; the voice intent side drives fusion
    /// to avoid spurious actions from cursor drift alone.
    func updateGestureContext(hoveredWidgetID: UUID?, gesture: String?, cursorPosition: CGPoint) {
        currentGestureContext = GestureContext(
            hoveredWidgetID: hoveredWidgetID,
            gesture: gesture,
            cursorPosition: cursorPosition,
            timestamp: Date()
        )
        print("[VoiceGestureFusion] Gesture context updated — hovered=\(hoveredWidgetID?.uuidString ?? "none") gesture=\(gesture ?? "none")")
    }

    /// Discard all buffered voice intents.
    func clearVoiceBuffer() {
        recentVoiceIntents.removeAll()
        print("[VoiceGestureFusion] Voice buffer cleared")
    }

    // -----------------------------------------------------------------------
    // MARK: Fusion
    // -----------------------------------------------------------------------

    /// Attempt to produce a FusedAction from the current voice buffer and
    /// gesture context.
    ///
    /// Returns `nil` when there is no usable voice intent within the window.
    /// Stores the result in `lastFusedAction`.
    @discardableResult
    func fuse() -> FusedAction? {
        isFusing = true
        defer { isFusing = false }

        // 1. Prune the voice buffer to the rolling window.
        trimVoiceBuffer()

        // 2. Pick the most recent voice intent.
        guard let voiceEntry = recentVoiceIntents.last else {
            print("[VoiceGestureFusion] fuse() — no recent voice intent in window")
            return nil
        }

        let gesture   = currentGestureContext
        let now       = Date()

        // 3. Resolve the target widget from gesture hover.
        let widgetID  = gesture?.hoveredWidgetID

        // 4. Map the intent label (and transcript) to a FusedActionType.
        let actionType = resolveActionType(label: voiceEntry.intentLabel,
                                           transcript: voiceEntry.transcript)

        // 5. Determine source.
        let source: FusedActionSource = (widgetID != nil) ? .voiceAndGesture : .voiceOnly

        // 6. Base confidence = voice confidence × hover multiplier (capped at 1).
        var computedConfidence = voiceEntry.confidence
        if widgetID != nil {
            computedConfidence = min(computedConfidence * hoverMultiplier, 1.0)
        }

        // 7. Proximity boost: hovered widget + voice intent within 2 s + deictic transcript.
        if widgetID != nil,
           now.timeIntervalSince(voiceEntry.timestamp) <= proximityWindowSeconds,
           isDeicticTranscript(voiceEntry.transcript) {
            computedConfidence = min(computedConfidence + proximityBoost, 1.0)
            print("[VoiceGestureFusion] Proximity boost applied (+\(proximityBoost))")
        }

        let result = FusedAction(
            action:     actionType,
            widgetID:   widgetID,
            confidence: computedConfidence,
            resolvedAt: now,
            source:     source
        )

        lastFusedAction = result
        print("[VoiceGestureFusion] Fused: \(actionType) widgetID=\(widgetID?.uuidString ?? "none") conf=\(String(format: "%.2f", computedConfidence)) source=\(source)")
        return result
    }

    // -----------------------------------------------------------------------
    // MARK: Private helpers
    // -----------------------------------------------------------------------

    /// Remove voice intent entries older than `voiceWindowSeconds`.
    private func trimVoiceBuffer() {
        let cutoff = Date().addingTimeInterval(-voiceWindowSeconds)
        recentVoiceIntents = recentVoiceIntents.filter { $0.timestamp > cutoff }
    }

    /// Returns true when the transcript contains deictic / referential language
    /// ("this", "that", "it", "here", "widget") implying the user is pointing
    /// at something in the spatial layer.
    private func isDeicticTranscript(_ transcript: String) -> Bool {
        let lower = transcript.lowercased()
        let deicticTokens = ["widget", "this", "that", "it", "here"]
        return deicticTokens.contains { lower.contains($0) }
    }

    /// Map an intent label + transcript to a concrete FusedActionType.
    ///
    /// Precedence:
    ///   1. Exact intent-label matches (from IntentRouter/IntentMapping ids).
    ///   2. Close/dismiss patterns in the transcript.
    ///   3. Show/open overlay patterns in the transcript.
    ///   4. Falls back to `.unknown`.
    private func resolveActionType(label: String, transcript: String) -> FusedActionType {
        let lower = transcript.lowercased()

        // --- Explicit intent-label matches ---
        switch label {
        case "moveWidgetLeft":
            return .moveWidget(direction: .left)
        case "moveWidgetRight":
            return .moveWidget(direction: .right)
        case "moveWidgetUp":
            return .moveWidget(direction: .up)
        case "moveWidgetDown":
            return .moveWidget(direction: .down)
        case "resizeWidgetLarge":
            return .resizeWidget(larger: true)
        case "resizeWidgetSmall":
            return .resizeWidget(larger: false)
        case "minimizeWidget":
            return .minimizeWidget
        case "restoreWidget":
            return .restoreWidget
        case "dockWidget":
            return .dockWidget(edge: dockEdge(from: lower))
        case "snapWidget":
            return .snapWidget(zone: snapZone(from: lower))
        default:
            break
        }

        // --- Transcript-level close / dismiss ---
        if lower.contains("close") || lower.contains("dismiss") {
            return .closeWidget
        }

        // --- Transcript-level show / open overlay ---
        if lower.contains("show") || lower.contains("open") {
            if let kind = overlayKind(from: lower) {
                return .openOverlay(kind: kind)
            }
        }

        // --- Partial-label fallbacks (belt-and-suspenders for future intents) ---
        if label.contains("move") {
            if lower.contains("left")  { return .moveWidget(direction: .left)  }
            if lower.contains("right") { return .moveWidget(direction: .right) }
            if lower.contains("up")    { return .moveWidget(direction: .up)    }
            if lower.contains("down")  { return .moveWidget(direction: .down)  }
        }
        if label.contains("resize") || label.contains("bigger") || label.contains("larger") {
            return .resizeWidget(larger: true)
        }
        if label.contains("smaller") || label.contains("shrink") {
            return .resizeWidget(larger: false)
        }
        if label.contains("dock") {
            return .dockWidget(edge: dockEdge(from: lower))
        }
        if label.contains("snap") {
            return .snapWidget(zone: snapZone(from: lower))
        }

        return .unknown
    }

    /// Infer a DockEdge from the transcript (left, right, top, bottom).
    private func dockEdge(from lower: String) -> DockEdge {
        if lower.contains("left")   { return .left   }
        if lower.contains("right")  { return .right  }
        if lower.contains("top")    { return .top    }
        if lower.contains("bottom") { return .bottom }
        return .left   // safe default
    }

    /// Infer a SnapZone from the transcript using zone-keyword heuristics.
    private func snapZone(from lower: String) -> SnapZone {
        let hasTop    = lower.contains("top")
        let hasBottom = lower.contains("bottom") || lower.contains("lower")
        let hasLeft   = lower.contains("left")
        let hasRight  = lower.contains("right")
        let hasCenter = lower.contains("center") || lower.contains("middle")

        switch (hasTop, hasBottom, hasLeft, hasRight, hasCenter) {
        case (true,  false, true,  false, _):     return .topLeft
        case (true,  false, false, true,  _):     return .topRight
        case (true,  false, false, false, _):     return .topHalf
        case (false, true,  true,  false, _):     return .bottomLeft
        case (false, true,  false, true,  _):     return .bottomRight
        case (false, true,  false, false, _):     return .bottomHalf
        case (false, false, true,  false, _):     return .leftThird
        case (false, false, false, true,  _):     return .rightThird
        case (_, _, _, _, true):                  return .center
        default:                                  return .center
        }
    }

    /// Extract an overlay kind string from a "show/open <overlay>" transcript.
    ///
    /// Matches known overlay kind raw values by substring.
    private func overlayKind(from lower: String) -> String? {
        // Ordered by specificity (longer strings first to avoid prefix collisions).
        let knownKinds: [(keyword: String, kind: String)] = [
            ("ambient context",   "ambientContext"),
            ("runtime",           "runtimeDiagnostics"),
            ("calendar",          "calendar"),
            ("task",              "tasks"),
            ("shopify",           "shopify"),
            ("github",            "github"),
            ("home",              "home"),
            ("news",              "news"),
            ("camera",            "camera"),
            ("memory",            "memory"),
            ("chat",              "chat"),
            ("timeline",          "timeline"),
            ("notification",      "notifications"),
            ("screen",            "screen"),
            ("reasoning",         "reasoning"),
            ("obsidian",          "obsidian"),
        ]
        for pair in knownKinds where lower.contains(pair.keyword) {
            return pair.kind
        }
        return nil
    }
}
