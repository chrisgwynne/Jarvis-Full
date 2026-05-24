import AppKit
import Foundation

// MARK: - ActiveAppMonitor

/// Tracks the frontmost application using NSWorkspace notifications.
/// Emits `AppFocusChangedEvent`, `AppLaunchedEvent`, and `AppClosedEvent`
/// to SystemBus. Does NOT capture screenshots or do OCR.
@MainActor
final class ActiveAppMonitor {

    private(set) var current: ActiveApp = .none
    private(set) var previous: ActiveApp = .none

    // Optional lightweight callback (in addition to SystemBus) for direct consumers.
    var onFocusChanged: ((ActiveApp, ActiveApp) -> Void)?

    private var observers: [Any] = []

    init() {
        seed()
        observeWorkspace()
    }

    deinit {
        for obs in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Window title (permission-free via CGWindowList)

    func windowTitle(for pid: pid_t) -> String {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return "" }

        // Find the topmost non-desktop window owned by this PID.
        for info in list {
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                ownerPID == pid,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,                                      // normal window layer
                let name = info[kCGWindowName as String] as? String,
                !name.isEmpty
            else { continue }
            return name
        }
        return ""
    }

    // MARK: - Private

    private func seed() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let title = windowTitle(for: app.processIdentifier)
        current = ActiveApp(
            name: app.localizedName ?? "",
            bundleID: app.bundleIdentifier ?? "",
            windowTitle: title,
            timestamp: Date()
        )
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter

        let focusObs = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleActivate(note)
            }
        }

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleLaunch(note)
            }
        }

        let terminateObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleTerminate(note)
            }
        }

        observers = [focusObs, launchObs, terminateObs]
    }

    private func handleActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }

        let title = windowTitle(for: app.processIdentifier)
        let newApp = ActiveApp(
            name: app.localizedName ?? "",
            bundleID: app.bundleIdentifier ?? "",
            windowTitle: title,
            timestamp: Date()
        )

        // Suppress duplicate events for the same app (e.g., window cycle within same app)
        if newApp.bundleID == current.bundleID && newApp.windowTitle == current.windowTitle {
            return
        }

        previous = current
        current = newApp

        onFocusChanged?(current, previous)

        SystemBus.shared.publish(AppFocusChangedEvent(
            previousApp: previous.name,
            previousBundleID: previous.bundleID,
            activeApp: current.name,
            activeBundleID: current.bundleID,
            windowTitle: current.windowTitle
        ))
    }

    private func handleLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        SystemBus.shared.publish(AppLaunchedEvent(
            appName: app.localizedName ?? "",
            bundleID: app.bundleIdentifier ?? ""
        ))
    }

    private func handleTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        SystemBus.shared.publish(AppClosedEvent(
            appName: app.localizedName ?? "",
            bundleID: app.bundleIdentifier ?? ""
        ))
    }
}
