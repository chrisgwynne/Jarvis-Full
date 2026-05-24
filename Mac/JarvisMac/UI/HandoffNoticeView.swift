import SwiftUI

/// Shown when a cross-device handoff arrives with text or conversation content.
struct HandoffNoticeView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("From your other device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.plain)
                    .font(.caption)
            }
            Text(text)
                .font(.body)
                .lineLimit(4)
                .truncationMode(.tail)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 320)
    }
}
