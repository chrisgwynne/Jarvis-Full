import Foundation
import OSLog

// Signal handling for clean shutdown
let logger = Logger(subsystem: "com.jarvis.brain", category: "daemon")

// Start the daemon server
let server = BrainDaemonServer()
server.start()

logger.info("JarvisBrainDaemon started on port \(server.port)")

// Sync router diagnostics into DaemonDiagnostics every 10 seconds
let syncTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
syncTimer.schedule(deadline: .now() + 10, repeating: 10)
syncTimer.setEventHandler {
    DaemonDiagnostics.shared.syncFromRouter()
}
syncTimer.resume()

// Run until signal
dispatchMain()
