import Foundation

/// Thin wrapper around NSAppleScript with a *real* timeout. Runs the script on
/// a dedicated thread and races it against a timeout so the caller is never left
/// hanging on a long-running `tell application` call (e.g. an app showing a
/// modal dialog). The main thread never blocks.
enum AppleScriptRunner {
    struct ScriptError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Run a script source string. Returns the script's string result, or
    /// throws `ScriptError`. If the script does not complete within `timeout`
    /// seconds the call throws `.timedOut` immediately (the script keeps running
    /// on its detached thread but its result is discarded).
    static func run(_ source: String, timeout: TimeInterval = 10) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            // A single-shot guard so we resume the continuation exactly once,
            // whichever finishes first — the script thread or the timeout.
            let didResume = ResumeGuard()

            // Dedicated thread for the (synchronous, blocking) AppleScript run.
            let worker = Thread {
                guard let script = NSAppleScript(source: source) else {
                    if didResume.claim() {
                        cont.resume(throwing: ScriptError(message: "Invalid AppleScript source"))
                    }
                    return
                }
                var errInfo: NSDictionary?
                let result = script.executeAndReturnError(&errInfo)
                guard didResume.claim() else { return }   // timeout already fired
                if let errInfo {
                    let msg = (errInfo["NSAppleScriptErrorMessage"] as? String) ?? "Unknown AppleScript error"
                    cont.resume(throwing: ScriptError(message: msg))
                } else {
                    cont.resume(returning: result.stringValue ?? "")
                }
            }
            worker.stackSize = 1 << 20   // 1 MB — AppleScript can be stack-hungry
            worker.start()

            // Real timeout: fires on a separate queue, independent of the script.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if didResume.claim() {
                    cont.resume(throwing: ScriptError(message: "AppleScript timed out after \(Int(timeout))s"))
                }
            }
        }
    }

    /// Tiny thread-safe one-shot flag: the first caller to `claim()` wins.
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}
