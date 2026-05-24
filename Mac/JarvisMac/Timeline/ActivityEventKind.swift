import Foundation

/// Coarse category for every activity event stored in the timeline.
enum ActivityEventKind: String, Codable, CaseIterable, Identifiable {
    // Commands & interaction
    case command        // intent matched and executed
    case wakeWord       // wake word triggered
    case bargeIn        // user interrupted TTS
    case typedInput     // typed chat message

    // Overlay lifecycle
    case overlayOpened
    case overlayClosed

    // Memory
    case memorySaved
    case memorySearched

    // Capture
    case screenCapture
    case cameraCapture
    case ocrEvent

    // Watch
    case screenWatchStart
    case screenWatchStop
    case cameraWatchStart
    case cameraWatchStop

    // Context
    case appSwitch       // active app changed
    case attentionChange // attention state changed

    // System
    case error
    case warning

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .command:          return "bolt.fill"
        case .wakeWord:         return "waveform.badge.mic"
        case .bargeIn:          return "exclamationmark.bubble.fill"
        case .typedInput:       return "keyboard"
        case .overlayOpened:    return "rectangle.stack.fill"
        case .overlayClosed:    return "rectangle.stack"
        case .memorySaved:      return "brain.head.profile"
        case .memorySearched:   return "magnifyingglass"
        case .screenCapture:    return "display"
        case .cameraCapture:    return "camera.fill"
        case .ocrEvent:         return "text.viewfinder"
        case .screenWatchStart: return "eye.fill"
        case .screenWatchStop:  return "eye.slash"
        case .cameraWatchStart: return "video.fill"
        case .cameraWatchStop:  return "video.slash"
        case .appSwitch:        return "app.badge"
        case .attentionChange:  return "brain"
        case .error:            return "xmark.circle.fill"
        case .warning:          return "exclamationmark.triangle.fill"
        }
    }

    var accentHex: String {
        switch self {
        case .command:                          return "00D4FF" // cyan
        case .wakeWord:                         return "00BFA5" // teal
        case .bargeIn:                          return "FF9800" // orange
        case .typedInput:                       return "7C8CF8" // indigo
        case .overlayOpened, .overlayClosed:    return "9C27B0" // purple
        case .memorySaved, .memorySearched:     return "00BCD4" // cyan-teal
        case .screenCapture, .ocrEvent,
             .screenWatchStart, .screenWatchStop: return "009688" // teal
        case .cameraCapture, .cameraWatchStart,
             .cameraWatchStop:                  return "00ACC1" // cyan
        case .appSwitch:                        return "78909C" // blue-grey
        case .attentionChange:                  return "AB47BC" // purple
        case .error:                            return "F44336" // red
        case .warning:                          return "FFC107" // amber
        }
    }
}
