import SwiftUI

// MARK: - ChatOverlayView

/// Main chat overlay — scrollable message history + typed input bar.
/// Accessible via "show chat" / "open chat". Routes typed input through
/// the same JarvisController pipeline as voice commands.
struct ChatOverlayView: View {
    let state: AppState
    let controller: JarvisController

    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            messageList
            processingBanner
            ChatInputBar(text: $inputText, processing: state.chatInputProcessing) {
                submitInput()
            }
        }
    }

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if state.chatMessages.isEmpty && !isLive {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else {
                        ForEach(state.chatMessages) { msg in
                            ChatMessageBubble(message: msg)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }

                    // Live partial transcript — shown while user is speaking
                    if isLive {
                        liveTranscriptBubble
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Invisible anchor for scrolling
                    Color.clear.frame(height: 1).id("chatBottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.18), value: state.chatMessages.count)
            }
            .onChange(of: state.chatMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chatBottom") }
            }
            .onChange(of: isLive) { _, live in
                if live { withAnimation { proxy.scrollTo("chatBottom") } }
            }
            .onAppear {
                proxy.scrollTo("chatBottom")
            }
        }
    }

    // MARK: Live typing indicator

    private var isLive: Bool {
        (state.phase == .listening || state.phase == .conversationalListening)
        && !state.partialTranscript.isEmpty
    }

    private var liveTranscriptBubble: some View {
        HStack {
            Spacer(minLength: 56)
            HStack(spacing: 8) {
                Text(state.partialTranscript)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.55))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 6, height: 6)
                    .opacity(0.75)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.cyan.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.cyan.opacity(0.20),
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Processing banner

    @ViewBuilder
    private var processingBanner: some View {
        if state.chatInputProcessing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).tint(.cyan)
                Text("Processing…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.20))
            .transition(.opacity)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title2).foregroundStyle(.secondary)
            Text("No conversation yet")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text("Speak to Jarvis or type a command below.\nTry \"show memory\", \"open Safari\", \"remember this\".")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Send

    private func submitInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task { await controller.sendTypedMessage(text) }
    }
}

// MARK: - ChatMessageBubble

struct ChatMessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 56) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(isUser ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(bubbleBG)

                Text(message.timestamp, style: .time)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if !isUser { Spacer(minLength: 56) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var bubbleBG: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isUser
                  ? Color.cyan.opacity(0.14)
                  : Color.white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isUser
                                  ? Color.cyan.opacity(0.28)
                                  : Color.white.opacity(0.09))
            )
    }
}

// MARK: - ChatInputBar

struct ChatInputBar: View {
    @Binding var text: String
    let processing: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField("Ask Jarvis…", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onSubmit { sendIfValid() }
                .disabled(processing)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(isFocused
                                              ? Color.cyan.opacity(0.40)
                                              : Color.white.opacity(0.10))
                        )
                )
                .animation(.easeInOut(duration: 0.15), value: isFocused)

            sendButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.28))
        .overlay(Divider().opacity(0.12), alignment: .top)
        .onAppear { isFocused = true }
    }

    private var sendButton: some View {
        Button(action: sendIfValid) {
            Group {
                if processing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.cyan)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(canSend ? .cyan : .secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    private var canSend: Bool {
        !processing && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func sendIfValid() {
        guard canSend else { return }
        onSend()
    }
}
