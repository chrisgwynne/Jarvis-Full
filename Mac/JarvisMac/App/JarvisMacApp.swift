import SwiftUI
import AppKit

@main
struct JarvisMacApp: App {
    // The delegate owns the long-lived runtime objects and the launch
    // lifecycle (accessory activation, bootstrap, login-item registration)
    // so the app behaves as a proper menubar app rather than a windowed one.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menubar presence — this is the app's primary surface. As an
        // accessory app there is no Dock icon; everything hangs off here.
        MenuBarExtra("Jarvis", systemImage: "waveform.circle") {
            MenuBarContent(state: appDelegate.state, controller: appDelegate.controller)
        }

        // The Command Centre is now an on-demand window opened from the
        // menubar / keyboard shortcut, not an always-present WindowGroup.
        Window("Jarvis", id: Self.commandCentreWindowID) {
            CommandCentreView(state: appDelegate.state, controller: appDelegate.controller)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Jarvis") {
                Button("Push to Talk") { appDelegate.controller.toggleListening() }
                    .keyboardShortcut(.space, modifiers: [.command])
                Button("Stop Speaking") { appDelegate.controller.stopSpeaking() }
                    .keyboardShortcut(".", modifiers: [.command])
                Divider()
                Button("Toggle Command Centre") {
                    NSApp.activate(ignoringOtherApps: true)
                    appDelegate.controller.toggleCommandCentre()
                }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Capture Camera Frame") {
                    Task { await appDelegate.controller.captureCameraAndDescribe(announce: true) }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Spatial Diagnostics") {
                    // Spatial interaction is ambient — this opens the live
                    // diagnostics overlay showing tracking state and FPS.
                    appDelegate.controller.spatialOverlay.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Read Screen Text") {
                    Task { await appDelegate.controller.captureCameraAndDescribe(announce: true, mode: .readText) }
                }
                Button("Watch the Desk") { appDelegate.controller.beginWatchingDesk() }
                Button("Stop Watching") { appDelegate.controller.stopWatchingDesk() }
                Divider()
                Button("Show Jarvis Help") {
                    Task { await appDelegate.controller.execute(.showHelp) }
                }
                .keyboardShortcut("?", modifiers: [.command])
            }

            // Replace macOS's empty default Help menu (which only appears
            // if the app ships a HelpBook).  Route both items at the
            // living-documentation overlay so the menu, the voice
            // command, and the in-app shortcut all reach the same place.
            CommandGroup(replacing: .help) {
                Button("Jarvis Help") {
                    Task { await appDelegate.controller.execute(.showHelp) }
                }
                .keyboardShortcut("?", modifiers: [.command])

                Button("What Can Jarvis Do?") {
                    Task { await appDelegate.controller.execute(.showHelp) }
                }
            }
        }

        Settings {
            SettingsView(state: appDelegate.state, controller: appDelegate.controller)
        }
    }

    static let commandCentreWindowID = "command-centre"
}

// MARK: - Menubar menu content

private struct MenuBarContent: View {
    let state: AppState
    let controller: JarvisController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Command Centre") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: JarvisMacApp.commandCentreWindowID)
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])

        Button("Push to Talk") { controller.toggleListening() }
            .keyboardShortcut(.space, modifiers: [.command])
        Button("Stop Speaking") { controller.stopSpeaking() }
            .keyboardShortcut(".", modifiers: [.command])

        Divider()

        Button("Capture Camera Frame") {
            Task { await controller.captureCameraAndDescribe(announce: true) }
        }
        Button("Read Screen Text") {
            Task { await controller.captureCameraAndDescribe(announce: true, mode: .readText) }
        }
        Button("Watch the Desk") { controller.beginWatchingDesk() }
        Button("Stop Watching") { controller.stopWatchingDesk() }

        Divider()

        Button("Jarvis Help") {
            Task { await controller.execute(.showHelp) }
        }
        SettingsLink { Text("Settings…") }

        Divider()

        Button("Quit Jarvis") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: [.command])
    }
}

// MARK: - App delegate (lifecycle + runtime ownership)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    lazy var controller = JarvisController(state: state)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar app: no Dock icon, no app-switcher entry.
        NSApp.setActivationPolicy(.accessory)

        // Don't bootstrap the live runtime (audio, daemon, timers) when the
        // app is loaded merely as the unit-test host — that is what hung the
        // test runner. See JarvisMacTests target / AppEnvironment.
        guard !AppEnvironment.isRunningTests else { return }

        // Crash capture must precede everything that can crash: uncaught
        // NSExceptions + fatal signals are persisted to Diagnostics/Crashes
        // and surfaced through AppState on the next launch.
        CrashReporter.install()

        // Auto-launch at login so the app comes back after a reboot alongside
        // the daemon LaunchAgent.
        LoginItemManager.shared.registerIfNeeded()

        Task { @MainActor in
            state.log("app", .info, "Launching JarvisMac")
            CrashReporter.surfacePendingReports(state: state)
            await controller.bootstrap()
        }
    }

    // Menubar app: closing the Command Centre window must not quit Jarvis.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
