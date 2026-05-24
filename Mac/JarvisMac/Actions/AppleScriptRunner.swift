import Foundation

/// Thin wrapper around NSAppleScript with a timeout. Runs scripts on a
/// background queue so the main thread never blocks on long-running
/// `tell application` calls.
enum AppleScriptRunner {
    struct ScriptError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Run a script source string. Returns the script's string result, or
    /// throws `ScriptError`.
    static func run(_ source: String, timeout: TimeInterval = 10) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(throwing: ScriptError(message: "Invalid AppleScript source"))
                    return
                }
                var errInfo: NSDictionary?
                let result = script.executeAndReturnError(&errInfo)
                if Date().timeIntervalSince(started) > timeout {
                    cont.resume(throwing: ScriptError(message: "AppleScript timed out"))
                    return
                }
                if let errInfo {
                    let msg = (errInfo["NSAppleScriptErrorMessage"] as? String) ?? "Unknown AppleScript error"
                    cont.resume(throwing: ScriptError(message: msg))
                    return
                }
                cont.resume(returning: result.stringValue ?? "")
            }
        }
    }
}
