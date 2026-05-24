import SwiftUI

// MARK: - GesturePreferencesView

/// Settings tab body for hand tracking configuration.
/// Embedded in SettingsView as the "Gestures" tab.
struct GesturePreferencesView: View {

    let controller: JarvisController

    @ObservedObject private var registry = GestureCommandRegistry.shared
    @State private var editingMapping:      GestureMapping?
    @State private var editingHUDItem:      HUDItemConfig?
    @State private var showResetAlert:      Bool = false
    @State private var showCalibReset:      Bool = false
    @State private var showSpatialCalibReset: Bool = false
    @State private var calibStatsText:      String = ""

    private var coordinator: SpatialAmbientCoordinator {
        controller.spatialCoordinator
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                enableSection
                sensitivitySection
                gestureMapSection
                hudSection
                spatialCalibrationSection
                calibrationSection
            }
            .padding(24)
        }
        .sheet(item: $editingMapping)  { m in MappingEditSheet(mapping: m, registry: registry) }
        .sheet(item: $editingHUDItem)  { h in HUDItemEditSheet(item: h, registry: registry) }
        .alert("Reset Gesture Mappings?",
               isPresented: $showResetAlert) {
            Button("Reset", role: .destructive) { registry.resetToDefaults() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All custom gesture mappings and HUD labels will be restored to defaults.")
        }
        .alert("Reset Calibration Profile?",
               isPresented: $showCalibReset) {
            Button("Reset", role: .destructive) {
                GestureCalibrationStore.shared.reset()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All learned thresholds will return to factory defaults. The system will re-learn your patterns from scratch.")
        }
        .alert("Reset Spatial Calibration?",
               isPresented: $showSpatialCalibReset) {
            Button("Reset", role: .destructive) { coordinator.resetCalibration() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Spatial calibration will be cleared. The default linear mapping will be used until you calibrate again.")
        }
        .onAppear { refreshCalibStats() }
    }

    // MARK: - Enable / Dominant Hand

    private var enableSection: some View {
        card {
            HStack {
                Toggle("Enable Hand Tracking",
                       isOn: Binding(
                        get: { controller.prefs.current.handTrackingEnabled },
                        set: { v in controller.prefs.update { $0.handTrackingEnabled = v } }
                       ))
                .toggleStyle(.switch)
                Spacer()
                Label("Ambient spatial layer — no voice command needed",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.3).padding(.vertical, 4)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dominant Hand")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { controller.prefs.current.dominantHand },
                        set: { v in controller.prefs.update { $0.dominantHand = v } }
                    )) {
                        Text("Right").tag("right")
                        Text("Left").tag("left")
                        Text("Auto").tag("auto")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Smoothing Level")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Responsive")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(controller.prefs.current.gestureSmoothing) },
                                set: { v in
                                    controller.prefs.update { $0.gestureSmoothing = Int(v) }
                                    applySmoothingLevel(Int(v))
                                }
                            ),
                            in: 1...10,
                            step: 1
                        )
                        .frame(width: 160)
                        Text("Smooth")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Sensitivity Preset

    private var sensitivitySection: some View {
        card {
            Text("SENSITIVITY PRESET")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1.5)

            HStack(spacing: 12) {
                ForEach(SensitivityPreset.allCases, id: \.rawValue) { preset in
                    let isSelected = registry.sensitivityPreset == preset
                    Button {
                        registry.applyPreset(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preset.displayName)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .cyan : .primary)
                            Text(preset.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.cyan.opacity(0.08) : Color.white.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(isSelected ? Color.cyan.opacity(0.5) : Color.white.opacity(0.08))
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Gesture Mapping

    private var gestureMapSection: some View {
        // Inline card styling — avoids generic @ViewBuilder inference issues with ForEach
        VStack(alignment: .leading, spacing: 10) {
            gestureMappingHeader
            gestureMappingRows
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.08)))
        )
    }

    private var gestureMappingHeader: some View {
        HStack {
            Text("GESTURE MAPPINGS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1.5)
            Spacer()
            Button("Reset Defaults") { showResetAlert = true }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .buttonStyle(.plain)
        }
    }

    private var gestureMappingRows: some View {
        let maps = registry.mappings
        return VStack(spacing: 0) {
            ForEach(maps) { (mapping: GestureMapping) in
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: mapping.gestureType.systemImage)
                            .frame(width: 20)
                            .foregroundStyle(.cyan)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mapping.gestureType.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(mapping.isEnabled ? mapping.action.displayName : "Disabled")
                                .font(.caption)
                                .foregroundStyle(mapping.isEnabled
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(Color.red.opacity(0.7)))
                        }

                        Spacer()

                        Text(mapping.hudLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.06)))

                        Toggle("", isOn: Binding(
                            get: { mapping.isEnabled },
                            set: { v in var m = mapping; m.isEnabled = v; registry.updateMapping(m) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.80)

                        Button { editingMapping = mapping } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 5)

                    if mapping.id != maps.last?.id {
                        Divider().opacity(0.15)
                    }
                }
            }
        }
    }

    // MARK: - HUD Items

    private var hudSection: some View {
        let items = registry.hudItems
        return card {
            Text("HUD MENU LABELS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1.5)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage)
                                .frame(width: 20)
                                .foregroundStyle(item.isEnabled ? .cyan : .secondary)
                            Text(item.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(item.isEnabled ? .primary : .secondary)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { item.isEnabled },
                                set: { v in var h = item; h.isEnabled = v; registry.updateHUDItem(h) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .scaleEffect(0.80)
                            Button { editingHUDItem = item } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 5)
                        if item.id != items.last?.id { Divider().opacity(0.15) }
                    }
                }
            }
        }
    }

    // MARK: - Spatial Calibration

    private var spatialCalibrationSection: some View {
        card {
            HStack {
                Text("SPATIAL POINTER CALIBRATION")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Spacer()
                if HandCalibrationStore.shared.calibration != nil {
                    Button("Reset") { showSpatialCalibReset = true }
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .buttonStyle(.plain)
                }
            }

            if let calib = HandCalibrationStore.shared.calibration {
                let level = CalibrationQualityLevel(averageError: calib.averageError,
                                                    sampleCount:  calib.sampleCount)
                Group {
                    calibRow("Status",      "Calibrated ✓",
                             color: .cyan)
                    calibRow("Quality",     level.label,
                             color: qualityRowColor(level))
                    calibRow("Avg error",   String(format: "%.1f pts", calib.averageError),
                             color: calib.averageError < 20 ? .cyan : .orange)
                    calibRow("Max error",   String(format: "%.1f pts", calib.maxError))
                    calibRow("Points used", "\(calib.sampleCount) of 9")
                    calibRow("Score",       String(format: "%.0f%%", calib.qualityScore * 100))
                    calibRow("Calibrated",  RelativeDateTimeFormatter()
                        .localizedString(for: calib.calibratedAt, relativeTo: Date()))
                }

                if level.redoRecommended {
                    Text("Pointer accuracy may be poor. Running calibration again is recommended.")
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.85))
                        .padding(.top, 4)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("No calibration — using default linear mapping. Pointer may not land accurately.")
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.85))
                }
                .padding(.vertical, 4)
            }

            HStack(spacing: 12) {
                Button(coordinator.isCalibrating ? "Calibrating…" : "Run Calibration") {
                    coordinator.startCalibration()
                }
                .disabled(coordinator.isCalibrating)
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                Text("Maximise Jarvis window before starting for best accuracy")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private func qualityRowColor(_ level: CalibrationQualityLevel) -> Color {
        switch level {
        case .excellent:    return .cyan
        case .good:         return .green
        case .fair:         return .yellow
        case .poor:         return .orange
        case .insufficient: return .red
        }
    }

    // MARK: - Gesture Calibration Profile

    private var calibrationSection: some View {
        card {
            HStack {
                Text("CALIBRATION PROFILE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Spacer()
                Button("Reset Learning") { showCalibReset = true }
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .buttonStyle(.plain)
            }

            let cal = GestureCalibrationStore.shared.profile
            // Group A — observations
            Group {
                calibRow("Frames tracked",    "\(cal.totalFrames)")
                calibRow("Last adapted",       cal.lastAdaptedAt == .distantPast
                    ? "Not yet"
                    : RelativeDateTimeFormatter().localizedString(for: cal.lastAdaptedAt,
                                                                   relativeTo: Date()))
                calibRow("Avg pointer speed", String(format: "%.0f pts/s", cal.avgPointerSpeedPts))
                calibRow("Avg pinch dist",    String(format: "%.3f norm", cal.avgPinchDistNorm))
                calibRow("Avg tremor range",  String(format: "%.1f pts", cal.avgTremorRangePts))
                calibRow("Success / cancel",  "\(cal.successfulGestures) / \(cal.cancelledGestures)")
            }
            // Group B — adapted thresholds
            Group {
                calibRow("Learned smoothing",  String(format: "α %.3f", cal.adaptedSmoothingAlpha))
                calibRow("Learned deadzone",   String(format: "%.1f pts", cal.adaptedDeadzonePts))
                calibRow("Learned pinch thr.", String(format: "%.3f", cal.adaptedPinchThreshold))
                calibRow("Learned ptr sens",   String(format: "%.2f×", cal.adaptedPointerSensitivity))
                calibRow("2nd hand dwell",     "\(cal.adaptedSecondHandDwellFrames) frames")
                calibRow("Resize dwell",       "\(cal.adaptedResizeDwellFrames) frames")
            }

            Text("Learning is very slow and bounded. Adapted values can never deviate more than ±30% from factory defaults. Only activates after 300+ frames of tracking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private func calibRow(_ label: String, _ value: String,
                           color: Color = .white.opacity(0.75)) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    // MARK: - Helpers

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.08)))
        )
    }

    private func applySmoothingLevel(_ level: Int) {
        // Map 1–10 to alpha 0.06–0.20 (inverted: lower level = more smoothing)
        let alpha = 0.06 + (Double(level - 1) / 9.0) * 0.14
        SpatialInteractionConfig.shared.smoothingAlpha = CGFloat(alpha)
    }

    private func refreshCalibStats() {
        calibStatsText = "Ready"
    }
}

// MARK: - MappingEditSheet

struct MappingEditSheet: View {
    @State var mapping: GestureMapping
    let registry: GestureCommandRegistry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Gesture Mapping")
                .font(.headline)

            LabeledContent("Gesture") {
                Text(mapping.gestureType.displayName)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Action") {
                Picker("", selection: $mapping.action) {
                    ForEach(GestureAction.allCases, id: \.rawValue) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .labelsHidden()
            }

            LabeledContent("HUD Label") {
                TextField("Label", text: $mapping.hudLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }

            LabeledContent("Voice Phrase") {
                TextField("Optional voice trigger", text: $mapping.commandPhrase)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            Toggle("Enabled", isOn: $mapping.isEnabled)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    registry.updateMapping(mapping)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - HUDItemEditSheet

struct HUDItemEditSheet: View {
    @State var item: HUDItemConfig
    let registry: GestureCommandRegistry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit HUD Item")
                .font(.headline)

            LabeledContent("Key") {
                Text(item.key).foregroundStyle(.secondary)
            }

            LabeledContent("Label") {
                TextField("Display label", text: $item.label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            Toggle("Visible in HUD", isOn: $item.isEnabled)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    registry.updateHUDItem(item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}
