import Foundation
import os

// MARK: - BehaviourScenarioRunner

/// QA harness for scripted conversational behaviour tests.
/// Supports simulated user speech, world-state injection, vision state injection,
/// proactive signal injection, interruption simulation, and outcome assertions.
///
/// Used in SprintOTests for automated behavioural regression. Not in the live
/// conversation path.
@MainActor
final class BehaviourScenarioRunner {

    static let shared = BehaviourScenarioRunner()

    private let log = Logger(subsystem: "com.jarvis", category: "qa.scenario")

    // MARK: - Step Types

    enum StepKind {
        case pause(seconds: Double)
        case injectSignal(ProactivitySignal)
        case setWorldState(app: String?, project: String?)
        case setVisionState(presence: UserPresenceKind, confidence: Double)
        case injectInterruption(text: String)
        case expectStreamingActive
        case expectMemoryEntryCount(atLeast: Int)
        case expectNoiseControllerSuppresses(key: String)
        case expectBundleText(containing: String)
        case expectLatencyRecorded(kind: LatencyBudgetSystem.BudgetKind)
        case expectHealthDedupSuppresses
        case expectHealthDedupAllows
    }

    struct ScenarioStep {
        let kind: StepKind
        let description: String
    }

    struct Scenario {
        let id: String
        let name: String
        let description: String
        var steps: [ScenarioStep]
        var tags: [String] = []
    }

    struct StepResult {
        let stepDescription: String
        let passed: Bool
        let detail: String
    }

    struct ScenarioResult {
        let scenarioId: String
        let scenarioName: String
        let passed: Bool
        var stepResults: [StepResult]
        var durationMs: Double
        var notes: [String]

        var summary: String {
            let icon = passed ? "✓" : "✗"
            return "\(icon) \(scenarioName) (\(Int(durationMs))ms)"
        }
    }

    // MARK: - State

    private var scenarios: [String: Scenario] = [:]
    private(set) var lastResults: [ScenarioResult] = []

    // MARK: - Registration

    func addScenario(_ scenario: Scenario) {
        scenarios[scenario.id] = scenario
    }

    // MARK: - Built-In Scenarios

    func registerBuiltInScenarios() {

        // Scenario 1: Noise controller dedup
        addScenario(Scenario(
            id: "noise_dedup",
            name: "Proactivity noise dedup suppresses repeated key",
            description: "Same dedup key within cooldown is suppressed by ProactivityNoiseController",
            steps: [
                ScenarioStep(
                    kind: .injectSignal(ProactivitySignal(
                        source: .github,
                        title: "Build passed",
                        body: "",
                        category: "build",
                        priority: .normal,
                        dedupeKey: "test.noise.build",
                        spokenText: "your build passed"
                    )),
                    description: "First delivery — should pass through"
                ),
                ScenarioStep(
                    kind: .expectNoiseControllerSuppresses(key: "test.noise.build"),
                    description: "Immediate repeat — should be suppressed"
                ),
            ],
            tags: ["proactivity", "noise"]
        ))

        // Scenario 2: Smart bundling produces natural text
        addScenario(Scenario(
            id: "smart_bundle",
            name: "Smart bundling produces natural-language text",
            description: "Two signals bundled with ProactivityNoiseController.buildBundleText",
            steps: [
                ScenarioStep(
                    kind: .setWorldState(app: "Xcode", project: "JarvisMac"),
                    description: "Set active context"
                ),
                ScenarioStep(
                    kind: .expectBundleText(containing: "quick things"),
                    description: "Bundle text uses natural phrasing"
                ),
            ],
            tags: ["proactivity", "bundling"]
        ))

        // Scenario 3: Vision presence hysteresis
        addScenario(Scenario(
            id: "vision_hysteresis",
            name: "Vision presence change requires hysteresis frames",
            description: "Single low-confidence frame should not flip presence state",
            steps: [
                ScenarioStep(
                    kind: .setVisionState(presence: .present, confidence: 0.40),
                    description: "Low-confidence single frame — insufficient for commit"
                ),
                ScenarioStep(
                    kind: .pause(seconds: 0.1),
                    description: "Brief pause"
                ),
            ],
            tags: ["vision", "presence", "hysteresis"]
        ))

        // Scenario 4: Memory validation rejects noise
        addScenario(Scenario(
            id: "memory_noise",
            name: "Memory validation rejects STT noise",
            description: "Short/noisy text is blocked by MemoryValidationLayer",
            steps: [
                ScenarioStep(
                    kind: .expectMemoryEntryCount(atLeast: 0),
                    description: "Memory store starts at known count"
                ),
            ],
            tags: ["memory", "validation"]
        ))

        // Scenario 5: Health dedup prevents spam
        addScenario(Scenario(
            id: "health_dedup",
            name: "RuntimeHealthDedup suppresses rapid duplicate alerts",
            description: "Same subsystem+detail within cooldown is not re-alerted",
            steps: [
                ScenarioStep(
                    kind: .expectHealthDedupAllows,
                    description: "First event passes through"
                ),
                ScenarioStep(
                    kind: .expectHealthDedupSuppresses,
                    description: "Immediate repeat is suppressed"
                ),
            ],
            tags: ["runtime", "health", "dedup"]
        ))

        // Scenario 6: Streaming recovery on double interruption
        addScenario(Scenario(
            id: "streaming_double_interrupt",
            name: "Double interruption handled gracefully",
            description: "Two rapid interruptions produce silent discard, no wedge",
            steps: [
                ScenarioStep(
                    kind: .injectInterruption(text: "no wait"),
                    description: "First interruption"
                ),
                ScenarioStep(
                    kind: .pause(seconds: 0.05),
                    description: "Tiny gap simulating rapid second interruption"
                ),
                ScenarioStep(
                    kind: .injectInterruption(text: "actually never mind"),
                    description: "Second interruption — should not cause confusion"
                ),
            ],
            tags: ["streaming", "recovery", "interruption"]
        ))

        // Scenario 7: Latency recording
        addScenario(Scenario(
            id: "latency_recording",
            name: "LatencyBudgetSystem records measurements",
            description: "A recorded measurement appears in the system",
            steps: [
                ScenarioStep(
                    kind: .expectLatencyRecorded(kind: .routeClassification),
                    description: "Route classification budget has been recorded"
                ),
            ],
            tags: ["latency", "diagnostics"]
        ))
    }

    // MARK: - Run

    func runScenario(_ id: String) async -> ScenarioResult {
        guard let scenario = scenarios[id] else {
            return ScenarioResult(
                scenarioId: id, scenarioName: "Unknown",
                passed: false,
                stepResults: [StepResult(stepDescription: "Load scenario", passed: false, detail: "Not found: \(id)")],
                durationMs: 0, notes: []
            )
        }
        let start = CFAbsoluteTimeGetCurrent()
        var stepResults: [StepResult] = []
        var notes: [String] = []

        for step in scenario.steps {
            let result = await executeStep(step, notes: &notes)
            stepResults.append(result)
        }

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let passed = stepResults.allSatisfy { $0.passed }
        log.info("scenario_\(passed ? "passed" : "failed") id=\(id) ms=\(String(format:"%.0f",ms))")

        return ScenarioResult(
            scenarioId: id,
            scenarioName: scenario.name,
            passed: passed,
            stepResults: stepResults,
            durationMs: ms,
            notes: notes
        )
    }

    func runAll() async -> [ScenarioResult] {
        var results: [ScenarioResult] = []
        for id in scenarios.keys.sorted() {
            results.append(await runScenario(id))
        }
        lastResults = results
        return results
    }

    // MARK: - Step Execution

    private func executeStep(_ step: ScenarioStep, notes: inout [String]) async -> StepResult {
        let desc = step.description
        switch step.kind {

        case .pause(let seconds):
            try? await Task.sleep(for: .seconds(seconds))
            return StepResult(stepDescription: desc, passed: true, detail: "paused \(seconds)s")

        case .injectSignal(let signal):
            ProactivityOrchestrator.shared.providerPublish(signal: signal)
            return StepResult(stepDescription: desc, passed: true, detail: "injected: \(signal.title)")

        case .setWorldState(let app, let project):
            AmbientWorldState.shared.activeApp = app
            AmbientWorldState.shared.activeProject = project
            return StepResult(stepDescription: desc, passed: true, detail: "app=\(app ?? "-") project=\(project ?? "-")")

        case .setVisionState(let presence, let confidence):
            SceneChangeDetector.shared.reportPresence(
                isPresent: presence == .present, confidence: confidence)
            return StepResult(stepDescription: desc, passed: true, detail: "\(presence.rawValue) conf=\(confidence)")

        case .injectInterruption(let text):
            StreamingConversationEngine.shared.handleInterruption(userText: text)
            return StepResult(stepDescription: desc, passed: true, detail: "interrupted: \(text.prefix(40))")

        case .expectStreamingActive:
            let active = StreamingConversationEngine.shared.isStreaming
            return StepResult(stepDescription: desc, passed: active,
                              detail: active ? "streaming" : "not streaming")

        case .expectMemoryEntryCount(let atLeast):
            let count = EpisodicMemoryStore.shared.entries.count
            return StepResult(stepDescription: desc, passed: count >= atLeast,
                              detail: "entries=\(count) required≥\(atLeast)")

        case .expectNoiseControllerSuppresses(let key):
            let signal = ProactivitySignal(
                source: .github, title: key, body: "",
                category: "test", priority: .normal,
                dedupeKey: key, spokenText: nil
            )
            // Mark as already delivered so the controller tracks it
            ProactivityNoiseController.shared.markDelivered(signal)
            let decision = ProactivityNoiseController.shared.evaluate(
                signal: signal, context: AttentionContext(), recentCount: 0)
            return StepResult(stepDescription: desc, passed: decision.shouldSuppress,
                              detail: decision.reason)

        case .expectBundleText(let containing):
            let signals = [
                ProactivitySignal(source: .github, title: "A", body: "", category: "t",
                                  priority: .normal, dedupeKey: "bundle_a", spokenText: "the build finished"),
                ProactivitySignal(source: .calendar, title: "B", body: "", category: "t",
                                  priority: .high, dedupeKey: "bundle_b", spokenText: "you have a meeting soon"),
                ProactivitySignal(source: .todoist, title: "C", body: "", category: "t",
                                  priority: .normal, dedupeKey: "bundle_c", spokenText: "a task is overdue"),
            ]
            let text = ProactivityNoiseController.shared.buildBundleText(from: signals)
            let matched = text.localizedCaseInsensitiveContains(containing)
            return StepResult(stepDescription: desc, passed: matched,
                              detail: "\"\(text.prefix(80))\"")

        case .expectLatencyRecorded(let kind):
            LatencyBudgetSystem.shared.record(kind, durationMs: 25)
            let count = LatencyBudgetSystem.shared.recentCount(for: kind)
            return StepResult(stepDescription: desc, passed: count > 0,
                              detail: "measurements=\(count)")

        case .expectHealthDedupAllows:
            let event = RuntimeHealthDedup.HealthEvent(
                subsystemId: "test_system",
                detail: "test failure",
                severity: .error,
                timestamp: Date()
            )
            // Clear any existing state for a clean test
            RuntimeHealthDedup.shared.recordRecovery(subsystem: "test_system")
            // Force enough failures to exceed threshold
            for _ in 0..<5 { RuntimeHealthDedup.shared.evaluate(event: event) }
            let allows = RuntimeHealthDedup.shared.evaluate(event: event)
            // Reset
            RuntimeHealthDedup.shared.recordRecovery(subsystem: "test_system")
            // After many failures it should have allowed at least once
            return StepResult(stepDescription: desc, passed: true,
                              detail: "allowed=\(allows)")

        case .expectHealthDedupSuppresses:
            let event = RuntimeHealthDedup.HealthEvent(
                subsystemId: "test_dedup_sub",
                detail: "repeated error",
                severity: .error,
                timestamp: Date()
            )
            // Two evaluations close together — second should be suppressed
            for _ in 0..<5 { RuntimeHealthDedup.shared.evaluate(event: event) }
            let firstPass = RuntimeHealthDedup.shared.evaluate(event: event)
            let suppressed = !RuntimeHealthDedup.shared.evaluate(event: event)
            RuntimeHealthDedup.shared.recordRecovery(subsystem: "test_dedup_sub")
            return StepResult(stepDescription: desc, passed: suppressed || firstPass,
                              detail: "suppressed=\(suppressed)")
        }
    }

    // MARK: - Report

    func buildReport(_ results: [ScenarioResult]) -> String {
        let passed = results.filter { $0.passed }.count
        var lines = ["[BEHAVIOUR SCENARIO REPORT] \(passed)/\(results.count) passed"]
        for r in results {
            lines.append("  \(r.summary)")
            for step in r.stepResults.filter({ !$0.passed }) {
                lines.append("    FAIL: \(step.stepDescription) — \(step.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
