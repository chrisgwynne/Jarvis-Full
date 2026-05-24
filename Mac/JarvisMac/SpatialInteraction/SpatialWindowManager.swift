import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

// MARK: - WindowSnapshot

/// An immutable point-in-time record of a visible window's state.
struct WindowSnapshot: Identifiable, Equatable {
    let id: UUID
    let appName: String
    let bundleID: String
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let isFocused: Bool
    let capturedAt: Date

    /// Internal pid used for AXUIElement operations — NOT part of public identity.
    fileprivate let pid: pid_t

    static func == (lhs: WindowSnapshot, rhs: WindowSnapshot) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - WindowEdge

enum WindowEdge {
    case left, right, top, bottom
}

// MARK: - WindowSnapTarget

enum WindowSnapTarget {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case leftThird
    case centerThird
    case rightThird
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case maximize
    case center(size: CGSize)
}

// MARK: - SpatialWindowManager

@MainActor
@Observable
final class SpatialWindowManager {

    static let shared = SpatialWindowManager()

    // MARK: - Observable state

    private(set) var capturedWindows: [WindowSnapshot] = []
    private(set) var isAccessibilityGranted: Bool = false

    // MARK: - Init

    private init() {
        isAccessibilityGranted = AXIsProcessTrusted()
    }

    // MARK: - Accessibility check

    /// Returns whether Accessibility is granted. Prompts the user if not.
    @discardableResult
    func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        isAccessibilityGranted = trusted
        return trusted
    }

    // MARK: - Window discovery

    /// Refreshes `capturedWindows` from the current on-screen window list.
    func refreshWindows() async {
        isAccessibilityGranted = AXIsProcessTrusted()

        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            print("[SpatialWindowManager] CGWindowListCopyWindowInfo returned nil")
            return
        }

        // Build a pid → bundleID map from running applications for fast lookup.
        var pidToBundleID: [pid_t: String] = [:]
        var pidToFocused: [pid_t: Bool] = [:]
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            pidToBundleID[app.processIdentifier] = app.bundleIdentifier ?? ""
            pidToFocused[app.processIdentifier] = (app.processIdentifier == frontPID)
        }

        var snapshots: [WindowSnapshot] = []
        let now = Date()

        for info in rawList {
            // Skip windows without an owner PID or name.
            guard
                let pid = (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }),
                let appName = info[kCGWindowOwnerName as String] as? String,
                !appName.isEmpty
            else { continue }

            // Skip windows owned by processes that are not regular apps (e.g. Dock, WindowServer).
            guard pidToBundleID[pid] != nil else { continue }

            // kCGWindowBounds is a CFDictionary containing X/Y/Width/Height.
            var frame = CGRect.zero
            if let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] {
                frame = CGRect(
                    x: boundsDict["X"] ?? 0,
                    y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0,
                    height: boundsDict["Height"] ?? 0
                )
            }

            // Only include windows with non-trivial size (filters out 1×1 sentinel windows).
            guard frame.width > 10, frame.height > 10 else { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            let bundleID = pidToBundleID[pid] ?? ""
            let isFocused = pidToFocused[pid] ?? false

            // CGWindowList cannot report minimized state; treat as visible.
            let snapshot = WindowSnapshot(
                id: UUID(),
                appName: appName,
                bundleID: bundleID,
                title: title,
                frame: frame,
                isMinimized: false,
                isFocused: isFocused,
                capturedAt: now,
                pid: pid
            )
            snapshots.append(snapshot)
        }

        capturedWindows = snapshots
        print("[SpatialWindowManager] refreshWindows: captured \(snapshots.count) windows")
    }

    /// Returns windows whose app name or title contains `query` (case-insensitive).
    func windows(matching query: String) -> [WindowSnapshot] {
        let q = query.lowercased()
        return capturedWindows.filter {
            $0.appName.lowercased().contains(q) || $0.title.lowercased().contains(q)
        }
    }

    /// Returns the currently focused window, or nil if none is known.
    func frontmostWindow() -> WindowSnapshot? {
        capturedWindows.first { $0.isFocused }
    }

    // MARK: - Control: focus

    func focus(window: WindowSnapshot) async {
        guard accessibilityCheck(for: "focus") else { return }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else {
            print("[SpatialWindowManager] focus: no running app for pid \(window.pid)")
            return
        }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
        print("[SpatialWindowManager] focus: activated '\(window.appName)'")
    }

    // MARK: - Control: move / resize

    func move(window: WindowSnapshot, to origin: CGPoint) async {
        guard accessibilityCheck(for: "move") else { return }
        guard let axWindow = axWindow(for: window) else { return }

        var point = origin
        guard let axVal = AXValueCreate(.cgPoint, &point) else {
            print("[SpatialWindowManager] move: failed to create AXValue for origin")
            return
        }
        let result = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, axVal)
        if result != .success {
            print("[SpatialWindowManager] move: AXUIElementSetAttributeValue failed (\(result.rawValue))")
        } else {
            print("[SpatialWindowManager] move: '\(window.appName)' → \(origin)")
        }
    }

    func resize(window: WindowSnapshot, to size: CGSize) async {
        guard accessibilityCheck(for: "resize") else { return }
        guard let axWindow = axWindow(for: window) else { return }

        var sz = size
        guard let axVal = AXValueCreate(.cgSize, &sz) else {
            print("[SpatialWindowManager] resize: failed to create AXValue for size")
            return
        }
        let result = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axVal)
        if result != .success {
            print("[SpatialWindowManager] resize: AXUIElementSetAttributeValue failed (\(result.rawValue))")
        } else {
            print("[SpatialWindowManager] resize: '\(window.appName)' → \(size)")
        }
    }

    // MARK: - Control: snap

    func snap(window: WindowSnapshot, to target: WindowSnapTarget, screenSize: CGSize) async {
        guard accessibilityCheck(for: "snap") else { return }
        let rect = frameFor(target: target, screenSize: screenSize)
        await move(window: window, to: rect.origin)
        await resize(window: window, to: rect.size)
        print("[SpatialWindowManager] snap: '\(window.appName)' → \(target) frame=\(rect)")
    }

    // MARK: - Control: minimize / restore / close

    func minimize(window: WindowSnapshot) async {
        guard accessibilityCheck(for: "minimize") else { return }
        guard let axWindow = axWindow(for: window) else { return }
        let val = true as CFTypeRef
        AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, val)
        print("[SpatialWindowManager] minimize: '\(window.appName)'")
    }

    func restore(window: WindowSnapshot) async {
        guard accessibilityCheck(for: "restore") else { return }
        guard let axWindow = axWindow(for: window) else { return }
        let val = false as CFTypeRef
        AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, val)
        print("[SpatialWindowManager] restore: '\(window.appName)'")
    }

    func close(window: WindowSnapshot) async {
        guard accessibilityCheck(for: "close") else { return }
        guard let axWindow = axWindow(for: window) else { return }

        // Get the AXCloseButton and press it.
        var closeButtonRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            axWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef
        )
        guard err == .success, let closeButton = closeButtonRef else {
            print("[SpatialWindowManager] close: could not get AXCloseButton for '\(window.appName)'")
            return
        }
        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        print("[SpatialWindowManager] close: '\(window.appName)'")
    }

    // MARK: - Voice-friendly API

    /// Finds the best-matching window and snaps it. Returns true if a window was found.
    func findAndSnap(matching query: String, to target: WindowSnapTarget) async -> Bool {
        await refreshWindows()
        guard let window = windows(matching: query).first else {
            print("[SpatialWindowManager] findAndSnap: no window matching '\(query)'")
            return false
        }
        let screenSize = primaryScreenSize()
        await snap(window: window, to: target, screenSize: screenSize)
        return true
    }

    /// Finds the best-matching window and focuses it. Returns true if a window was found.
    func findAndFocus(matching query: String) async -> Bool {
        await refreshWindows()
        guard let window = windows(matching: query).first else {
            print("[SpatialWindowManager] findAndFocus: no window matching '\(query)'")
            return false
        }
        await focus(window: window)
        return true
    }

    /// Tiles up to N captured windows into the provided snap targets.
    func tileWindows(targets: [WindowSnapTarget]) async {
        guard accessibilityCheck(for: "tileWindows") else { return }
        await refreshWindows()
        let screenSize = primaryScreenSize()
        let pairs = zip(capturedWindows.prefix(targets.count), targets)
        for (window, target) in pairs {
            await snap(window: window, to: target, screenSize: screenSize)
        }
        print("[SpatialWindowManager] tileWindows: tiled \(Array(pairs).count) window(s)")
    }

    // MARK: - Private: AX helpers

    /// Resolves the first AXUIElement window for the snapshot by matching the title.
    private func axWindow(for snapshot: WindowSnapshot) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(snapshot.pid)

        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success, let windowList = windowsRef as? [AXUIElement], !windowList.isEmpty else {
            print("[SpatialWindowManager] axWindow: cannot get AX windows for '\(snapshot.appName)' (err=\(err.rawValue))")
            return nil
        }

        // Match by title; if no title match, fall back to the first window.
        if !snapshot.title.isEmpty {
            for axWin in windowList {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let winTitle = titleRef as? String,
                   winTitle == snapshot.title {
                    return axWin
                }
            }
        }
        return windowList.first
    }

    // MARK: - Private: AXValue convenience

    private func axPoint(_ point: CGPoint) -> AXValue {
        var p = point
        // AXValueCreate is guaranteed to return non-nil for .cgPoint
        return AXValueCreate(.cgPoint, &p)!
    }

    private func axSize(_ size: CGSize) -> AXValue {
        var s = size
        return AXValueCreate(.cgSize, &s)!
    }

    // MARK: - Private: snap rect computation

    private func frameFor(target: WindowSnapTarget, screenSize: CGSize) -> CGRect {
        let menuBarHeight: CGFloat = 28
        let usableY: CGFloat = menuBarHeight
        let usableH: CGFloat = screenSize.height - menuBarHeight
        let w = screenSize.width
        let h = usableH

        switch target {
        case .leftHalf:
            return CGRect(x: 0, y: usableY, width: w / 2, height: h)
        case .rightHalf:
            return CGRect(x: w / 2, y: usableY, width: w / 2, height: h)
        case .topHalf:
            return CGRect(x: 0, y: usableY, width: w, height: h / 2)
        case .bottomHalf:
            return CGRect(x: 0, y: usableY + h / 2, width: w, height: h / 2)
        case .leftThird:
            return CGRect(x: 0, y: usableY, width: w / 3, height: h)
        case .centerThird:
            return CGRect(x: w / 3, y: usableY, width: w / 3, height: h)
        case .rightThird:
            return CGRect(x: 2 * w / 3, y: usableY, width: w / 3, height: h)
        case .topLeft:
            return CGRect(x: 0, y: usableY, width: w / 2, height: h / 2)
        case .topRight:
            return CGRect(x: w / 2, y: usableY, width: w / 2, height: h / 2)
        case .bottomLeft:
            return CGRect(x: 0, y: usableY + h / 2, width: w / 2, height: h / 2)
        case .bottomRight:
            return CGRect(x: w / 2, y: usableY + h / 2, width: w / 2, height: h / 2)
        case .maximize:
            return CGRect(x: 0, y: usableY, width: w, height: h)
        case .center(let size):
            let ox = (w - size.width) / 2
            let oy = usableY + (h - size.height) / 2
            return CGRect(origin: CGPoint(x: ox, y: oy), size: size)
        }
    }

    // MARK: - Private: screen size

    private func primaryScreenSize() -> CGSize {
        NSScreen.main.map { CGSize(width: $0.frame.width, height: $0.frame.height) }
            ?? CGSize(width: 1440, height: 900)
    }

    // MARK: - Private: guard helper

    @discardableResult
    private func accessibilityCheck(for operation: String) -> Bool {
        guard isAccessibilityGranted else {
            print("[SpatialWindowManager] \(operation): Accessibility permission not granted — request via checkAccessibility()")
            return false
        }
        return true
    }
}
