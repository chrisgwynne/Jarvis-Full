import SwiftUI

/// Compact transient toast shown after simple voice commands.
/// Fades in/out via the parent's animation block — the parent should animate
/// on `state.toastMessage` changes.
struct CommandResultToast: View {
    let message: String?
    let icon: String

    var body: some View {
        if let message, !message.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.13))
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 14)
            .transition(JarvisMotion.toast)
        }
    }
}
