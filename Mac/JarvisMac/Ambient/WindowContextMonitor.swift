import AppKit
import Foundation

// MARK: - WindowContextMonitor

/// Polls for active window title changes without taking screenshots.
/// Uses CGWindowListCopyWindowInfo (permission-free) and optionally
/// AX APIs (requires Accessibility permission) for richer detail.
///
/// The polling interval is intentionally slow (default 5 s) — this is
/// a passive background signal, not real-time tracking.
@MainActor
final class WindowContextMonitor {

    private(set) var currentWindowTitle: String = ""
    private(set) var currentApp: String = ""

    var onWindowChanged: ((String, String) -> Void)?   // (appName, windowTitle)

    private var pollTask: Task<Void, Never>?
    private var pollInterval: TimeInterval

    init(pollIntervalSeconds: TimeInterval = 5.0) {
        self.pollInterval = pollIntervalSeconds
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 5) * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Query

    /// Get the frontmost window title for a given PID. Permission-free.
    func windowTitle(for pid: pid_t) -> String {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return "" }

        for info in list {
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                ownerPID == pid,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let name = info[kCGWindowName as String] as? String,
                !name.isEmpty
            else { continue }
            return name
        }
        return ""
    }

    // MARK: - Private

    private func poll() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let app = front.localizedName ?? ""
        let title = windowTitle(for: front.processIdentifier)

        guard app != currentApp || title != currentWindowTitle else { return }

        currentApp = app
        currentWindowTitle = title
        onWindowChanged?(app, title)
    }
}
