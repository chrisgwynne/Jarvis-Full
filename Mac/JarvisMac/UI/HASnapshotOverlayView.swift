import SwiftUI
import AppKit

// MARK: - HASnapshotOverlayView

/// Displays a live (snapshot-refresh) view of a single Home Assistant camera.
///
/// HA camera proxy endpoints require `Authorization: Bearer <token>` — a header
/// that `AsyncImage` does not support. This view manually fetches each frame
/// using `URLSession`, converts the JPEG/PNG bytes to `NSImage`, and displays
/// the result. A background Task polls every `refreshInterval` seconds.
///
/// No unbounded WKWebView is used. The overlay deduplication rule in
/// `OverlayManager.open()` guarantees at most one `.haCamera` panel exists.
struct HASnapshotOverlayView: View {

    // MARK: - Config

    /// HA camera entity ID (e.g. `camera.front_door`).
    let entityID: String
    /// Human-readable camera name displayed in the footer.
    let friendlyName: String
    /// HA base URL (e.g. `http://192.168.1.20:8123`).
    let baseURL: String
    /// Long-lived access token for bearer auth.
    let token: String

    // MARK: - State

    @State private var imageData:    Data?   = nil
    @State private var isLoading:    Bool    = false
    @State private var errorMessage: String? = nil
    @State private var lastRefreshed: Date?  = nil
    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var refreshCount: Int = 0

    /// Seconds between automatic snapshot refreshes.
    private let refreshInterval: TimeInterval = 5

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            feedArea
            footer
        }
        .onAppear  { startAutoRefresh() }
        .onDisappear { stopAutoRefresh() }
        .onChange(of: entityID) {
            // Entity ID changed (e.g. user switched cameras) — restart loop.
            imageData = nil
            errorMessage = nil
            startAutoRefresh()
        }
    }

    // MARK: - Feed area

    private var feedArea: some View {
        ZStack {
            Color.black

            if let data = imageData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    .id(refreshCount)   // triggers cross-fade on each refresh
            } else if isLoading && imageData == nil {
                loadingPlaceholder
            } else if let err = errorMessage {
                errorPlaceholder(err)
            } else {
                ProgressView()
                    .colorScheme(.dark)
            }

            // Subtle spinner while refreshing an existing frame
            if isLoading, imageData != nil {
                ProgressView()
                    .scaleEffect(0.75)
                    .colorScheme(.dark)
                    .padding(7)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.6)
                .colorScheme(.dark)
            Text("Connecting to camera…")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func errorPlaceholder(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.30))
            Text(msg)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.50))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button("Retry") { Task { await fetchSnapshot() } }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(friendlyName.isEmpty ? entityID : friendlyName)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let lastRefreshed {
                Text(lastRefreshed, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Button {
                Task { await fetchSnapshot() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh snapshot")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Snapshot fetch

    @MainActor
    private func fetchSnapshot() async {
        guard !baseURL.isEmpty, !token.isEmpty else {
            errorMessage = "Home Assistant not configured"
            return
        }
        let urlString = "\(baseURL.trimmingCharacters(in: .init(charactersIn: "/")))/api/camera_proxy/\(entityID)"
        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid camera URL"
            return
        }

        isLoading = true
        defer { isLoading = false }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 401:
                    errorMessage = "Unauthorized — check your HA token"
                    return
                case 404:
                    errorMessage = "Camera unavailable: \(entityID)"
                    return
                case 200..<300:
                    break
                default:
                    errorMessage = "HTTP \(http.statusCode)"
                    return
                }
            }

            guard NSImage(data: data) != nil else {
                errorMessage = "Invalid image data received"
                return
            }

            // Success path
            imageData    = data
            lastRefreshed = Date()
            errorMessage = nil
            refreshCount += 1
            Log.app.debug("[ha-camera] Snapshot refreshed for \(entityID) (\(data.count) bytes)")

        } catch {
            // Don't replace a good frame with an error on transient failures
            if imageData == nil {
                errorMessage = error.localizedDescription
            }
            Log.app.warning("[ha-camera] Snapshot fetch failed for \(entityID): \(error.localizedDescription)")
        }
    }

    // MARK: - Auto-refresh

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTask = Task {
            await fetchSnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled else { return }
                await fetchSnapshot()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

// MARK: - HAAllCamerasOverlayView

/// Grid view showing snapshots for all discovered HA cameras.
/// Opens automatically when the user says "show all cameras".
struct HAAllCamerasOverlayView: View {

    let cameras: [HAEntity]
    let baseURL: String
    let token: String
    /// Called when the user taps a camera to expand it solo.
    var onSelectCamera: ((HAEntity) -> Void)?

    // 2-column grid
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        if cameras.isEmpty {
            ContentUnavailableView(
                "No Cameras Found",
                systemImage: "camera.slash",
                description: Text("Connect Home Assistant and sync entities to see cameras here.")
            )
            .padding()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(cameras) { camera in
                        cameraCard(camera)
                    }
                }
                .padding(16)
            }
        }
    }

    private func cameraCard(_ camera: HAEntity) -> some View {
        Button {
            onSelectCamera?(camera)
        } label: {
            VStack(spacing: 0) {
                HASnapshotOverlayView(
                    entityID:     camera.entityID,
                    friendlyName: camera.displayName,
                    baseURL:      baseURL,
                    token:        token
                )
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
