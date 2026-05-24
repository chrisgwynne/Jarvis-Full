import Foundation

/// Polls Apple Mail every 3 minutes and emits ProactivitySignals for
/// emails that match VIP keywords in their subject lines.
///
/// Uses an in-memory set to dedup announced messageIDs within a session.
/// Skips if `engine.settings.emailEnabled` is false.
@MainActor
final class EmailProactivityProvider: ProactivitySignalProvider {

    let source: SignalSource = .email

    private weak var engine: ProactivityEngine?
    private weak var appState: AppState?
    private var pollTask: Task<Void, Never>?

    /// Keywords whose presence in a subject triggers a VIP alert.
    private static let vipKeywords: [String] = [
        "urgent", "important", "action required", "asap",
        "follow up", "follow-up", "reminder", "deadline",
    ]

    /// MessageIDs announced this session — prevents repeated alerts.
    private var announcedIDs: Set<String> = []

    init(engine: ProactivityEngine, appState: AppState) {
        self.engine   = engine
        self.appState = appState
    }

    func start() {
        pollTask = Task {
            while !Task.isCancelled {
                await pollNow()
                try? await Task.sleep(for: .seconds(180)) // every 3 min
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollNow() async {
        guard let engine = engine, engine.settings.emailEnabled else { return }

        guard let unread = try? await AppleMailService.unreadEmails(limit: 20) else { return }

        for msg in unread {
            let key = msg.messageID.isEmpty ? "\(msg.subject)-\(msg.sender)" : msg.messageID
            guard !announcedIDs.contains(key) else { continue }

            let subjectLower = msg.subject.lowercased()
            let matchedKeyword = Self.vipKeywords.first {
                subjectLower.contains($0)
            }
            guard let keyword = matchedKeyword else { continue }

            announcedIDs.insert(key)

            let priority: SignalPriority = keyword == "urgent" || keyword == "asap"
                ? .high : .normal
            let spoken = "Email from \(msg.senderName): \(msg.subject)."
            let signal = ProactivitySignal(
                source: .email,
                title: msg.subject,
                body: "From: \(msg.senderName)",
                category: "email_vip",
                priority: priority,
                dedupeKey: "email.vip.\(key)",
                spokenText: spoken,
                requiresAttention: priority == .high
            )
            ProactivityOrchestrator.shared.providerPublish(signal: signal)
        }
    }
}
