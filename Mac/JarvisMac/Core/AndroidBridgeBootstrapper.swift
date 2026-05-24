import Foundation

/// Extracts the WebSocket/Android bridge and Tailscale bootstrap from JarvisController.
/// Extracted from JarvisController.bootstrap() — Sprint O decomposition.
@MainActor struct AndroidBridgeBootstrapResult {
    let bridge: AndroidBridgeManager?
    let receiver: AndroidEventReceiver?
}

@MainActor enum AndroidBridgeBootstrapper {

    /// Creates and wires AndroidBridgeManager + AndroidEventReceiver.
    /// Returns nil for both if the websocket subsystem is disabled in prefs.
    static func bootstrap(
        controller: JarvisController,
        server: WebSocketServer,
        state: AppState,
        prefs: PreferencesStore,
        proactivity: ProactivityEngine,
        context: ContextEngine,
        syncPrefs: (AndroidEventReceiver) -> Void
    ) -> AndroidBridgeBootstrapResult {
        let breadcrumb = CrashBreadcrumbLog.shared
        guard prefs.current.subsystemWebSocketEnabled else {
            breadcrumb.subsystemSkipped("websocket")
            return AndroidBridgeBootstrapResult(bridge: nil, receiver: nil)
        }

        breadcrumb.subsystemStart("websocket")
        let bridge = AndroidBridgeManager(controller: controller, state: state, prefs: prefs)
        server.delegate = bridge
        server.start()
        state.webSocketPort = prefs.current.webSocketPort
        state.androidAuthRequired = prefs.current.requireWebSocketAuth

        let receiver = AndroidEventReceiver()
        receiver.proactivity = proactivity
        receiver.context = context
        receiver.state = state
        syncPrefs(receiver)
        bridge.eventReceiver = receiver

        return AndroidBridgeBootstrapResult(bridge: bridge, receiver: receiver)
    }

    /// Wires and starts TailscaleService, or skips if the subsystem is disabled.
    static func wireTailscale(_ tailscale: TailscaleService, state: AppState, prefs: PreferencesStore) {
        let breadcrumb = CrashBreadcrumbLog.shared
        guard prefs.current.subsystemTailscaleEnabled else {
            breadcrumb.subsystemSkipped("tailscale")
            return
        }
        breadcrumb.subsystemStart("tailscale")
        tailscale.onStatusChanged = { s in
            state.tailscaleIP        = s.ip
            state.tailscaleHostname  = s.hostname
            state.tailscaleConnected = s.isConnected
        }
        tailscale.start()
    }
}
