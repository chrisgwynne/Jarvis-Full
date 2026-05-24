import Foundation
import Darwin.Mach

/// Immediate-flush crash breadcrumb logger.
///
/// Appends a timestamped, memory-annotated line to disk on every significant
/// lifecycle event. Uses `FileHandle.write` for synchronous (non-buffered)
/// writes — every entry lands on disk even if the process is about to crash.
///
/// Log: `~/Library/Application Support/JarvisMac/crash-breadcrumbs.log`
/// Rotates to `.bak` at 2 MB.
final class CrashBreadcrumbLog {

    static let shared = CrashBreadcrumbLog()

    private let url: URL
    private var fileHandle: FileHandle?
    // Serial queue ensures writes from background Tasks never interleave.
    private let queue = DispatchQueue(label: "com.jarvis.breadcrumb", qos: .utility)

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("crash-breadcrumbs.log")

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()

        rotateIfNeeded()
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        write(subsystem: "app", action: "session_start",
              detail: "PID=\(ProcessInfo.processInfo.processIdentifier) version=\(ver)")
    }

    // MARK: - Public API

    /// Synchronously append a breadcrumb entry to disk.
    ///
    /// - Parameters:
    ///   - subsystem: e.g. `"camera"`, `"obsidian"`, `"health"`
    ///   - action:    e.g. `"start"`, `"stop"`, `"error"`
    ///   - detail:    optional free-text context
    func write(subsystem: String, action: String, detail: String = "") {
        let ts  = ISO8601DateFormatter().string(from: Date())
        let mem = Self.residentMemoryMB()
        let memStr = mem >= 0 ? "\(mem)MB" : "?MB"
        let line: String
        if detail.isEmpty {
            line = "[\(ts)] [\(memStr)] \(subsystem):\(action)\n"
        } else {
            line = "[\(ts)] [\(memStr)] \(subsystem):\(action) — \(detail)\n"
        }
        let data = Data(line.utf8)
        queue.sync { [weak self] in
            self?.fileHandle?.write(data)
            self?.fileHandle?.synchronizeFile()
        }
    }

    // MARK: - Convenience

    func subsystemStart(_ name: String) {
        write(subsystem: name, action: "start")
    }

    func subsystemStop(_ name: String) {
        write(subsystem: name, action: "stop")
    }

    func subsystemSkipped(_ name: String, reason: String = "disabled") {
        write(subsystem: name, action: "skipped", detail: reason)
    }

    func subsystemError(_ name: String, _ msg: String) {
        write(subsystem: name, action: "error", detail: msg)
    }

    func emergencyStop(reason: String) {
        write(subsystem: "health", action: "EMERGENCY_STOP", detail: reason)
    }

    // MARK: - Helpers

    /// Current process resident-set size in MB. Returns -1 on failure.
    static func residentMemoryMB() -> Int {
        var info  = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size) / (1_024 * 1_024)
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size  = attrs[.size] as? Int,
              size > 2 * 1_024 * 1_024 else { return }
        fileHandle?.closeFile()
        fileHandle = nil
        let bak = url.deletingLastPathComponent()
                     .appendingPathComponent("crash-breadcrumbs.bak.log")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.moveItem(at: url, to: bak)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        write(subsystem: "app", action: "log_rotated")
    }

    deinit { fileHandle?.closeFile() }
}
