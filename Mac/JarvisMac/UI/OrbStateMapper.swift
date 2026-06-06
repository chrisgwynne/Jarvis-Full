import SwiftUI

// MARK: - OrbState

/// Unified visual state for the Jarvis orb.
/// Decoupled from `AssistantPhase` so the orb never depends on runtime logic.
enum OrbState: String, Equatable {
    case idle       // not yet armed — dim resting state
    case passive    // wake word armed — calm readiness
    case listening  // active STT session
    case thinking   // LLM / intent routing
    case speaking   // TTS output
    case muted      // listening disabled by user
    case error      // audio or STT failure
    case offline    // daemon / connectivity down
}

// MARK: - OrbVisualConfig

/// All visual parameters for one orb state. Pure data — no SwiftUI view logic.
struct OrbVisualConfig: Equatable {
    let ringColor:       Color
    let ringOpacity:     Double    // base opacity of the primary ring
    let glowColor:       Color     // outer glow shadow colour
    let pulseFrequency:  Double    // breathing cycles per second (0 = static)
    let pulseAmplitude:  Double    // ring scaleEffect delta (0.03 = ±3%)
    let arcVisible:      Bool      // show rotating highlight arc
    let arcSpeed:        Double    // seconds per full rotation (0 = static)
    let ringWidth:       CGFloat   // base stroke width in points
}

// MARK: - OrbVisualConfig presets
// Palette: cool blues for passive states, cyan for active listening,
// blue-green for speaking, purple for thinking.
// Inspired by Apple Vision Pro system UI — never warm/orange/red unless error.

extension OrbVisualConfig {
    static let idle = OrbVisualConfig(
        ringColor:      Color(hue: 0.600, saturation: 0.55, brightness: 0.52),
        ringOpacity:    0.52,
        glowColor:      Color(hue: 0.600, saturation: 0.60, brightness: 0.35),
        pulseFrequency: 0.80,   // 2× faster — immediately visible as alive
        pulseAmplitude: 0.030,
        arcVisible:     false,
        arcSpeed:       0,
        ringWidth:      2.0
    )
    static let passive = OrbVisualConfig(
        ringColor:      Color(hue: 0.600, saturation: 0.72, brightness: 0.80),
        ringOpacity:    0.72,
        glowColor:      Color(hue: 0.600, saturation: 0.75, brightness: 0.52),
        pulseFrequency: 1.40,   // noticeable breathing at wake-armed state
        pulseAmplitude: 0.042,
        arcVisible:     true,
        arcSpeed:       10,     // visible slow drift (was 24 = too slow)
        ringWidth:      2.2
    )
    static let listening = OrbVisualConfig(
        ringColor:      Color(hue: 0.523, saturation: 0.88, brightness: 0.96),
        ringOpacity:    0.92,
        glowColor:      Color(hue: 0.523, saturation: 0.80, brightness: 0.72),
        pulseFrequency: 2.40,   // fast react-to-voice pulse
        pulseAmplitude: 0.060,
        arcVisible:     true,
        arcSpeed:       3.5,    // fast arc rotation — alert, active
        ringWidth:      3.0
    )
    static let thinking = OrbVisualConfig(
        ringColor:      Color(hue: 0.648, saturation: 0.68, brightness: 0.84),
        ringOpacity:    0.82,
        glowColor:      Color(hue: 0.648, saturation: 0.72, brightness: 0.58),
        pulseFrequency: 1.20,
        pulseAmplitude: 0.038,
        arcVisible:     true,
        arcSpeed:       4.5,    // scanning arcs visibly rotate
        ringWidth:      2.5
    )
    static let speaking = OrbVisualConfig(
        ringColor:      Color(hue: 0.475, saturation: 0.78, brightness: 0.88),
        ringOpacity:    0.90,
        glowColor:      Color(hue: 0.475, saturation: 0.72, brightness: 0.62),
        pulseFrequency: 2.80,   // most energetic state
        pulseAmplitude: 0.070,
        arcVisible:     true,
        arcSpeed:       3.0,    // very fast arcs
        ringWidth:      3.5
    )
    static let muted = OrbVisualConfig(
        ringColor:      Color(white: 0.28),
        ringOpacity:    0.32,
        glowColor:      Color.clear,
        pulseFrequency: 0,
        pulseAmplitude: 0,
        arcVisible:     false,
        arcSpeed:       0,
        ringWidth:      1.0
    )
    static let error = OrbVisualConfig(
        ringColor:      Color(hue: 0.068, saturation: 0.78, brightness: 0.86),
        ringOpacity:    0.78,
        glowColor:      Color(hue: 0.068, saturation: 0.72, brightness: 0.60),
        pulseFrequency: 1.40,
        pulseAmplitude: 0.045,
        arcVisible:     false,
        arcSpeed:       0,
        ringWidth:      1.6
    )
    static let offline = OrbVisualConfig(
        ringColor:      Color(hue: 0.000, saturation: 0.52, brightness: 0.36),
        ringOpacity:    0.45,
        glowColor:      Color.clear,
        pulseFrequency: 0,
        pulseAmplitude: 0,
        arcVisible:     false,
        arcSpeed:       0,
        ringWidth:      1.0
    )
}

// MARK: - OrbStateMapper

/// Converts Jarvis runtime states into OrbState and OrbVisualConfig.
/// The orb never reads AssistantPhase directly — it goes through this mapper
/// so the visual layer stays decoupled from the conversation runtime.
enum OrbStateMapper {

    static func orbState(for phase: AssistantPhase) -> OrbState {
        switch phase {
        case .idle:                    return .idle
        case .wakeListening:           return .passive
        case .listening:               return .listening
        case .conversationalListening: return .listening
        case .awaitingResponse:        return .listening
        case .thinking:                return .thinking
        case .speaking:                return .speaking
        case .bargedIn:                return .listening
        case .muted:                   return .muted
        case .error:                   return .error
        }
    }

    static func visualConfig(for state: OrbState) -> OrbVisualConfig {
        switch state {
        case .idle:      return .idle
        case .passive:   return .passive
        case .listening: return .listening
        case .thinking:  return .thinking
        case .speaking:  return .speaking
        case .muted:     return .muted
        case .error:     return .error
        case .offline:   return .offline
        }
    }
}
