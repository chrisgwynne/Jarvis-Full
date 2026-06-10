import XCTest
@testable import JarvisMac

@MainActor
final class GitHubIssueOverlayTests: XCTestCase {

    // MARK: - Helpers

    /// Returns a fresh, isolated DraftStore to avoid shared-state bleed between tests.
    private func freshStore() -> GitHubIssueDraftStore {
        // DraftStore singleton is @MainActor — we reset it between tests via clearDraft.
        let store = GitHubIssueDraftStore.shared
        store.clearDraft()
        return store
    }

    override func setUp() async throws {
        GitHubIssueDraftStore.shared.clearDraft()
    }

    // MARK: - Acceptance Test A
    // Runtime error opens pre-filled issue overlay — no issue created until Submit.

    func testA_ErrorOpensOverlay_DraftIsPreFilled() {
        let store = freshStore()
        let opened = store.openForError(
            title: "STT failed to start",
            description: "AVAudioEngine threw an error when starting the microphone tap.",
            area: .stt,
            severity: .high,
            logs: "Error domain=AVAudio code=-50",
            signature: "stt_start_fail",
            defaultRepo: "owner/repo"
        )
        XCTAssertTrue(opened, "openForError should return true on first call")
        let draft = store.currentDraft
        XCTAssertNotNil(draft, "A draft must exist after openForError")
        XCTAssertEqual(draft?.title, "STT failed to start")
        XCTAssertEqual(draft?.area, .stt)
        XCTAssertEqual(draft?.severity, .high)
        XCTAssertEqual(draft?.source, .automaticError)
        XCTAssertEqual(draft?.submitState, .idle)
    }

    // MARK: - Acceptance Test B
    // No issue is created until user clicks Submit — draft starts in .idle state.

    func testB_DraftStartsIdle_NotSubmitted() {
        let store = freshStore()
        _ = store.openForError(
            title: "Error", description: "desc", area: .macApp, severity: .medium,
            logs: "", signature: "sig1", defaultRepo: "o/r"
        )
        XCTAssertEqual(store.currentDraft?.submitState, .idle,
                       "Draft must start in .idle — nothing submitted until user clicks Submit")
    }

    // MARK: - Acceptance Test C
    // User can edit title and body before submitting.

    func testC_UserCanEditFields() {
        let store = freshStore()
        _ = store.openForError(
            title: "Original title", description: "Original desc",
            area: .daemon, severity: .low, logs: "", signature: nil, defaultRepo: ""
        )
        guard let draft = store.currentDraft else {
            XCTFail("Expected draft"); return
        }
        draft.title = "Edited title"
        draft.description = "Edited description"
        draft.area = .tts
        XCTAssertEqual(draft.title, "Edited title")
        XCTAssertEqual(draft.description, "Edited description")
        XCTAssertEqual(draft.area, .tts)
    }

    // MARK: - Acceptance Test D
    // "Open a GitHub issue" opens blank overlay (source = .manualVoice).

    func testD_ManualOpen_BlankDraft() {
        let store = freshStore()
        store.openManual(defaultRepo: "owner/repo")
        XCTAssertNotNil(store.currentDraft, "Manual open must create a draft")
        XCTAssertEqual(store.currentDraft?.source, .manualVoice)
        XCTAssertTrue(store.currentDraft?.title.isEmpty ?? false,
                      "Blank manual open must have empty title")
    }

    // MARK: - Acceptance Test E
    // "Log this as an issue" opens overlay using recent context (source = .manualWithContext).

    func testE_LogAsIssue_PreFillsContext() {
        let store = freshStore()
        store.openManual(
            rawTranscript: "set a timer for five minutes",
            context: "intent=unknown | activeOverlay=news",
            defaultRepo: "owner/repo"
        )
        let draft = store.currentDraft
        XCTAssertNotNil(draft)
        XCTAssertEqual(draft?.source, .manualWithContext)
        XCTAssertTrue(draft?.title.contains("set a timer for five minutes") == true,
                      "Title must reference the transcript")
        XCTAssertFalse(draft?.description.isEmpty ?? true,
                       "Description must be pre-filled from context")
    }

    // MARK: - Acceptance Test F
    // Duplicate repeated errors do not spam overlays.

    func testF_DuplicateErrors_DoNotOpenMultipleOverlays() {
        let store = freshStore()

        let first = store.openForError(
            title: "Same error", description: "desc", area: .brain,
            severity: .high, logs: "", signature: "dup_sig", defaultRepo: ""
        )
        XCTAssertTrue(first, "First occurrence should open overlay")

        let second = store.openForError(
            title: "Same error", description: "desc", area: .brain,
            severity: .high, logs: "", signature: "dup_sig", defaultRepo: ""
        )
        XCTAssertFalse(second, "Duplicate same-signature error must NOT open new overlay")

        // Duplicate count must increment instead.
        XCTAssertGreaterThan(store.currentDraft?.duplicateCount ?? 0, 1,
                             "Duplicate count should increment, not open new overlay")
    }

    // MARK: - Acceptance Test G
    // Missing GitHub token shows clear config error — not a crash.

    func testG_BlankRepo_DraftHasEmptyRepo() {
        let store = freshStore()
        _ = store.openForError(
            title: "Error", description: "desc", area: .macApp,
            severity: .low, logs: "", signature: nil, defaultRepo: ""
        )
        // Draft's repo is blank → UI shows config error rather than submitting.
        XCTAssertTrue(store.currentDraft?.repo.isEmpty ?? false,
                      "Draft repo must reflect unconfigured state")
    }

    // MARK: - Acceptance Test H
    // Successful submit transitions draft to .success (model-layer test).

    func testH_SuccessState_HoldsURLAndNumber() {
        let draft = GitHubIssueDraft()
        draft.submitState = .success(url: "https://github.com/o/r/issues/42", number: 42)
        if case .success(let url, let number) = draft.submitState {
            XCTAssertEqual(url, "https://github.com/o/r/issues/42")
            XCTAssertEqual(number, 42)
        } else {
            XCTFail("Expected .success state")
        }
    }

    // MARK: - Acceptance Test I
    // Failed submit preserves all edited fields.

    func testI_FailedSubmit_PreservesFields() {
        let draft = GitHubIssueDraft()
        draft.title = "My issue title"
        draft.description = "Detailed description"
        draft.area = .stt
        draft.severity = .critical
        draft.logsTrace = "stack trace here"

        // Simulate submit failure
        draft.submitState = .failed(message: "Network error: timeout")

        // Fields must still be intact
        XCTAssertEqual(draft.title, "My issue title")
        XCTAssertEqual(draft.description, "Detailed description")
        XCTAssertEqual(draft.area, .stt)
        XCTAssertEqual(draft.severity, .critical)
        XCTAssertEqual(draft.logsTrace, "stack trace here")
        if case .failed(let msg) = draft.submitState {
            XCTAssertTrue(msg.contains("timeout"))
        } else {
            XCTFail("Expected .failed state")
        }
    }

    // MARK: - Model tests

    func testRenderedBody_ContainsAllSections() {
        let draft = GitHubIssueDraft()
        draft.description = "Something crashed"
        draft.expectedBehaviour = "Should work"
        draft.actualBehaviour = "It crashed"
        draft.stepsToReproduce = "1. Say X"
        draft.logsTrace = "NSError: -50"
        draft.area = .vision
        draft.severity = .high

        let body = draft.renderedBody
        XCTAssertTrue(body.contains("## Summary"))
        XCTAssertTrue(body.contains("Something crashed"))
        XCTAssertTrue(body.contains("## Expected Behaviour"))
        XCTAssertTrue(body.contains("Should work"))
        XCTAssertTrue(body.contains("## Actual Behaviour"))
        XCTAssertTrue(body.contains("It crashed"))
        XCTAssertTrue(body.contains("## Steps to Reproduce"))
        XCTAssertTrue(body.contains("1. Say X"))
        XCTAssertTrue(body.contains("```text"))
        XCTAssertTrue(body.contains("NSError: -50"))
        XCTAssertTrue(body.contains("## Environment"))
        XCTAssertTrue(body.contains("vision"))
        XCTAssertTrue(body.contains("high"))
    }

    func testResolvedLabels_IncludesTypeAndSeverity() {
        let draft = GitHubIssueDraft()
        draft.issueType = .bug
        draft.severity = .critical
        draft.labelsCSV = "mac-app, needs-routing"

        let labels = draft.resolvedLabels
        XCTAssertTrue(labels.contains("bug"))
        XCTAssertTrue(labels.contains("critical"))
        XCTAssertTrue(labels.contains("mac-app"))
        XCTAssertTrue(labels.contains("needs-routing"))
    }

    func testDuplicateCount_DefaultsToOne() {
        let draft = GitHubIssueDraft.blank()
        XCTAssertEqual(draft.duplicateCount, 1)
    }

    func testFromError_SetsAllFields() {
        let draft = GitHubIssueDraft.fromError(
            title: "Brain down",
            description: "No database",
            area: .brain,
            severity: .critical,
            logs: "SQLite error 1",
            signature: "brain_db_fail",
            duplicateCount: 3,
            defaultRepo: "owner/repo"
        )
        XCTAssertEqual(draft.title, "Brain down")
        XCTAssertEqual(draft.area, .brain)
        XCTAssertEqual(draft.severity, .critical)
        XCTAssertEqual(draft.source, .automaticError)
        XCTAssertEqual(draft.duplicateCount, 3)
        XCTAssertEqual(draft.errorSignature, "brain_db_fail")
        XCTAssertTrue(draft.logsTrace.contains("SQLite error 1"))
    }

    func testClearDraft_NilsCurrentDraft() {
        let store = freshStore()
        store.openManual(defaultRepo: "o/r")
        XCTAssertNotNil(store.currentDraft)
        store.clearDraft()
        XCTAssertNil(store.currentDraft)
    }

}
