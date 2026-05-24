import SwiftUI
import AppKit

@main
struct JarvisMacApp: App {
    @State private var state: AppState
    @State private var controller: JarvisController

    init() {
        let s = AppState()
        _state = State(initialValue: s)
        _controller = State(initialValue: JarvisController(state: s))
    }

    var body: some Scene {
        WindowGroup("Jarvis") {
            CommandCentreView(state: state, controller: controller)
                .task {
                    state.log("app", .info, "Launching JarvisMac")
                    await controller.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Jarvis") {
                Button("Push to Talk") { controller.toggleListening() }
                    .keyboardShortcut(.space, modifiers: [.command])
                Button("Stop Speaking") { controller.stopSpeaking() }
                    .keyboardShortcut(".", modifiers: [.command])
                Divider()
                Button("Toggle Command Centre") { controller.toggleCommandCentre() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Capture Camera Frame") {
                    Task { await controller.captureCameraAndDescribe(announce: true) }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Spatial Diagnostics") {
                    // Spatial interaction is ambient — this opens the live
                    // diagnostics overlay showing tracking state and FPS.
                    controller.spatialOverlay.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Read Screen Text") {
                    Task { await controller.captureCameraAndDescribe(announce: true, mode: .readText) }
                }
                Button("Watch the Desk") { controller.beginWatchingDesk() }
                Button("Stop Watching") { controller.stopWatchingDesk() }
                Divider()
                Button("Show Jarvis Help") {
                    Task { await controller.execute(.showHelp) }
                }
                .keyboardShortcut("?", modifiers: [.command])
            }

            // Replace macOS's empty default Help menu (which only appears
            // if the app ships a HelpBook).  Route both items at the
            // living-documentation overlay so the menu, the voice
            // command, and the in-app shortcut all reach the same place.
            CommandGroup(replacing: .help) {
                Button("Jarvis Help") {
                    Task { await controller.execute(.showHelp) }
                }
                .keyboardShortcut("?", modifiers: [.command])

                Button("What Can Jarvis Do?") {
                    Task { await controller.execute(.showHelp) }
                }
            }
        }

        Settings {
            SettingsView(state: state, controller: controller)
        }
    }
}
