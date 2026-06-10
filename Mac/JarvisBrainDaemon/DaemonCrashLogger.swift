import Foundation
import Darwin
import OSLog

// MARK: - DaemonCrashLogger
//
// The daemon runs headless under launchd — when it dies on a fatal signal
// (fatalError, segfault) there is no UI and nothing in the app's logs. This
// captures fatal signals to a crash file beside the shared JarvisMac
// diagnostics, and on the next daemon start logs (via os_log) that the
// previous instance crashed, so `log stream`/Console and the Mac app's
// daemon diagnostics make the failure visible.
//
// Same async-signal-safety rules as the app's CrashReporter: the crash file
// is pre-opened at install time and the handler only uses write(2) +
// backtrace_symbols_fd(3).

enum DaemonCrashLogger {

    static var crashesDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("JarvisMac")
            .appendingPathComponent("Diagnostics")
            .appendingPathComponent("Crashes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Install signal handlers and report any crash files from previous runs.
    static func installAndReportPrevious(logger: Logger) {
        // Report previous daemon crash files (non-empty ones), then archive.
        let fm = FileManager.default
        let archive = crashesDirectory.appendingPathComponent("Archived")
        try? fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: crashesDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.lastPathComponent.hasPrefix("JarvisBrainDaemon-signal-") {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size == 0 {
                try? fm.removeItem(at: url)
                continue
            }
            logger.error("[DaemonCrash] previous daemon instance crashed — report: \(url.lastPathComponent, privacy: .public)")
            try? fm.moveItem(at: url, to: archive.appendingPathComponent(url.lastPathComponent))
        }

        // Pre-open this run's crash file.
        let path = crashesDirectory
            .appendingPathComponent("JarvisBrainDaemon-signal-\(Int(Date().timeIntervalSince1970)).crash")
            .path
        daemonSignalCrashFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

        for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = daemonHandleFatalSignal
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESETHAND
            sigaction(sig, &action, nil)
        }
    }
}

fileprivate var daemonSignalCrashFD: Int32 = -1

private func daemonHandleFatalSignal(_ sig: Int32) {
    let fd = daemonSignalCrashFD
    if fd >= 0 {
        var preamble: [UInt8] = Array("Fatal signal ".utf8)
        var n = sig
        var digits: [UInt8] = []
        if n == 0 { digits = [UInt8(ascii: "0")] }
        while n > 0 {
            digits.insert(UInt8(ascii: "0") + UInt8(n % 10), at: 0)
            n /= 10
        }
        preamble.append(contentsOf: digits)
        preamble.append(UInt8(ascii: "\n"))
        preamble.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress, $0.count) }

        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, 64)
        backtrace_symbols_fd(&frames, count, fd)
        fsync(fd)
    }
    raise(sig)
}
