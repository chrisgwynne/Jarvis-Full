import Foundation

/// Small launch-environment probes used to keep test runs from triggering
/// live side effects.
enum AppEnvironment {
    /// True when the process is hosting an XCTest bundle. The app target is
    /// loaded as the test host for `JarvisMacTests`, so the SwiftUI lifecycle
    /// still runs — we use this to skip `controller.bootstrap()` (audio,
    /// daemon, timers) which otherwise hangs the test runner at startup.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
