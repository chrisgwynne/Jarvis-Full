import Foundation
import OSLog

let logger = Logger(subsystem: "com.jarvis.brain", category: "daemon")

// ── Single-instance guard ──────────────────────────────────────────────────
// Detect a healthy JarvisBrainDaemon before binding the port.
// Prevents "Address already in use" when launchctl and Xcode both launch
// the daemon simultaneously, or when launchd auto-restarts a still-running process.

let envPort = Int(ProcessInfo.processInfo.environment["JARVIS_DAEMON_PORT"] ?? "8765") ?? 8765
let launchSource: String = {
    if let s = ProcessInfo.processInfo.environment["JARVIS_LAUNCH_SOURCE"] { return s }
    // Heuristic: if parent PID matches launchd (PID 1 or its children), likely a LaunchAgent.
    return getppid() <= 2 ? "launchagent" : "manual"
}()

logger.info("[Daemon] initialising port=\(envPort) launchSource=\(launchSource)")
logger.info("[PortAudit] port=\(envPort)")

var existingInstanceHealthy = false
let healthSema = DispatchSemaphore(value: 0)
let checkCfg = URLSessionConfiguration.default
checkCfg.timeoutIntervalForRequest = 1.5
let checkSession = URLSession(configuration: checkCfg)
if let healthURL = URL(string: "http://127.0.0.1:\(envPort)/health") {
    checkSession.dataTask(with: healthURL) { data, response, _ in
        if let data,
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["daemon"] as? Bool == true {
            existingInstanceHealthy = true
        }
        healthSema.signal()
    }.resume()
    healthSema.wait()
}

if existingInstanceHealthy {
    logger.info("[Daemon] existing instance detected — reusing daemon, exiting cleanly")
    exit(0)
}

logger.info("[Daemon] no existing instance — starting")

// ── Start daemon ───────────────────────────────────────────────────────────

let server = BrainDaemonServer()
logger.info("[Daemon] binding port=\(server.port)")
server.start()
// BrainDaemonServer.start() logs "[Daemon] listener ready" when NWListener reaches .ready.
// A premature "started" log here (before .ready fires) is intentionally absent.

// Sync router diagnostics into DaemonDiagnostics every 10 seconds
let syncTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
syncTimer.schedule(deadline: .now() + 10, repeating: 10)
syncTimer.setEventHandler {
    DaemonDiagnostics.shared.syncFromRouter()
}
syncTimer.resume()

// Run until signal
dispatchMain()
