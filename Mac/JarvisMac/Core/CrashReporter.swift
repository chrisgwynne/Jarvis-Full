import Foundation
import Darwin
import os

// MARK: - CrashReporter
//
// Captures the two ways the app dies without a trace today:
//   1. Uncaught NSExceptions (NSSetUncaughtExceptionHandler)
//   2. Fatal signals — SIGABRT (Swift fatalError/precondition), SIGSEGV,
//      SIGBUS, SIGILL, SIGFPE, SIGTRAP
//
// Reports are persisted to the same Diagnostics directory SelfMonitor uses
// (~/Library/Application Support/JarvisMac/Diagnostics/Crashes/) and surfaced
// on the next launch via `surfacePendingReports`, which routes them through
// the existing AppState log + SelfMonitor breadcrumb infrastructure. No
// third-party services.
//
// Signal-handler constraints: only async-signal-safe calls are allowed inside
// a signal handler (no malloc, no Foundation, no os_log). The crash file is
// therefore pre-opened at install time and the handler writes raw bytes via
// write(2) + backtrace_symbols_fd(3) only.

enum CrashReporter {

    // MARK: Paths

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

    // MARK: Install

    /// Installs both handlers. Call as early as possible in app launch —
    /// before any subsystem that could crash. Idempotent.
    static func install(processName: String = "JarvisMac") {
        guard !installed else { return }
        installed = true

        // Pre-open the signal crash file so the handler never allocates.
        let path = crashesDirectory
            .appendingPathComponent("\(processName)-signal-\(Int(Date().timeIntervalSince1970)).crash")
            .path
        signalCrashFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        signalCrashPath = path

        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.writeExceptionReport(exception)
        }

        for sig in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = handleFatalSignal
            sigemptyset(&action.sa_mask)
            // SA_RESETHAND: restore default disposition after first delivery so
            // re-raising the signal terminates the process with the original
            // semantics (crash log in Console, correct exit status).
            action.sa_flags = Int32(SA_RESETHAND)
            sigaction(sig, &action, nil)
        }
    }

    // MARK: Surfacing on next launch

    struct PendingReport {
        let url: URL
        let summary: String
    }

    /// Collects crash reports written by a previous process instance, returns
    /// them for surfacing, and archives them so they are reported exactly once.
    /// The live signal file for *this* process is excluded.
    static func collectPendingReports() -> [PendingReport] {
        let fm = FileManager.default
        let archive = crashesDirectory.appendingPathComponent("Archived")
        try? fm.createDirectory(at: archive, withIntermediateDirectories: true)

        let files = (try? fm.contentsOfDirectory(
            at: crashesDirectory, includingPropertiesForKeys: nil)) ?? []

        var reports: [PendingReport] = []
        for url in files where url.pathExtension == "crash" {
            if url.path == signalCrashPath { continue }
            // Empty signal files are from clean runs (pre-opened, never written).
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size == 0 {
                try? fm.removeItem(at: url)
                continue
            }
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let firstLines = content.split(separator: "\n").prefix(3).joined(separator: " | ")
            reports.append(PendingReport(url: url, summary: firstLines))
            try? fm.moveItem(at: url, to: archive.appendingPathComponent(url.lastPathComponent))
        }

        // Keep the archive bounded — newest 20 reports.
        let archived = ((try? fm.contentsOfDirectory(
            at: archive, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .sorted { (lhs, rhs) in
                let l = ((try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate) ?? .distantPast
                let r = ((try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate) ?? .distantPast
                return l > r
            }
        for old in archived.dropFirst(20) { try? fm.removeItem(at: old) }

        return reports
    }

    /// Logs pending reports through the app's existing monitoring surfaces.
    @MainActor
    static func surfacePendingReports(state: AppState) {
        let reports = collectPendingReports()
        guard !reports.isEmpty else { return }
        for report in reports {
            Log.app.error("[CrashReporter] previous run crashed: \(report.summary)")
            state.log("crash", .error,
                "Jarvis crashed last run — report archived in Diagnostics/Crashes (\(report.url.lastPathComponent))")
        }
    }

    // MARK: - Exception path (not signal-restricted)

    private static func writeExceptionReport(_ exception: NSException) {
        let url = crashesDirectory.appendingPathComponent(
            "JarvisMac-exception-\(Int(Date().timeIntervalSince1970)).crash")
        var body = "Uncaught NSException: \(exception.name.rawValue)\n"
        body += "Reason: \(exception.reason ?? "unknown")\n"
        body += "Date: \(ISO8601DateFormatter().string(from: Date()))\n\n"
        body += exception.callStackSymbols.joined(separator: "\n")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Signal path (async-signal-safe only)

    private static let fatalSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
    private static var installed = false
    fileprivate static var signalCrashFD: Int32 = -1
    fileprivate static var signalCrashPath: String?
}

/// C-convention handler — must not capture context, allocate, or call into
/// Foundation. Writes a fixed preamble + raw backtrace to the pre-opened fd,
/// then re-raises so the OS performs its normal crash handling.
private func handleFatalSignal(_ sig: Int32) {
    let fd = CrashReporter.signalCrashFD
    if fd >= 0 {
        var preamble: [UInt8] = Array("Fatal signal ".utf8)
        // Render the signal number without allocation.
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
    // SA_RESETHAND restored the default disposition; re-raise to die properly.
    raise(sig)
}
