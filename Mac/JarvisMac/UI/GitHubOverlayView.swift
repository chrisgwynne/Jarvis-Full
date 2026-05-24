import SwiftUI
import AppKit

struct GitHubOverlayView: View {
    let apiClient: GitHubAPIClient

    @State private var notifications: [GHNotification] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.purple)
                Text("GitHub")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button {
                        Task { await loadNotifications() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let error = errorMessage {
                ContentUnavailableView(
                    "Couldn't Load Notifications",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .padding()
            } else if notifications.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "checkmark.seal.fill",
                    description: Text("You're all clear on GitHub.")
                )
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        let reviewRequests = notifications.filter { $0.reason == "review_requested" }
                        let assigned       = notifications.filter { $0.reason == "assign" }
                        let mentions       = notifications.filter { $0.reason == "mention" }
                        let other          = notifications.filter {
                            !["review_requested", "assign", "mention"].contains($0.reason)
                        }

                        if !reviewRequests.isEmpty {
                            sectionHeader("Review Requests", icon: "eye.circle.fill", count: reviewRequests.count, color: .orange)
                            ForEach(reviewRequests) { notif in
                                NotificationRow(notification: notif)
                            }
                        }
                        if !assigned.isEmpty {
                            sectionHeader("Assigned", icon: "person.fill.checkmark", count: assigned.count, color: .blue)
                            ForEach(assigned) { notif in
                                NotificationRow(notification: notif)
                            }
                        }
                        if !mentions.isEmpty {
                            sectionHeader("Mentions", icon: "at", count: mentions.count, color: .cyan)
                            ForEach(mentions) { notif in
                                NotificationRow(notification: notif)
                            }
                        }
                        if !other.isEmpty {
                            sectionHeader("Other", icon: "bell.fill", count: other.count, color: .secondary)
                            ForEach(other) { notif in
                                NotificationRow(notification: notif)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color.clear)
        .task { await loadNotifications() }
    }

    private func loadNotifications() async {
        isLoading = true
        errorMessage = nil
        do {
            notifications = try await apiClient.getNotifications()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func sectionHeader(_ title: String, icon: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

// MARK: - NotificationRow

private struct NotificationRow: View {
    let notification: GHNotification

    private var repoShort: String {
        notification.repository.full_name.components(separatedBy: "/").last
            ?? notification.repository.full_name
    }

    private var timeAgo: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: notification.updated_at)
            ?? ISO8601DateFormatter().date(from: notification.updated_at)
            ?? Date()
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    private var reasonBadgeColor: Color {
        switch notification.reason {
        case "review_requested": return .orange
        case "assign":           return .blue
        case "mention":          return .cyan
        case "comment":          return .green
        case "ci_activity":      return .secondary
        default:                 return .secondary
        }
    }

    private var reasonLabel: String {
        switch notification.reason {
        case "review_requested": return "review"
        case "assign":           return "assigned"
        case "mention":          return "mention"
        case "comment":          return "comment"
        case "ci_activity":      return "CI"
        default:                 return notification.reason
        }
    }

    private var notificationURL: URL? {
        // Convert GitHub API URL to web URL for browser open.
        // e.g. https://api.github.com/repos/owner/repo/pulls/123
        //   -> https://github.com/owner/repo/pull/123
        guard let apiURL = notification.subject.url else { return nil }
        let webURL = apiURL
            .replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
        return URL(string: webURL)
    }

    var body: some View {
        Button {
            if let url = notificationURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(repoShort)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(notification.subject.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(reasonLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(reasonBadgeColor.opacity(0.18)))
                            .foregroundStyle(reasonBadgeColor)

                        Text(timeAgo)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Image(systemName: "arrow.up.right.square")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }
}

#Preview {
    // Preview with a mock client (token won't work in preview)
    GitHubOverlayView(apiClient: GitHubAPIClient(token: "preview"))
        .frame(width: 360, height: 500)
}
