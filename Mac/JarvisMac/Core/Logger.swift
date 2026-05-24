import Foundation
import OSLog

/// OSLog wrapper that also fans logs out to the in-app debug widget.
enum Log {
    private static let subsystem = "com.jarvis.mac.JarvisMac"

    static let app       = Logger(subsystem: subsystem, category: "app")
    static let audio     = Logger(subsystem: subsystem, category: "audio")
    static let speech    = Logger(subsystem: subsystem, category: "speech")
    static let wake      = Logger(subsystem: subsystem, category: "wake")
    static let vision    = Logger(subsystem: subsystem, category: "vision")
    static let net       = Logger(subsystem: subsystem, category: "net")
    static let llm       = Logger(subsystem: subsystem, category: "llm")
    static let actions   = Logger(subsystem: subsystem, category: "actions")
    static let intent    = Logger(subsystem: subsystem, category: "intent")
    static let ui        = Logger(subsystem: subsystem, category: "ui")
    static let context   = Logger(subsystem: subsystem, category: "context")
    static let home      = Logger(subsystem: subsystem, category: "home")
    static let latency   = Logger(subsystem: subsystem, category: "latency")
    static let memory    = Logger(subsystem: subsystem, category: "memory")
    static let screen    = Logger(subsystem: subsystem, category: "screen")
    static let android   = Logger(subsystem: subsystem, category: "android")
    static let runtime   = Logger(subsystem: subsystem, category: "runtime")
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let category: String
    let level: Level
    let message: String

    enum Level: String { case debug, info, warn, error }

    var formatted: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return "[\(f.string(from: timestamp))] [\(category)/\(level.rawValue)] \(message)"
    }
}
