import SwiftUI

/// Shared visual chrome for every dashboard widget. All widgets compose
/// inside a `WidgetCard` so the grid stays visually consistent.
struct WidgetCard<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    var onClose: (() -> Void)?
    @ViewBuilder let content: () -> Content

    init(title: String,
         systemImage: String = "square.grid.2x2",
         accent: Color = .accentColor,
         onClose: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.onClose = onClose
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Close widget")
                }
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: accent.opacity(0.15), radius: 12, x: 0, y: 6)
    }
}
