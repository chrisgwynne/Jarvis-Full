import AppKit
import Foundation

/// Manages the JarvisBrainDaemon LaunchAgent lifecycle from within the main app.
@MainActor
final class DaemonManager: ObservableObject {
    static let shared = DaemonManager()

    enum DaemonStatus: Equatable {
        case notInstalled
        case stopped
        case running
        case crashed
        case unhealthy   // launchctl says running (pid > 0) but HTTP /health fails
        case unknown
    }

    // MARK: - Port owner detection

    struct PortOwnerInfo {
        enum Owner {
            case nobody
            case daemon
            case app
            case other(String)
        }
        let pid: Int?
        let processName: String?
        let owner: Owner

        var isConflict: Bool {
            if case .other = owner { return true }
            return false
        }

        var description: String {
            switch owner {
            case .nobody:         return "Port 8765 is free"
            case .daemon:         return "Port 8765 owned by JarvisBrainDaemon ✓"
            case .app:            return "Port 8765 owned by JarvisMac (legacy mode)"
            case .other(let n):   return "⚠️ Port 8765 conflict: \(n) (PID \(pid ?? 0))"
            }
        }
    }

    // MARK: - LaunchAgent service state

    enum LaunchAgentServiceState {
        case notLoaded
        case running(pid: Int)
        case stopped          // loaded but pid = 0
        case failed(lastExit: Int)
        case unknown
    }

    @Published var status: DaemonStatus = .unknown
    @Published var isInstalled: Bool = false
    @Published var lastHeartbeat: Date? = nil
    @Published var gatewayURL: String = "http://127.0.0.1:8765"
    @Published var connectedDevices: Int = 0
    @Published var daemonUptimeSeconds: Double = 0
    @Published var portOwner: PortOwnerInfo = PortOwnerInfo(pid: nil, processName: nil, owner: .nobody)
    @Published var lastLaunchctlError: String = ""

    private let plistLabel = "com.jarvis.brain"
    private var pollTimer: Timer?

    var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.jarvis.brain.plist")
    }

    var daemonBinaryURL: URL {
        // In development builds, JarvisBrainDaemon is a standalone executable
        // that sits alongside JarvisMac.app in the same DerivedData Debug/ folder.
        // It is NOT embedded inside the app bundle.
        // .app → parent (Debug/) → JarvisBrainDaemon
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("JarvisBrainDaemon")
    }

    var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
    }

    // MARK: - Install / Uninstall

    func install() {
        let uid = getuid()
        let plistContent = makePlistContent()
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
        isInstalled = true
        pollStatus()
    }

    func uninstall() {
        let uid = getuid()
        runLaunchctl(["bootout", "gui/\(uid)/\(plistLabel)"])
        try? FileManager.default.removeItem(at: plistURL)
        isInstalled = false
        status = .notInstalled
    }

    func start() {
        let uid = getuid()
        runLaunchctl(["kickstart", "-k", "gui/\(uid)/\(plistLabel)"])
    }

    func stop() {
        let uid = getuid()
        runLaunchctl(["kill", "SIGTERM", "gui/\(uid)/\(plistLabel)"])
    }

    func restart() {
        let uid = getuid()
        runLaunchctl(["kickstart", "-k", "gui/\(uid)/\(plistLabel)"])
    }

    // MARK: - Status polling

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollStatus() }
        }
        pollStatus()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func pollStatus() {
        isInstalled = FileManager.default.fileExists(atPath: plistURL.path)
        if !isInstalled {
            status = .notInstalled
            portOwner = detectPortOwner()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Port ownership check
            self.portOwner = self.detectPortOwner()

            // Query launchd for the authoritative service state
            let agentState = self.queryLaunchAgentState()
            let alive = await self.checkDaemonHealth()

            if alive {
                self.status = .running
                self.lastHeartbeat = Date()
            } else {
                switch agentState {
                case .running:
                    // Process is alive but /health failed — unhealthy (bound but not listening)
                    self.status = .unhealthy
                case .failed(let code):
                    self.lastLaunchctlError = "Last exit: \(code)"
                    self.status = .crashed
                case .stopped:
                    self.status = .stopped
                case .notLoaded:
                    self.status = .notInstalled
                case .unknown:
                    self.status = .unknown
                }
            }
        }
    }

    func checkDaemonHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8765/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["daemon"] as? Bool == true {
                if let uptime = json["uptimeSeconds"] as? Double {
                    self.daemonUptimeSeconds = uptime
                }
                return true
            }
        } catch {}
        return false
    }

    func openLogs() {
        let out = logsDirectory.appendingPathComponent("JarvisBrainDaemon.out.log")
        NSWorkspace.shared.open(out)
    }

    // MARK: - LaunchAgent state query

    /// Parse `launchctl print` output into a typed state.
    /// Internal (not private) so it is callable from unit tests.
    func queryLaunchAgentState() -> LaunchAgentServiceState {
        let output = runLaunchctl(["print", "gui/\(getuid())/\(plistLabel)"])
        if output.contains("No such process") || output.contains("could not find service") {
            return .notLoaded
        }
        // Parse pid = N
        if let pidRange = output.range(of: #"pid = (\d+)"#, options: .regularExpression) {
            let pidStr = output[pidRange]
                .replacingOccurrences(of: "pid = ", with: "")
            let pid = Int(pidStr.trimmingCharacters(in: .whitespaces)) ?? 0
            if pid > 0 { return .running(pid: pid) }
        }
        // Parse last exit status
        if let exitRange = output.range(of: #"last exit code = (-?\d+)"#, options: .regularExpression) {
            let codeStr = output[exitRange]
                .replacingOccurrences(of: "last exit code = ", with: "")
            let code = Int(codeStr.trimmingCharacters(in: .whitespaces)) ?? 0
            if code != 0 { return .failed(lastExit: code) }
        }
        return .stopped
    }

    // MARK: - Port ownership detection

    func detectPortOwner() -> PortOwnerInfo {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-i", ":8765", "-n", "-P", "-t"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output.isEmpty {
            return PortOwnerInfo(pid: nil, processName: nil, owner: .nobody)
        }
        let pidStr = output.components(separatedBy: .newlines).first ?? ""
        let pid = Int(pidStr.trimmingCharacters(in: .whitespaces)) ?? 0

        // Get process name from pid
        let nameTask = Process()
        nameTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        nameTask.arguments = ["-p", "\(pid)", "-o", "comm="]
        let namePipe = Pipe()
        nameTask.standardOutput = namePipe
        nameTask.standardError = Pipe()
        try? nameTask.run()
        nameTask.waitUntilExit()
        let name = String(data: namePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"

        let owner: PortOwnerInfo.Owner
        if name.contains("JarvisBrainDaemon") { owner = .daemon }
        else if name.contains("JarvisMac")    { owner = .app }
        else                                  { owner = .other(name) }

        return PortOwnerInfo(pid: pid, processName: name, owner: owner)
    }

    // MARK: - Helpers

    @discardableResult
    func runLaunchctl(_ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func makePlistContent() -> String {
        let binaryPath = daemonBinaryURL.path
        let outLog = logsDirectory.appendingPathComponent("JarvisBrainDaemon.out.log").path
        let errLog = logsDirectory.appendingPathComponent("JarvisBrainDaemon.err.log").path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.jarvis.brain</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(outLog)</string>
            <key>StandardErrorPath</key>
            <string>\(errLog)</string>
        </dict>
        </plist>
        """
    }
}
