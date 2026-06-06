import Foundation
import OSLog

let logger = Logger(subsystem: "com.jarvis.brain", category: "daemon")

// ── Single-instance guard ──────────────────────────────────────────────────
// Detect a healthy JarvisBrainDaemon before binding the port.
// Prevents "Address already in use" when launchctl and Xcode both launch
// the daemon simultaneously, or when launchd auto-restarts a still-running process.
//
// STALE DAEMON DETECTION: If an old auth-requiring daemon is running, simply
// deferring to it would leave the app connecting to a daemon that rejects requests.
// We also check /version for authMode — if it is NOT "no-auth", the running daemon
// is an older build and must be replaced.

let envPort = Int(ProcessInfo.processInfo.environment["JARVIS_DAEMON_PORT"] ?? "8765") ?? 8765
let launchSource: String = {
    if let s = ProcessInfo.processInfo.environment["JARVIS_LAUNCH_SOURCE"] { return s }
    // Heuristic: if parent PID matches launchd (PID 1 or its children), likely a LaunchAgent.
    return getppid() <= 2 ? "launchagent" : "manual"
}()

logger.info("[Daemon] initialising port=\(envPort) launchSource=\(launchSource)")
logger.info("[PortAudit] port=\(envPort)")

// ── Port owner detection ───────────────────────────────────────────────────
func portOwnerPID(port: Int) -> Int32? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    task.arguments = ["-i", ":\(port)", "-n", "-P", "-t"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    task.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let first = out.components(separatedBy: .newlines).first,
          let pid = Int32(first.trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
    return pid
}

func portOwnerExecutable(pid: Int32) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-p", "\(pid)", "-o", "comm="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    task.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
}

if let ownerPID = portOwnerPID(port: envPort) {
    let ownerExec = portOwnerExecutable(pid: ownerPID)
    logger.info("[PortAudit] pid=\(ownerPID) executable=\(ownerExec)")
}

// ── Healthy instance check ─────────────────────────────────────────────────
var existingInstanceHealthy = false
let checkCfg = URLSessionConfiguration.default
checkCfg.timeoutIntervalForRequest = 1.5
let checkSession = URLSession(configuration: checkCfg)

let healthSema = DispatchSemaphore(value: 0)
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
    // Also verify the running instance is the current no-auth build.
    // Old daemons (pre no-auth) will not return authMode in /version.
    var runningAuthMode = "unknown"
    let versionSema = DispatchSemaphore(value: 0)
    if let versionURL = URL(string: "http://127.0.0.1:\(envPort)/version") {
        checkSession.dataTask(with: versionURL) { data, response, _ in
            if let data,
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                runningAuthMode = json["authMode"] as? String ?? "missing"
            }
            versionSema.signal()
        }.resume()
        versionSema.wait()
    }
    logger.info("[PortAudit] runningAuthMode=\(runningAuthMode)")

    if runningAuthMode == "no-auth" {
        // Current build already running — safe to exit.
        logger.info("[Daemon] existing no-auth instance detected — reusing daemon, exiting cleanly")
        exit(0)
    }

    // Stale auth-requiring daemon detected — kill it so the current build can bind.
    logger.warning("[PortAudit] staleDaemonDetected=true runningAuthMode=\(runningAuthMode) — killing stale daemon")
    if let stalePID = portOwnerPID(port: envPort) {
        let staleExec = portOwnerExecutable(pid: stalePID)
        logger.info("[PortAudit] killing pid=\(stalePID) executable=\(staleExec)")
        kill(stalePID, SIGTERM)
        // Give the OS time to reclaim the port before we try to bind.
        Thread.sleep(forTimeInterval: 2.0)
    } else {
        logger.warning("[PortAudit] could not determine stale PID via lsof — proceeding anyway")
        Thread.sleep(forTimeInterval: 1.0)
    }
}

logger.info("[Daemon] no existing no-auth instance — starting")

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
