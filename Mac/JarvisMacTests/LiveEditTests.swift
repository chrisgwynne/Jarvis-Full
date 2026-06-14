import XCTest
@testable import JarvisMac

// MARK: - LiveEditTests

@MainActor
final class LiveEditTests: XCTestCase {

    // A mutable text backing for an in-memory living system.
    private final class Box { var value: String; init(_ v: String) { value = v } }

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("liveedit_\(UUID().uuidString).json")
    }

    /// A hermetic engine over a fresh registry + audit log (no shared state).
    private func makeEngine() -> (LiveEditEngine, LivingSystemRegistry, LiveEditAuditLog) {
        let reg = LivingSystemRegistry()
        let audit = LiveEditAuditLog(fileURL: tmpURL())
        let engine = LiveEditEngine(registry: reg, audit: audit, fileURL: tmpURL())
        return (engine, reg, audit)
    }

    private func registerText(_ reg: LivingSystemRegistry,
                              id: LivingSystemID,
                              box: Box,
                              isProtected: Bool = false,
                              injects: Bool = true,
                              validator: @escaping (String) -> ValidationResult = LiveEditValidators.nonEmpty) {
        reg.register(LivingSystem(
            id: id, isProtected: isProtected, injectsContext: injects, defaultRisk: .medium,
            read: { box.value }, write: { box.value = $0 }, validator: validator
        ))
    }

    // MARK: - Apply / validate

    func testApplyEditUpdatesSystemAndAudits() {
        let (engine, reg, audit) = makeEngine()
        let box = Box("# Soul\nBe useful to the user.")
        registerText(reg, id: .soul, box: box, validator: LiveEditValidators.soul)

        let outcome = engine.apply(.soul,
                                   newValue: "# Soul\nBe useful to the user.\n- Always prioritise brevity.",
                                   reason: "prioritise brevity", source: .user)
        guard case .applied = outcome else { return XCTFail("expected applied, got \(outcome)") }
        XCTAssertTrue(box.value.contains("brevity"))
        XCTAssertEqual(audit.recent(limit: 1).first?.action, "applied")
        XCTAssertEqual(audit.lastChange?.summary, "prioritise brevity")
    }

    func testRejectEmptyEdit() {
        let (engine, reg, _) = makeEngine()
        let box = Box("# Voice\nCalm and direct.")
        registerText(reg, id: .voice, box: box)
        let outcome = engine.apply(.voice, newValue: "   ", reason: "blank", source: .user)
        guard case .rejected = outcome else { return XCTFail("expected rejected") }
        XCTAssertEqual(box.value, "# Voice\nCalm and direct.", "system must be unchanged on reject")
    }

    func testSoulMustPreserveMission() {
        let (engine, reg, _) = makeEngine()
        let box = Box("Be useful to the user.")
        registerText(reg, id: .soul, box: box, validator: LiveEditValidators.soul)

        // No mission anchor → rejected.
        if case .applied = engine.apply(.soul, newValue: "Banana bread recipe.", reason: "x", source: .user) {
            XCTFail("soul without mission anchor should be rejected")
        }
        // Anchor present → applied.
        guard case .applied = engine.apply(.soul, newValue: "Help the user and be useful.", reason: "y", source: .user) else {
            return XCTFail("anchored soul should apply")
        }
    }

    func testNoChangeReturnsNoChange() {
        let (engine, reg, _) = makeEngine()
        let box = Box("# Goals\nShip Jarvis.")
        registerText(reg, id: .goals, box: box)
        let outcome = engine.apply(.goals, newValue: "# Goals\nShip Jarvis.", reason: "same", source: .user)
        XCTAssertEqual(outcome, .noChange)
    }

    // MARK: - Rollback

    func testRollbackRestoresPreviousState() {
        let (engine, reg, _) = makeEngine()
        let box = Box("original useful")
        registerText(reg, id: .identity, box: box, validator: LiveEditValidators.nonEmpty)
        _ = engine.apply(.identity, newValue: "changed identity", reason: "edit", source: .user)
        XCTAssertEqual(box.value, "changed identity")

        guard case .applied = engine.rollbackLast() else { return XCTFail("rollback should apply") }
        XCTAssertEqual(box.value, "original useful", "rollback must restore the previous value")
    }

    func testRollbackWithNoHistoryRejects() {
        let (engine, _, _) = makeEngine()
        guard case .rejected = engine.rollbackLast() else { return XCTFail("expected rejection") }
    }

    // MARK: - Protected core

    func testProtectedSystemNeedsApproval() {
        let (engine, reg, _) = makeEngine()
        let box = Box("boundaries useful")
        registerText(reg, id: .boundaries, box: box, isProtected: true, injects: false)

        // Unapproved → proposal, not applied.
        guard case .needsApproval = engine.apply(.boundaries, newValue: "new boundaries", reason: "edit", source: .user) else {
            return XCTFail("protected edit should need approval")
        }
        XCTAssertEqual(box.value, "boundaries useful", "protected system must not change without approval")

        // Explicit approval → applied.
        guard case .applied = engine.apply(.boundaries, newValue: "new boundaries", reason: "edit", source: .userApproved) else {
            return XCTFail("approved protected edit should apply")
        }
        XCTAssertEqual(box.value, "new boundaries")
    }

    // MARK: - NL instructions

    func testInstructionAppendsPrinciple() {
        let (engine, reg, _) = makeEngine()
        let box = Box("# Behaviour\n- Be concise.")
        registerText(reg, id: .behaviourRules, box: box)
        _ = engine.applyInstruction(.behaviourRules, instruction: "always prioritise brevity", source: .user)
        XCTAssertTrue(box.value.contains("- Always prioritise brevity."), "got: \(box.value)")
    }

    func testInstructionRemovesMatchingRule() {
        let (engine, reg, _) = makeEngine()
        let box = Box("# Behaviour\n- Be concise.\n- Avoid filler phrases.")
        registerText(reg, id: .behaviourRules, box: box)
        _ = engine.applyInstruction(.behaviourRules, instruction: "remove the rule about filler", source: .user)
        XCTAssertFalse(box.value.contains("filler"), "got: \(box.value)")
        XCTAssertTrue(box.value.contains("Be concise."))
    }

    // MARK: - Context injection reflects edits

    func testCombinedContextBlockReflectsEdit() {
        let (engine, reg, _) = makeEngine()
        let box = Box("Calm and direct.")
        registerText(reg, id: .voice, box: box, injects: true)
        _ = engine.apply(.voice, newValue: "Terse and dry.", reason: "edit", source: .user)
        let ctx = reg.combinedContextBlock()
        XCTAssertTrue(ctx.contains("[VOICE]"))
        XCTAssertTrue(ctx.contains("Terse and dry."))
    }

    func testProtectedSystemNotInjected() {
        let (_, reg, _) = makeEngine()
        let box = Box("secret boundaries")
        registerText(reg, id: .boundaries, box: box, isProtected: true, injects: false)
        XCTAssertFalse(reg.combinedContextBlock().contains("secret boundaries"))
    }

    // MARK: - Self-fix → Heartbeat

    func testReportFailureCreatesHeartbeatIssueAndProposal() {
        let (engine, reg, audit) = makeEngine()
        let box = Box("# Commands")
        registerText(reg, id: .commands, box: box)
        let before = HeartbeatStore.shared.state.openIssues.count
        _ = engine.reportFailure(systemID: .commands, detail: "open dashboard failed 3x")
        XCTAssertGreaterThanOrEqual(HeartbeatStore.shared.state.openIssues.count, before)
        XCTAssertTrue(HeartbeatStore.shared.state.openIssues.contains { $0.text.contains("open dashboard failed") })
        XCTAssertEqual(audit.recent(limit: 1).first?.action, "proposed")
    }

    // MARK: - LiveDocStore persistence + reload

    func testLiveDocStorePersistsAndReloads() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("livedoc_\(UUID().uuidString).md")
        let store = LiveDocStore(id: "voice", defaultText: "default", fileURL: url)
        store.setText("custom voice")
        XCTAssertEqual(store.text, "custom voice")
        // Write through happens via debounce; force a direct write to verify the
        // file-backed read path of a second store.
        try? "from disk".data(using: .utf8)?.write(to: url, options: .atomic)
        let store2 = LiveDocStore(id: "voice", defaultText: "default", fileURL: url)
        XCTAssertEqual(store2.text, "from disk")
    }

    // MARK: - Validators

    func testCommandsValidatorAcceptsValidMapping() {
        XCTAssertTrue(LiveEditValidators.commands("shop dashboard => Etsy, Shopify, eBay").isValid)
    }

    func testCommandsValidatorRejectsMissingAction() {
        XCTAssertFalse(LiveEditValidators.commands("shop dashboard =>").isValid)
    }

    func testCommandsValidatorRejectsDuplicateTrigger() {
        let two = "a => x\na => y"
        XCTAssertFalse(LiveEditValidators.commands(two).isValid)
    }

    // MARK: - Instruction transforms (pure)

    func testTransformAppendDefault() {
        let out = LiveEditInstruction.transform(current: "- One.", instruction: "be terse")
        XCTAssertEqual(out, "- One.\n- Be terse.")
    }

    func testTransformRemoval() {
        let out = LiveEditInstruction.transform(current: "- Keep.\n- Remove me please.",
                                                instruction: "forget the rule about remove me")
        XCTAssertFalse(out.contains("Remove me"))
    }

    // MARK: - Router parsing (pure)

    func testParseAlias() {
        let parsed = LiveEditCommandRouter.parseAlias("when i say shop dashboard i mean etsy shopify and ebay")
        XCTAssertEqual(parsed?.0, "shop dashboard")
        XCTAssertEqual(parsed?.1, "etsy shopify and ebay")
    }

    func testStripConnectors() {
        XCTAssertEqual(LiveEditCommandRouter.stripConnectors("so you always prioritise brevity"),
                       "always prioritise brevity")
    }

    func testSplitMapping() {
        let parsed = LiveEditCommandRouter.splitMapping("standup => open Slack and Notion")
        XCTAssertEqual(parsed?.0, "standup")
        XCTAssertEqual(parsed?.1, "open Slack and Notion")
    }

    // MARK: - Router end-to-end (shared engine)

    func testRouterHandlesShowLivingSystems() {
        let reply = LiveEditCommandRouter.handle(rawText: "show living systems",
                                                 normalized: "show living systems")
        XCTAssertNotNil(reply)
    }

    func testRouterReturnsNilForNonLiveEdit() {
        let reply = LiveEditCommandRouter.handle(rawText: "what's the weather",
                                                 normalized: "what's the weather")
        XCTAssertNil(reply)
    }
}
