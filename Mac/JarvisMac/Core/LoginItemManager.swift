import Foundation
import ServiceManagement
import OSLog

/// Registers JarvisMac as a login item via `SMAppService` so it relaunches
/// after a reboot (the daemon already runs as a LaunchAgent). No helper
/// plist is required for the main-app registration.
@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    private let log = Logger(subsystem: "com.jarvis.mac", category: "loginitem")

    /// Whether the app is currently set to open at login.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register at login if not already enabled. Safe to call on every launch.
    func registerIfNeeded() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do {
            try service.register()
            log.info("Registered JarvisMac as a login item")
        } catch {
            log.error("Login-item registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove the login item (used from Settings).
    func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            log.info("Unregistered JarvisMac login item")
        } catch {
            log.error("Login-item unregister failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
