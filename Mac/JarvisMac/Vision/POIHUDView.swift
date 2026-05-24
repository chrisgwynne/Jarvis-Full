import SwiftUI
import AVKit

// MARK: - Main POI Surveillance HUD

struct POIHUDView: View {
    @State private var module = VisionModule.shared
    @State private var settings = VisionSettings.shared
    @State private var selectedFeedID: UUID? = nil
    @State private var displayMode: DisplayMode = .grid
    @State private var showEventLog: Bool = false
    @State private var showSettings: Bool = false

    enum DisplayMode {
        case grid, focus, cinematic
    }

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top status bar
                topBar

                // Main content
                Group {
                    switch displayMode {
                    case .grid:     gridView
                    case .focus:    focusView
                    case .cinematic: cinematicView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom threat bar
                ThreatStatusBar(
                    threatLevel: module.threatClassifier.sceneThreatLevel,
                    targetCount: module.allActiveTargets.count
                )
            }

            // Side event log panel
            if showEventLog {
                HStack {
                    Spacer()
                    EventLogPanel(memory: module.sceneMemory)
                        .frame(width: 260)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(.black)
        .onAppear {
            if !module.isRunning { module.start() }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            // POI Logo
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(.cyan)
                Text("JARVIS INTELLIGENCE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("v2")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.6))
            }

            Spacer()

            // Feed count
            Text("\(module.activeFeedCount) FEED\(module.activeFeedCount == 1 ? "" : "S") ACTIVE")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.7))

            Divider().frame(height: 12).background(.white.opacity(0.15))

            // View mode toggle
            HStack(spacing: 0) {
                ForEach([("square.grid.2x2", DisplayMode.grid),
                         ("rectangle.portrait", DisplayMode.focus),
                         ("film", DisplayMode.cinematic)], id: \.0) { icon, mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { displayMode = mode }
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundStyle(displayMode == mode ? .cyan : .white.opacity(0.4))
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showEventLog.toggle() }
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(showEventLog ? .cyan : .white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.cyan.opacity(0.15)).frame(height: 1)
        }
    }

    // MARK: - Grid View (multi-camera)

    private var gridView: some View {
        let feeds = module.activeFeedDescriptors
        let columns = feeds.count <= 1 ? 1 : feeds.count <= 4 ? 2 : 3

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns),
            spacing: 4
        ) {
            ForEach(feeds) { feed in
                CameraCell(
                    feed: feed,
                    module: module,
                    isSelected: selectedFeedID == feed.id,
                    onTap: {
                        selectedFeedID = feed.id
                        withAnimation(.easeInOut(duration: 0.2)) { displayMode = .focus }
                    }
                )
            }
            // Empty slots to fill grid
            if feeds.isEmpty {
                noFeedPlaceholder
            }
        }
        .padding(4)
    }

    // MARK: - Focus View (single camera)

    private var focusView: some View {
        let feedID = selectedFeedID ?? module.activeFeedDescriptors.first?.id
        return Group {
            if let id = feedID, let feed = module.activeFeedDescriptors.first(where: { $0.id == id }) {
                FocusCameraView(feed: feed, module: module)
            } else {
                noFeedPlaceholder
            }
        }
    }

    // MARK: - Cinematic View (dramatic single feed)

    private var cinematicView: some View {
        let feedID = selectedFeedID ?? module.activeFeedDescriptors.first?.id
        return Group {
            if let id = feedID,
               let feed = module.activeFeedDescriptors.first(where: { $0.id == id }) {
                CinematicCameraView(feed: feed, module: module)
            } else {
                noFeedPlaceholder
            }
        }
    }

    // MARK: - Placeholder

    private var noFeedPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.2))
            Text("NO CAMERAS CONFIGURED")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
            Text("Say \"show surveillance\" to activate\nor configure cameras in Settings")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Camera Cell (grid item)

private struct CameraCell: View {
    let feed: CameraFeedDescriptor
    let module: VisionModule
    let isSelected: Bool
    let onTap: () -> Void

    private var targets: [TrackedTarget] { module.targets(for: feed.id) }
    private var latestFrame: CGImage? { module.latestFrame(for: feed.id) }
    private var threatLevel: ThreatLevel { module.threatClassifier.sceneThreatLevel }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Camera frame
                if let img = latestFrame {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    Color(white: 0.08)
                    VStack {
                        Image(systemName: "camera.fill")
                            .foregroundStyle(.white.opacity(0.2))
                        Text("CONNECTING…")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }

                // Visual overlays
                ZStack {
                    if VisionSettings.shared.showGrid {
                        GridOverlay(columns: 6, rows: 4)
                    }
                    if VisionSettings.shared.showScanlines {
                        ScanlineOverlay()
                    }

                    // Bounding boxes
                    ForEach(targets) { target in
                        TargetBracketView(target: target, frameSize: geo.size)
                        if VisionSettings.shared.showVelocityVectors {
                            VelocityVectorView(target: target, frameSize: geo.size)
                        }
                    }
                }

                // Timestamp + camera name
                VStack {
                    HUDTimestampView(cameraName: feed.name)
                    Spacer()
                    // Target count badge
                    if !targets.isEmpty {
                        HStack {
                            Spacer()
                            Text("\(targets.filter { !$0.isGhost }.count)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(threatLevel.color)
                        }
                        .padding(6)
                    }
                }
            }
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isSelected ? Color.cyan : Color.white.opacity(0.1), lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .aspectRatio(16/9, contentMode: .fit)
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Focus Camera View (single full-size)

private struct FocusCameraView: View {
    let feed: CameraFeedDescriptor
    let module: VisionModule

    private var targets: [TrackedTarget] { module.targets(for: feed.id) }
    private var latestFrame: CGImage? { module.latestFrame(for: feed.id) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background frame
                if let img = latestFrame {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color(white: 0.06)
                }

                // Overlays
                ZStack {
                    if VisionSettings.shared.showGrid {
                        GridOverlay(columns: 10, rows: 7)
                    }
                    if VisionSettings.shared.showScanlines {
                        ScanlineOverlay(spacing: 3, opacity: 0.04)
                    }
                    VHSNoiseOverlay(intensity: 0.025)

                    ForEach(targets) { target in
                        TargetBracketView(target: target, frameSize: geo.size)
                        if VisionSettings.shared.showVelocityVectors {
                            VelocityVectorView(target: target, frameSize: geo.size)
                        }
                    }
                }

                // HUD chrome
                VStack {
                    HUDTimestampView(cameraName: feed.name)
                    Spacer()
                    // Bottom info strip
                    bottomInfoStrip
                }
            }
            .clipped()
        }
    }

    private var bottomInfoStrip: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.location.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.8))
                Text("\(targets.filter { !$0.isGhost }.count) ACTIVE TARGET\(targets.filter { !$0.isGhost }.count == 1 ? "" : "S")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if let threat = targets.filter({ !$0.isGhost }).max(by: { $0.threatLevel < $1.threatLevel }) {
                Text(threat.threatLevel.label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(threat.threatLevel.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(threat.threatLevel.color, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.7))
    }
}

// MARK: - Cinematic Camera View

private struct CinematicCameraView: View {
    let feed: CameraFeedDescriptor
    let module: VisionModule
    @State private var highlightedTargetID: UUID? = nil

    private var targets: [TrackedTarget] { module.targets(for: feed.id) }
    private var latestFrame: CGImage? { module.latestFrame(for: feed.id) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let img = latestFrame {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        // Subtle vignette
                        .overlay(
                            RadialGradient(
                                colors: [.clear, .black.opacity(0.7)],
                                center: .center,
                                startRadius: geo.size.width * 0.3,
                                endRadius: geo.size.width * 0.9
                            )
                        )
                } else {
                    Color.black
                }

                // Full-resolution overlays
                ScanlineOverlay(spacing: 4, opacity: 0.06)
                VHSNoiseOverlay(intensity: 0.03)

                ForEach(targets) { target in
                    TargetBracketView(target: target, frameSize: geo.size)
                }

                // Target lock for highest-threat target
                if let topTarget = targets.filter({ !$0.isGhost }).max(by: { $0.threatLevel < $1.threatLevel }),
                   topTarget.threatLevel > .normal {
                    let cx = topTarget.bounds.midX * geo.size.width
                    let cy = topTarget.bounds.midY * geo.size.height
                    TargetLockView(color: topTarget.threatLevel.color)
                        .position(x: cx, y: cy)
                }

                // Cinematic overlays
                VStack {
                    HUDTimestampView(cameraName: feed.name)
                    Spacer()
                    cinematicBottomBar
                }
            }
        }
    }

    private var cinematicBottomBar: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(feed.name.uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(feed.location.uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                let topThreat = targets.filter { !$0.isGhost }.max(by: { $0.threatLevel < $1.threatLevel })
                Text(topThreat?.threatLevel.systemLabel ?? "MONITORING")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(topThreat?.threatLevel.color ?? .green)
                Text("\(targets.filter { !$0.isGhost }.count) TARGET\(targets.filter { !$0.isGhost }.count == 1 ? "" : "S") DETECTED")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        )
    }
}

// MARK: - Event Log Panel

private struct EventLogPanel: View {
    let memory: SceneMemoryStore
    @State private var events: [SceneEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("EVENT LOG")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                Spacer()
                Text("\(events.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.cyan.opacity(0.2)).frame(height: 1)
            }

            // Event list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        EventRowView(event: event)
                    }
                }
            }
            .background(Color(white: 0.04))
        }
        .overlay(
            Rectangle()
                .fill(.cyan.opacity(0.12))
                .frame(width: 1),
            alignment: .leading
        )
        .onAppear { events = memory.events }
        .onChange(of: memory.events.count) { events = memory.events }
    }
}

private struct EventRowView: View {
    let event: SceneEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Circle()
                    .fill(event.primaryThreat.color)
                    .frame(width: 6, height: 6)
            }
            Text(event.description)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
            Text(event.cameraName.uppercased())
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.05)).frame(height: 0.5)
        }
    }
}
