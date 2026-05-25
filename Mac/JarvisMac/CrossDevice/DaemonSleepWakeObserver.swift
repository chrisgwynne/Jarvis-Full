import Foundation
import AppKit

/// Observes macOS system sleep and wake events.
/// On wake, triggers DaemonAppBridge to reconnect if disconnected.
@MainActor
final class DaemonSleepWakeObserver {
    private weak var bridge: DaemonAppBridge?
    private var observers: [NSObjectProtocol] = []

    init(bridge: DaemonAppBridge) {
        self.bridge = bridge
        start()
    }

    deinit {
        // Remove all observers synchronously — NSWorkspace notifications are safe
        // to remove from any thread, and deinit is called without actor isolation.
        let center = NSWorkspace.shared.notificationCenter
        for token in observers {
            center.removeObserver(token)
        }
    }

    private func start() {
        let center = NSWorkspace.shared.notificationCenter

        // Optional: disconnect cleanly before sleep to avoid stale socket state.
        let sleepToken = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Disconnect proactively so the daemon doesn't hold a zombie socket.
                self.bridge?.disconnect()
            }
        }

        // On wake, allow 2 seconds for the network stack to settle before reconnecting.
        let wakeToken = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    guard let bridge = self.bridge else { return }
                    if !bridge.isConnected {
                        bridge.connect()
                    }
                }
            }
        }

        observers = [sleepToken, wakeToken]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
    }
}
