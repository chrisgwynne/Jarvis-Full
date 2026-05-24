import SwiftUI
import AppKit

// MARK: - HandCalibrationView

/// Full-screen calibration overlay mounted inside `SpatialInteractionLayer`.
///
/// Shown when `coordinator.isCalibrating == true`. Guides the user through
/// 5–9 target points, captures Vision-space hand positions at each confirmed
/// point, fits an affine transform, and saves it via `HandCalibrationStore`.
///
/// Confirmation methods (any one triggers capture):
///   - Click/tap anywhere on the overlay
///   - Space bar or Return key (via NSEvent local monitor)
///   - Cursor dwell ≥ 1.5 s within 50 pts of the target
struct HandCalibrationView: View {

    @ObservedObject var coordinator: SpatialAmbientCoordinator

    // MARK: - Phase

    enum CalibPhase {
        case intro
        case targeting
        case result(AffineCalibration)
        case tooFewPoints
    }

    // MARK: - State

    @State private var phase: CalibPhase = .intro
    @State private var currentIndex: Int = 0
    @State private var samples: [CalibrationSample] = []
    @State private var dwellProgress: Double = 0
    @State private var viewSize: CGSize = .zero
    @State private var flashConfirm: Bool = false
    @State private var keyMonitor: Any? = nil

    private let requiredCount = 5
    private let dwellDuration: Double = 1.5
    private let dwellRadius: CGFloat  = 50

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop(in: geo.size)

                switch phase {
                case .intro:
                    introPanel
                case .targeting:
                    targetingLayer(in: geo.size)
                case .result(let calib):
                    resultPanel(calib: calib)
                case .tooFewPoints:
                    tooFewPanel
                }
            }
            .onAppear {
                viewSize = geo.size
                installKeyMonitor()
            }
            .onDisappear {
                removeKeyMonitor()
            }
            .onChange(of: geo.size) { _, s in viewSize = s }
        }
    }

    // MARK: - Backdrop

    private func backdrop(in size: CGSize) -> some View {
        Color.black.opacity(0.82)
            .ignoresSafeArea()
            .onTapGesture { confirmCurrent() }
    }

    // MARK: - Intro

    private var introPanel: some View {
        VStack(spacing: 24) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 48))
                .foregroundStyle(.cyan)

            Text("Hand Tracking Calibration")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 10) {
                instructionRow("1", "9 target dots will appear one at a time")
                instructionRow("2", "Point your index finger at each dot")
                instructionRow("3", "Press Space, Return, or click to confirm each point")
                instructionRow("4", "At least 5 points are needed — 9 gives best accuracy")
            }
            .padding(20)
            .background(roundedBg)

            Text("Maximise the Jarvis window for best results")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))

            HStack(spacing: 16) {
                cancelButton
                Button("Begin Calibration") { beginCalibration() }
                    .buttonStyle(CyanPillButtonStyle())
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(40)
        .frame(maxWidth: 480)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.90))
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.cyan.opacity(0.25)))
        )
    }

    private func instructionRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.cyan.opacity(0.15)))

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: - Targeting

    private func targetingLayer(in size: CGSize) -> some View {
        let targets = HandCalibrationEngine.targetPositions(in: size)
        let target  = currentIndex < targets.count ? targets[currentIndex] : CGPoint(x: size.width / 2, y: size.height / 2)

        return ZStack {
            // Progress bar at top
            progressBar(in: size)

            // Target dot
            targetDot(at: target, in: size)

            // Cursor indicator — bright filled dot so user can see finger position
            if coordinator.cursorState.isVisible {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.35))
                        .frame(width: 44, height: 44)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .cyan, radius: 6)
                }
                .position(coordinator.cursorState.position)
            }

            // No-hand hint shown when cursor is not visible during targeting
            if !coordinator.cursorState.isVisible {
                VStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Raise your index finger toward the camera")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 80)
            }

            // Flash confirmation ring
            if flashConfirm {
                Circle()
                    .strokeBorder(Color.green, lineWidth: 3)
                    .frame(width: 80, height: 80)
                    .position(target)
                    .transition(.opacity)
            }

            // Instruction hint at bottom
            hintBar(in: size)
        }
        .onChange(of: coordinator.cursorState.position) { _, pos in
            updateDwell(cursorPos: pos, target: target)
        }
    }

    private func progressBar(in size: CGSize) -> some View {
        let total   = HandCalibrationEngine.targetPositions(in: size).count
        let done    = samples.count
        let pct     = Double(done) / Double(total)

        return VStack(spacing: 6) {
            HStack {
                Text("Point \(currentIndex + 1) of \(total)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if samples.count >= requiredCount {
                    Button("Finish (\(samples.count) pts)") { finishCalibration() }
                        .buttonStyle(CyanPillButtonStyle())
                        .keyboardShortcut("f", modifiers: [.command])
                }
                cancelButton
            }
            .padding(.horizontal, 20)

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 4)
                    Capsule()
                        .fill(Color.cyan)
                        .frame(width: g.size.width * pct, height: 4)
                        .animation(.easeInOut(duration: 0.3), value: pct)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 20)
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func targetDot(at target: CGPoint, in size: CGSize) -> some View {
        ZStack {
            // Outer pulse ring
            TargetPulseRing()

            // Cross-hair arms
            Group {
                Rectangle()
                    .fill(Color.cyan.opacity(0.5))
                    .frame(width: 40, height: 1)
                Rectangle()
                    .fill(Color.cyan.opacity(0.5))
                    .frame(width: 1, height: 40)
            }

            // Centre dot
            Circle()
                .fill(Color.cyan)
                .frame(width: 12, height: 12)
                .shadow(color: .cyan, radius: 8)

            // Dwell ring
            if dwellProgress > 0 {
                Circle()
                    .trim(from: 0, to: dwellProgress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.05), value: dwellProgress)
            }

            // Dot number label
            Text("\(currentIndex + 1)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .offset(y: 30)
        }
        .position(target)
    }

    private func hintBar(in size: CGSize) -> some View {
        HStack(spacing: 20) {
            hintChip("Space / Return", "Confirm")
            hintChip("Click", "Confirm")
            hintChip("Hold 1.5 s", "Auto-confirm")
            if samples.count >= requiredCount {
                hintChip("⌘F", "Finish early")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.75))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 24)
    }

    private func hintChip(_ key: String, _ action: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
            Text(action)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - Result

    private func resultPanel(calib: AffineCalibration) -> some View {
        let level = CalibrationQualityLevel(averageError: calib.averageError,
                                            sampleCount:  calib.sampleCount)
        return VStack(spacing: 24) {
            Image(systemName: level.redoRecommended ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(level.redoRecommended ? .orange : .cyan)

            Text("Calibration Complete")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 8) {
                qualityRow("Quality",       level.label,
                           color: qualityColor(level))
                qualityRow("Avg error",     String(format: "%.1f pts", calib.averageError),
                           color: calib.averageError < 20 ? .cyan : .orange)
                qualityRow("Max error",     String(format: "%.1f pts", calib.maxError))
                qualityRow("Points used",   "\(calib.sampleCount) / 9")
                qualityRow("Score",         String(format: "%.0f%%", calib.qualityScore * 100))
            }
            .padding(16)
            .background(roundedBg)

            if level.redoRecommended {
                Text("Consider re-running calibration for better pointer accuracy.")
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.85))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 14) {
                Button("Redo") { restartCalibration() }
                    .buttonStyle(OutlinePillButtonStyle())

                Button("Apply & Close") {
                    HandCalibrationStore.shared.save(calib)
                    coordinator.applyCalibration(calib)
                    coordinator.endCalibration()
                }
                .buttonStyle(CyanPillButtonStyle())
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(40)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.cyan.opacity(0.22)))
        )
    }

    private func qualityRow(_ key: String, _ value: String,
                             color: Color = .white.opacity(0.75)) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    // MARK: - Too few points

    private var tooFewPanel: some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text("Not Enough Points")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("At least \(requiredCount) confirmed points are required. Only \(samples.count) were captured.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 14) {
                cancelButton
                Button("Try Again") { restartCalibration() }
                    .buttonStyle(CyanPillButtonStyle())
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.orange.opacity(0.30)))
        )
    }

    // MARK: - Shared

    private var cancelButton: some View {
        Button("Cancel") { coordinator.endCalibration() }
            .buttonStyle(OutlinePillButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
    }

    private var roundedBg: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08)))
    }

    // MARK: - Logic

    private func beginCalibration() {
        samples      = []
        currentIndex = 0
        dwellProgress = 0
        phase        = .targeting
    }

    private func restartCalibration() {
        samples       = []
        currentIndex  = 0
        dwellProgress = 0
        phase         = .targeting
    }

    private var isTargeting: Bool {
        if case .targeting = phase { return true }
        return false
    }

    private func confirmCurrent() {
        guard isTargeting else { return }
        let targets = HandCalibrationEngine.targetPositions(in: viewSize)
        guard currentIndex < targets.count else { return }

        let visionPt = coordinator.rawVisionPoint
        let targetPt = targets[currentIndex]

        // Only record if we have a valid Vision reading
        guard visionPt != .zero else { return }

        samples.append(CalibrationSample(visionPoint: visionPt, targetPoint: targetPt))
        dwellProgress = 0

        // Flash feedback
        withAnimation(.easeOut(duration: 0.15)) { flashConfirm = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation { flashConfirm = false }
        }

        let nextIndex = currentIndex + 1
        if nextIndex < targets.count {
            currentIndex = nextIndex
        } else {
            finishCalibration()
        }
    }

    private func finishCalibration() {
        if samples.count < HandCalibrationEngine.minimumSamples {
            phase = .tooFewPoints
            return
        }
        if let calib = HandCalibrationEngine.fit(samples: samples) {
            phase = .result(calib)
        } else {
            phase = .tooFewPoints
        }
    }

    // MARK: - Dwell

    private func updateDwell(cursorPos: CGPoint, target: CGPoint) {
        guard isTargeting else { dwellProgress = 0; return }
        let dist = hypot(cursorPos.x - target.x, cursorPos.y - target.y)
        if dist < dwellRadius {
            dwellProgress = min(dwellProgress + (1.0 / 60.0) / dwellDuration, 1.0)
            if dwellProgress >= 1.0 { confirmCurrent() }
        } else {
            dwellProgress = max(0, dwellProgress - 0.05)
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            switch event.keyCode {
            case 49:       // Space
                confirmCurrent()
                return nil
            case 36, 76:   // Return, numpad Enter
                if case .targeting = phase { confirmCurrent(); return nil }
                return event
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    // MARK: - Helpers

    private func qualityColor(_ level: CalibrationQualityLevel) -> Color {
        switch level {
        case .excellent:    return .cyan
        case .good:         return .green
        case .fair:         return .yellow
        case .poor:         return .orange
        case .insufficient: return .red
        }
    }
}

// MARK: - TargetPulseRing

private struct TargetPulseRing: View {
    @State private var phase: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.cyan.opacity(0.35 - phase * 0.25), lineWidth: 2)
                .frame(width: 56 + phase * 20, height: 56 + phase * 20)
            Circle()
                .strokeBorder(Color.cyan.opacity(0.20), lineWidth: 1)
                .frame(width: 72, height: 72)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }
}

// MARK: - Button Styles

private struct CyanPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Capsule().fill(Color.cyan.opacity(configuration.isPressed ? 0.75 : 1.0)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
    }
}

private struct OutlinePillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0.04))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.20)))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
    }
}
