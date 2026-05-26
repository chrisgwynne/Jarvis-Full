import Foundation
import AppKit
import os

// MARK: - AmbientContextEngine

/// Passive awareness layer — Jarvis always knows what the user is doing
/// without requiring explicit commands.
///
/// Responsibilities:
/// - Track frontmost app via ActiveAppMonitor (no screenshots)
/// - Optionally sample screen at low frequency when watch mode is off
/// - Produce ScreenContextSummary from existing ScreenAwarenessService
/// - Detect errors/dialogs on screen and emit events to SystemBus
/// - Manage watch mode (boost sampling on "watch this")
/// - Enforce PrivacyFilter (block sensitive apps from capture)
/// - Feed ContextEngine.lastScreenSummary for LLM context injection
///
/// Performance contract:
/// - Passive mode: app tracking only, no screenshots unless enabled
/// - Normal mode: one screenshot per samplingIntervalSeconds (default 30 s)
/// - Watch mode: one screenshot per watchIntervalSeconds (default 8 s)
/// - All OCR and capture is discarded after summarisation
@MainActor
final class AmbientContextEngine {

    // MARK: - Public state

    private(set) var context = AmbientContext()
    private(set) var isEnabled: Bool = true

    // MARK: - Dependencies (injected after init)

    weak var screenAwareness: ScreenAwarenessService?
    weak var contextEngine: ContextEngine?

    // MARK: - Sub-monitors

    let appMonitor = ActiveAppMonitor()
    let windowMonitor = WindowContextMonitor(pollIntervalSeconds: 5.0)

    // MARK: - Privacy

    var privacyFilter = PrivacyFilter()

    // MARK: - Sampling config

    var samplingEnabled: Bool = true
    var samplingIntervalSeconds: TimeInterval = 30.0
    var watchIntervalSeconds: TimeInterval = 8.0
    var watchModeDuration: TimeInterval = 300.0  // default 5-minute watch window

    // MARK: - Private

    private var samplingTask: Task<Void, Never>?
    private var watchExpiryTask: Task<Void, Never>?
    private var busTokens: [SystemBus.SubscriptionToken] = []

    // P0 concurrency guards — prevents multiple simultaneous ScreenCaptureKit sessions
    // which cause WindowServer resource exhaustion and can crash the system.
    private var isCapturingNow = false
    private var lastOpportunisticAt: Date = .distantPast
    private var lastContextPublishAt: Date = .distantPast
    private static let minOpportunisticInterval: TimeInterval = 5.0   // max 1 opportunistic capture per 5s
    private static let minContextPublishInterval: TimeInterval = 3.0  // max 1 ScreenContextUpdated event per 3s

    // MARK: - Init

    init() {
        wireAppMonitor()
    }

    // MARK: - Lifecycle

    func start() {
        guard isEnabled else { return }
        windowMonitor.start()
        startSamplingLoop()
        Log.vision.info("[AmbientContext] started")
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        watchExpiryTask?.cancel()
        watchExpiryTask = nil
        windowMonitor.stop()
        busTokens.forEach { SystemBus.shared.unsubscribe($0) }
        busTokens.removeAll()
        Log.vision.info("[AmbientContext] stopped")
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        context.isEnabled = enabled
        if enabled { start() } else { stop() }
    }

    // MARK: - Watch mode

    /// Activate watch mode: increases sampling frequency for `duration` seconds.
    func activateWatchMode(duration: TimeInterval? = nil, targetApp: String? = nil) {
        let dur = duration ?? watchModeDuration
        let expiry = Date(timeIntervalSinceNow: dur)
        context.watchMode = .active(
            startedAt: Date(),
            expiresAt: expiry,
            targetApp: targetApp ?? context.activeApp.name.nonEmpty
        )
        scheduleWatchExpiry(at: expiry)
        restartSamplingLoop()
        Log.vision.info("[AmbientContext] watch mode ON — \(Int(dur))s, app=\(targetApp ?? "any")")
    }

    func deactivateWatchMode() {
        context.watchMode = .inactive
        watchExpiryTask?.cancel()
        watchExpiryTask = nil
        restartSamplingLoop()
        Log.vision.info("[AmbientContext] watch mode OFF")
    }

    // MARK: - On-demand snapshot

    /// Force an immediate screen analysis (e.g., on voice command "summarise screen").
    /// Waits for any in-progress capture to finish first (max 3 s), then runs.
    @discardableResult
    func forceSnapshot() async -> ScreenContextSummary {
        var waited = 0
        while isCapturingNow && waited < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            waited += 1
        }
        return await runScreenCapture(force: true)
    }

    // MARK: - App monitor wiring

    private func wireAppMonitor() {
        appMonitor.onFocusChanged = { [weak self] newApp, prevApp in
            guard let self else { return }
            self.handleAppFocusChanged(new: newApp, previous: prevApp)
        }
        windowMonitor.onWindowChanged = { [weak self] appName, title in
            guard let self else { return }
            self.handleWindowChanged(appName: appName, title: title)
        }
    }

    private func handleAppFocusChanged(new: ActiveApp, previous: ActiveApp) {
        // Update history (newest-first, cap at 10)
        var history = context.recentAppHistory
        if !context.activeApp.isEmpty { history.insert(context.activeApp, at: 0) }
        if history.count > 10 { history = Array(history.prefix(10)) }

        context.previousApp = previous
        context.activeApp = new
        context.lastAppChangeAt = Date()
        context.recentAppHistory = history

        // Feed ContextEngine
        contextEngine?.setActiveApp(new.name)

        // Privacy check — if new app is blocked, redact
        if privacyFilter.isBlocked(bundleID: new.bundleID, appName: new.name, windowTitle: new.windowTitle) {
            context.latestSummary = ScreenContextSummary(
                activeApp: new.name, bundleID: new.bundleID,
                windowTitle: new.windowTitle, detectedTask: "",
                visibleEntities: [], visibleErrors: [],
                ocrTextSummary: "", confidence: 0, isRedacted: true,
                timestamp: Date()
            )
            SystemBus.shared.publish(ContextRedactedEvent(appName: new.name, bundleID: new.bundleID))
            return
        }

        // On app change, trigger an opportunistic snapshot — but throttled.
        // Guard: skip if a capture is already running, or if we triggered one recently.
        // This prevents WindowServer overload when apps switch rapidly (e.g. during a
        // dock animation, mission control, or context menu flicker).
        if samplingEnabled {
            let now = Date()
            let elapsed = now.timeIntervalSince(lastOpportunisticAt)
            if !isCapturingNow && elapsed >= Self.minOpportunisticInterval {
                lastOpportunisticAt = now
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.runScreenCapture(force: false)
                }
            }
        }
    }

    private func handleWindowChanged(appName: String, title: String) {
        // Update window title in current ActiveApp
        if context.activeApp.name == appName {
            context.activeApp = ActiveApp(
                name: context.activeApp.name,
                bundleID: context.activeApp.bundleID,
                windowTitle: title,
                timestamp: Date()
            )
        }
    }

    // MARK: - Sampling loop

    private func startSamplingLoop() {
        guard samplingEnabled, samplingTask == nil else { return }
        let interval = context.watchMode.isActive ? watchIntervalSeconds : samplingIntervalSeconds
        // Use Task.detached at .utility priority so the sleep and screen-capture IPC
        // do not hold the @MainActor hostage. runScreenCapture is async and does its
        // heavy work (SCStreamConfiguration / OCR) without blocking the main thread —
        // it only hops back to @MainActor for the final @Observable state mutations.
        samplingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.runScreenCapture(force: false)
            }
        }
    }

    private func restartSamplingLoop() {
        samplingTask?.cancel()
        samplingTask = nil
        startSamplingLoop()
    }

    private func scheduleWatchExpiry(at date: Date) {
        watchExpiryTask?.cancel()
        let delay = max(1, date.timeIntervalSinceNow)
        watchExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.deactivateWatchMode()
        }
    }

    // MARK: - Screen capture + summary

    /// Internal capture entry point.
    /// - Parameter force: When true (forceSnapshot path) the method still respects
    ///   `isCapturingNow` — callers must wait for any in-progress capture first.
    @discardableResult
    private func runScreenCapture(force: Bool = false) async -> ScreenContextSummary {
        guard samplingEnabled else { return .empty }

        // P0 guard: prevent concurrent ScreenCaptureKit sessions.
        // forceSnapshot() waits for the previous capture to finish before calling us,
        // so we don't need a separate code path — the guard is always correct here.
        guard !isCapturingNow else {
            Log.vision.debug("[AmbientContext] capture skipped — already capturing")
            return .empty
        }
        isCapturingNow = true
        defer { isCapturingNow = false }

        let activeApp = appMonitor.current

        // Privacy gate
        if privacyFilter.isBlocked(
            bundleID: activeApp.bundleID,
            appName: activeApp.name,
            windowTitle: activeApp.windowTitle
        ) {
            let redacted = ScreenContextSummary(
                activeApp: activeApp.name,
                bundleID: activeApp.bundleID,
                windowTitle: activeApp.windowTitle,
                detectedTask: "", visibleEntities: [], visibleErrors: [],
                ocrTextSummary: "", confidence: 0, isRedacted: true,
                timestamp: Date()
            )
            context.latestSummary = redacted
            context.lastSummaryAt = Date()
            return redacted
        }

        guard let awareness = screenAwareness else {
            // No screen capture service wired — produce a lightweight summary from app info only
            let summary = buildLightweightSummary(app: activeApp)
            updateContext(summary)
            return summary
        }

        // Full capture + OCR path
        guard let screenSummary = try? await awareness.analyse() else {
            return .empty
        }

        let contextSummary = buildSummary(from: screenSummary, app: activeApp)
        updateContext(contextSummary)
        return contextSummary
    }

    private func buildLightweightSummary(app: ActiveApp) -> ScreenContextSummary {
        let task = detectedTask(appName: app.name, windowTitle: app.windowTitle, textLines: [])
        return ScreenContextSummary(
            activeApp: app.name,
            bundleID: app.bundleID,
            windowTitle: app.windowTitle,
            detectedTask: task,
            visibleEntities: [],
            visibleErrors: [],
            ocrTextSummary: "",
            confidence: 0.4,
            isRedacted: false,
            timestamp: Date()
        )
    }

    private func buildSummary(from screen: ScreenSummary, app: ActiveApp) -> ScreenContextSummary {
        let errors = extractErrors(from: screen.recognizedText, windowTitle: screen.windowTitle)
        let entities = extractEntities(from: screen.recognizedText, app: screen.appName)
        let task = detectedTask(
            appName: screen.appName.nonEmpty ?? app.name,
            windowTitle: screen.windowTitle,
            textLines: screen.recognizedText
        )
        let conf = screen.recognizedText.isEmpty ? 0.3 : 0.75

        return ScreenContextSummary(
            activeApp: screen.appName.nonEmpty ?? app.name,
            bundleID: app.bundleID,
            windowTitle: screen.windowTitle.nonEmpty ?? app.windowTitle,
            detectedTask: task,
            visibleEntities: entities,
            visibleErrors: errors,
            ocrTextSummary: screen.ocrSummary,
            confidence: conf,
            isRedacted: false,
            timestamp: screen.timestamp
        )
    }

    private func updateContext(_ summary: ScreenContextSummary) {
        let prev = context.latestSummary
        context.latestSummary = summary
        context.lastSummaryAt = Date()

        // Feed ContextEngine
        contextEngine?.recordScreen(summary.spokenDescription)

        // Throttle ScreenContextUpdatedEvent — max once per 3 s.
        // Rapid app switches that somehow bypass the opportunistic guard would otherwise
        // produce an event storm that floods EventStore and any catch-all subscribers.
        let now = Date()
        if now.timeIntervalSince(lastContextPublishAt) >= Self.minContextPublishInterval {
            lastContextPublishAt = now
            SystemBus.shared.publish(ScreenContextUpdatedEvent(summary: summary))
        }

        // Detect error transition: errors appeared that weren't there before.
        // Error events are NOT throttled — they should always get through.
        let newErrors = summary.visibleErrors.filter { !prev.visibleErrors.contains($0) }
        if !newErrors.isEmpty {
            SystemBus.shared.publish(ScreenErrorDetectedEvent(
                appName: summary.activeApp,
                errorText: newErrors.joined(separator: "; "),
                windowTitle: summary.windowTitle
            ))
        }
    }

    // MARK: - Text heuristics

    private func detectedTask(appName: String, windowTitle: String, textLines: [String]) -> String {
        let low = appName.lowercased()
        var parts: [String] = []

        if low.contains("xcode") || low.contains("cursor") || low.contains("vscode")
           || low.contains("visual studio") || low.contains("nova") || low.contains("sublime") {
            if let file = textLines.first(where: {
                $0.hasSuffix(".swift") || $0.hasSuffix(".ts") || $0.hasSuffix(".py")
                || $0.hasSuffix(".js") || $0.hasSuffix(".go") || $0.hasSuffix(".rs")
            }) {
                parts.append("Editing \(file.trimmingCharacters(in: .whitespaces)) in \(appName)")
            } else {
                parts.append("Coding in \(appName)\(windowTitle.isEmpty ? "" : " — \(windowTitle)")")
            }
        } else if low.contains("terminal") || low.contains("iterm") || low.contains("warp") {
            parts.append("Using terminal\(windowTitle.isEmpty ? "" : ": \(windowTitle)")")
        } else if low.contains("safari") || low.contains("chrome") || low.contains("firefox")
                  || low.contains("arc") || low.contains("brave") {
            let title = windowTitle.isEmpty ? "" : windowTitle
            parts.append(title.isEmpty ? "Browsing" : "Browsing: \(title)")
        } else if low.contains("slack") || low.contains("discord") || low.contains("teams") {
            parts.append("Messaging in \(appName)")
        } else if low.contains("mail") || low.contains("outlook") || low.contains("spark") {
            parts.append("Reading or writing email")
        } else if low.contains("figma") || low.contains("sketch") || low.contains("canva") {
            parts.append("Designing in \(appName)\(windowTitle.isEmpty ? "" : " — \(windowTitle)")")
        } else if !appName.isEmpty {
            parts.append("Using \(appName)\(windowTitle.isEmpty ? "" : " — \(windowTitle)")")
        }

        return parts.first ?? ""
    }

    private func extractErrors(from lines: [String], windowTitle: String) -> [String] {
        var errors: [String] = []
        let errorKeywords = ["error:", "failed:", "build failed", "exception", "crash",
                             "undefined", "cannot find", "does not conform", "missing",
                             "fatal error", "command failed", "exit code", "✗", "❌"]
        for line in lines {
            let low = line.lowercased()
            if errorKeywords.contains(where: { low.contains($0) }) {
                errors.append(line.trimmingCharacters(in: .whitespaces).prefix(120).description)
            }
        }
        // Window title can itself indicate an error dialog
        let titleLow = windowTitle.lowercased()
        if titleLow.contains("error") || titleLow.contains("failed") || titleLow.contains("alert") {
            errors.insert(windowTitle, at: 0)
        }
        return Array(errors.prefix(5))
    }

    private func extractEntities(from lines: [String], app: String) -> [String] {
        var entities: [String] = []
        let fileExtensions = [".swift", ".ts", ".tsx", ".py", ".go", ".rs", ".js", ".jsx",
                              ".kt", ".java", ".cpp", ".c", ".h", ".md", ".json", ".yaml"]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fileExtensions.contains(where: { trimmed.hasSuffix($0) }) && trimmed.count < 60 {
                entities.append(trimmed)
            }
            // GitHub PR / issue patterns
            if trimmed.hasPrefix("#") && trimmed.count < 30 { entities.append(trimmed) }
        }
        return Array(Set(entities).prefix(8))
    }
}

// MARK: - String helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
