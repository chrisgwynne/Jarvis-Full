import SwiftUI

/// Collapsible debug overlay. Toggle with ⌘D or the UI button.
/// Shows live internal state so you can diagnose audio/STT/phase issues.
struct DebugHUDView: View {
    let state: AppState
    let controller: JarvisController
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            if expanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.88))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.green.opacity(0.4)))
        )
        .font(.system(size: 10, design: .monospaced))
        .frame(width: 256)
        .animation(.spring(duration: 0.2), value: expanded)
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text("DEBUG HUD")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)
            Spacer()
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            Button {
                withAnimation { state.debugHUDVisible = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.green.opacity(0.07))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            // ── STARTUP ──────────────────────────────────────────────────────
            section("STARTUP")
            row("phase",   state.startupPhase,
                state.startupReady ? .green : .orange)
            row("ready",   flag(state.startupReady),
                state.startupReady ? .green : .orange)
            row("gated",   flag(state.startupProactivityGated),
                state.startupProactivityGated ? .orange : .green)
            if state.startupGracePeriodRemaining > 0 {
                row("grace",
                    String(format: "%.0fs", state.startupGracePeriodRemaining),
                    .yellow)
            }
            if let first = state.firstProactiveAlertAt {
                let remaining = first.timeIntervalSinceNow
                if remaining > 0 {
                    row("1st alert in",
                        String(format: "%.0fs", remaining), .cyan)
                } else {
                    row("1st alert", "unlocked", .green)
                }
            }
            row("q.signals", state.startupQueuedSignalCount > 0
                    ? "\(state.startupQueuedSignalCount)" : "—",
                state.startupQueuedSignalCount > 0 ? .cyan : .secondary)
            row("discarded", state.startupDiscardedSignalCount > 0
                    ? "\(state.startupDiscardedSignalCount)" : "—",
                state.startupDiscardedSignalCount > 0 ? .orange : .secondary)

            section("ASSISTANT")
            row("phase",      state.phase.rawValue,          phaseColor)
            row("orb",        orbColorName,                  phaseColor)
            row("mode",       listeningModeLabel,            listeningModeColor)
            row("desired",    state.listeningDesiredMode.displayName, .blue)
            row("actual",     state.listeningActualState.displayName, listeningActualColor)
            row("listen on",  flag(state.listeningEnabled),  state.listeningEnabled ? .green : .orange)
            row("listening",  flag(state.isListening),        state.isListening  ? .green  : .secondary)
            row("speaking",   flag(state.isSpeaking),         state.isSpeaking   ? .orange : .secondary)
            row("wake armed", flag(state.isWakeArmed),        state.isWakeArmed  ? .blue   : .secondary)
            row("watchdog",   state.wakeWatchdogRestarts > 0 ? "\(state.wakeWatchdogRestarts)" : "0",
                state.wakeWatchdogRestarts > 0 ? .orange : .secondary)
            if let at = state.lastWatchdogRecoveryAt {
                row("wd recovery", relativeTime(at), .orange)
            }
            if !state.lastOverlayEvent.isEmpty {
                row("overlay ev", state.lastOverlayEvent, .teal)
            }

            section("AUDIO — STT")
            row("stt engine", state.speechEngine.displayName, .cyan)
            row("offline",    flag(state.isOffline),          state.isOffline    ? .green  : .secondary)
            row("mic",        state.activeMicrophoneName ?? "none", .cyan)

            section("AUDIO — TTS")
            row("tts engine", state.ttsEngine.displayName, .teal)
            row("voice",      state.ttsVoiceName.isEmpty  ? "auto" : state.ttsVoiceName, .teal)
            row("lang",       state.ttsVoiceLanguage.isEmpty ? "—" : state.ttsVoiceLanguage, .teal)
            if let e = state.ttsLastError { row("tts err", e, .red) }
            row("mic status", state.microphoneStatus.label,   state.microphoneStatus.isHealthy ? .green : .orange)
            row("stt status", state.speechStatus.label,       state.speechStatus.isHealthy ? .green : .orange)
            row("barge trig", state.lastBargeInReason.map { _ in "yes" } ?? "no", .secondary)
            row("listen why", state.listeningReason.isEmpty ? "—" : state.listeningReason, .cyan)
            row("stop why",   state.lastStopReason.isEmpty  ? "—" : state.lastStopReason,  .orange)
            row("session",    state.listeningSessionShortID.isEmpty ? "—" : state.listeningSessionShortID, .cyan)
            row("min listen", state.listeningMinRemainingMs > 0 ? "\(state.listeningMinRemainingMs)ms" : "—",
                state.listeningMinRemainingMs > 0 ? .green : .secondary)
            row("audio buf",  flag(state.listeningSawAudioBuffer),
                state.listeningSawAudioBuffer ? .green : .orange)
            row("restarts",   state.listeningRestartCount > 0 ? "\(state.listeningRestartCount)" : "—",
                state.listeningRestartCount > 0 ? .yellow : .secondary)

            // Lifecycle event log (last 5)
            if !state.listeningEventLog.isEmpty {
                section("LIFECYCLE LOG")
                ForEach(state.listeningEventLog.suffix(5).reversed()) { ev in
                    HStack(alignment: .top) {
                        Text(ev.displayTimestamp)
                            .foregroundStyle(.secondary)
                            .frame(width: 82, alignment: .leading)
                        Text("\(ev.fromState)→\(ev.toState)")
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .top) {
                        Text("")
                            .frame(width: 82, alignment: .leading)
                        Text(ev.reason)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }

            section("TRANSCRIPT")
            row("partial",    trunc(state.partialTranscript),    .primary)
            row("final",      trunc(state.lastFinalTranscript),  .mint)
            row("normalised", trunc(state.lastNormalizedText),   .cyan)
            row("p.action",   state.parsedAction.isEmpty ? "—" : state.parsedAction, .purple)
            row("p.target",   state.parsedTarget.isEmpty ? "—" : state.parsedTarget, .purple)
            if state.parsedConfidence > 0 {
                row("p.conf",  String(format: "%.0f%%", state.parsedConfidence * 100),
                    state.parsedConfidence >= 0.8 ? .green
                    : state.parsedConfidence >= 0.5 ? .yellow : .orange)
            }
            if let intent = state.lastIntent {
                row("intent", trunc(String(describing: intent)), .purple)
            }
            row("spoken",     trunc(state.lastSpoken),          .yellow)

            if let cmd = state.phraseMatchedCommand {
                section("PHRASE MATCH")
                row("command",  cmd,                               .cyan)
                if let phrase = state.phraseMatchedPhrase {
                    row("phrase", trunc(phrase),                   .cyan)
                }
                if let mt = state.phraseMatchType {
                    row("type",   mt.rawValue,                     .teal)
                }
                if let conf = state.phraseMatchConfidence {
                    row("conf",   String(format: "%.0f%%", conf * 100),
                        conf >= 0.95 ? .green : conf >= 0.80 ? .yellow : .orange)
                }
            } else if !state.phraseNearMisses.isEmpty {
                section("PHRASE NEAR MISSES")
                ForEach(Array(state.phraseNearMisses.prefix(3).enumerated()),
                        id: \.offset) { _, miss in
                    row(miss.commandId,
                        String(format: "%.0f%%", miss.confidence * 100),
                        .orange)
                }
            }

            if state.webOverlayBridgeMessages > 0
               || state.webOverlayLastError != nil {
                section("WEB OVERLAYS")
                row("bridge msg",
                    state.webOverlayBridgeMessages > 0
                        ? "\(state.webOverlayBridgeMessages)" : "—",
                    state.webOverlayBridgeMessages > 0 ? .cyan : .secondary)
                row("last msg",
                    state.webOverlayLastMessage.isEmpty ? "—" : state.webOverlayLastMessage,
                    .teal)
                if let err = state.webOverlayLastError {
                    row("bridge err", trunc(err, 26), .red)
                }
            }

            // Proactivity diagnostics
            if !state.proactivityLastSignalTitle.isEmpty || controller.proactivity.isPaused {
                section("PROACTIVITY")
                row("pending",  "\(controller.proactivity.pendingCount)",
                    controller.proactivity.pendingCount > 0 ? .orange : .secondary)
                row("paused",   flag(controller.proactivity.isPaused),
                    controller.proactivity.isPaused ? .yellow : .secondary)
                if !state.proactivityLastSignalTitle.isEmpty {
                    row("last sig", trunc(state.proactivityLastSignalTitle, 22), .cyan)
                    row("decision", state.proactivityLastDecision, .teal)
                    row("reason",   state.proactivityLastReason,   .secondary)
                }
            }

            // Conversational continuity diagnostics
            if state.awaitingResponseActive || !state.pendingQuestion.isEmpty {
                section("CONVERSATION")
                row("state",    state.awaitingResponseActive ? "awaiting reply" : "armed",
                    state.awaitingResponseActive ? .cyan : .mint)
                if !state.pendingQuestion.isEmpty {
                    row("question", trunc(state.pendingQuestion, 26), .cyan)
                    row("type",     state.awaitingResponseType, .secondary)
                }
                if !state.lastFollowUpResolution.isEmpty {
                    row("resolved", state.lastFollowUpResolution, .teal)
                }
                if !state.lastFollowUpTranscript.isEmpty {
                    row("reply",    trunc(state.lastFollowUpTranscript, 22), .secondary)
                }
            }

            // Vision diagnostics — only shown when LLM vision was used or errored
            if !state.lastVisionProvider.isEmpty {
                section("VISION")
                row("provider",  state.lastVisionProvider, .cyan)
                row("capture",   state.lastVisionCaptureMs > 0  ? "\(state.lastVisionCaptureMs)ms"  : "—", .yellow)
                row("encode",    state.lastVisionEncodeMs  > 0  ? "\(state.lastVisionEncodeMs)ms"   : "—", .yellow)
                row("request",   state.lastVisionRequestMs > 0  ? "\(state.lastVisionRequestMs)ms"  : "—", .yellow)
                row("total",     state.lastVisionTotalMs   > 0  ? "\(state.lastVisionTotalMs)ms"    : "—", .orange)
                row("img size",  state.lastVisionImageSizeKB > 0 ? "\(state.lastVisionImageSizeKB)KB" : "—", .teal)
                if let err = state.lastVisionError {
                    row("err", trunc(err, 28), .red)
                }
            }

            if let err = state.lastError {
                section("ERROR")
                row("msg",    trunc(err, 32),                   .red)
            }

            section("LATENCY avg ms")
            ForEach(latencyRows, id: \.0) { label, val in
                row(label, val, .yellow)
            }
        }
        .padding(8)
        .foregroundStyle(.primary)
    }

    // MARK: - Helpers

    private var orbColorName: String {
        switch state.phase {
        case .idle:                    return "gray"
        case .wakeListening:           return "blue"
        case .listening:               return "cyan"
        case .conversationalListening: return "green"
        case .awaitingResponse:        return "green"
        case .thinking:                return "purple"
        case .speaking:                return "orange"
        case .bargedIn:                return "orange"
        case .muted:                   return "gray"
        case .error:                   return "red"
        }
    }

    private var listeningActualColor: Color {
        switch state.listeningActualState {
        case .unavailable:       return .red
        case .idleListening:     return .secondary
        case .wakeWordListening: return .blue
        case .activelyListening: return .cyan
        case .processing:        return .purple
        case .speaking:          return .orange
        case .temporarilyPaused: return .yellow
        case .recovering:        return .orange
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let sec = Int(-date.timeIntervalSinceNow)
        if sec < 60 { return "\(sec)s ago" }
        return "\(sec / 60)m ago"
    }

    private var phaseColor: Color {
        switch state.phase {
        case .idle:                    return .secondary
        case .wakeListening:           return .blue
        case .listening:               return .cyan
        case .conversationalListening: return .green
        case .awaitingResponse:        return .green
        case .thinking:                return .purple
        case .speaking:                return .orange
        case .bargedIn:                return .orange
        case .muted:                   return .gray
        case .error:                   return .red
        }
    }

    private var listeningModeLabel: String {
        if !state.listeningEnabled { return "muted" }
        switch state.phase {
        case .wakeListening, .idle:    return "passive wake"
        case .listening:               return "active command"
        case .conversationalListening: return "conversational"
        case .awaitingResponse:        return "awaiting reply"
        case .thinking:                return "processing"
        case .speaking:                return "speaking"
        case .bargedIn:                return "interrupted"
        case .muted:                   return "muted"
        case .error:                   return "error"
        }
    }

    private var listeningModeColor: Color {
        if !state.listeningEnabled { return .orange }
        switch state.phase {
        case .wakeListening, .idle:    return .blue
        case .listening:               return .cyan
        case .conversationalListening: return .green
        case .awaitingResponse:        return .green
        case .thinking:                return .purple
        case .speaking:                return .orange
        case .bargedIn:                return .orange
        case .muted:                   return .gray
        case .error:                   return .red
        }
    }

    private var latencyRows: [(String, String)] {
        let m = state.latencyMillis
        let keys: [(String, String)] = [
            ("stt_first_partial", "stt partial"),
            ("stt_final",         "stt final"),
            ("intent_route",      "intent"),
            ("action_execute",    "action"),
            ("tts_start",         "tts start"),
            ("tts_complete",      "tts total"),
        ]
        return keys.compactMap { k, l in m[k].map { (l, "\(Int($0))") } }
    }

    private func flag(_ b: Bool) -> String { b ? "yes" : "no" }

    private func trunc(_ s: String, _ n: Int = 26) -> String {
        s.isEmpty ? "—" : String(s.prefix(n))
    }

    @ViewBuilder
    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(.green.opacity(0.55))
            .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .foregroundStyle(color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
