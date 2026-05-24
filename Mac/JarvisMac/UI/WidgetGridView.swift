import SwiftUI

/// Modular widget grid driven by `WidgetManager`.
///
/// In `.dashboard` (Workspace) mode only non-developer widgets appear.
/// In `.developer` mode all widgets are shown.
/// Each widget can be individually closed via the close button on `WidgetCard`.
struct WidgetGridView: View {
    let state: AppState
    let controller: JarvisController
    var mode: UIMode = .dashboard
    var manager: WidgetManager? = nil

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 16, alignment: .top)]
    }

    /// Widgets currently visible for the active mode.
    private var visibleKinds: [WidgetKind] {
        guard let mgr = manager else {
            // No manager — show all widgets (legacy fallback).
            return WidgetKind.allCases
        }
        return mgr.visibleWidgets(for: mode)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(visibleKinds) { kind in
                    widgetView(for: kind)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .animation(.easeInOut(duration: 0.22), value: visibleKinds.map(\.rawValue))
        }
    }

    @ViewBuilder
    private func widgetView(for kind: WidgetKind) -> some View {
        let onClose: () -> Void = { manager?.close(kind) }
        switch kind {
        case .voiceStatus:
            VoiceStatusWidget(state: state, controller: controller, onClose: manager != nil ? onClose : nil)
        case .transcript:
            TranscriptWidget(state: state, onClose: manager != nil ? onClose : nil)
        case .camera:
            CameraPreviewWidget(state: state, controller: controller, onClose: manager != nil ? onClose : nil)
        case .vision:
            VisionWidget(state: state, controller: controller, onClose: manager != nil ? onClose : nil)
        case .systemStatus:
            SystemStatusWidget(state: state, onClose: manager != nil ? onClose : nil)
        case .homeAssistant:
            HomeAssistantWidget(state: state, controller: controller, onClose: manager != nil ? onClose : nil)
        case .context:
            ContextWidget(state: state, controller: controller, onClose: manager != nil ? onClose : nil)
        case .androidLink:
            AndroidConnectionWidget(state: state, onClose: manager != nil ? onClose : nil)
        case .speechEngine:
            SpeechEngineWidget(state: state, controller: controller, onClose: manager != nil ? onClose : nil)
        case .wakeWord:
            WakeWordWidget(state: state, controller: controller, onClose: manager != nil ? onClose : nil)
        case .audioDevice:
            AudioDeviceWidget(state: state, controller: controller, onClose: manager != nil ? onClose : nil)
        case .latency:
            LatencyWidget(state: state, onClose: manager != nil ? onClose : nil)
        case .debugLogs:
            DebugLogsWidget(state: state, onClose: manager != nil ? onClose : nil)
        }
    }
}
