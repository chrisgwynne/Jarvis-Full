import XCTest
@testable import JarvisMac

/// Pins down the classifier's routing decisions.  This is the gate
/// between "user uttered something we couldn't map to an intent" and
/// "talk to the LLM in free-text mode vs intent-JSON mode" — getting
/// it wrong is exactly the bug that produced "I don't have an action
/// for that yet" instead of a real answer.
final class QuestionClassifierTests: XCTestCase {

    // MARK: - Clarification reply (highest precedence)

    func test_shortReply_whilePendingQuestion_isClarification() {
        XCTAssertEqual(
            QuestionClassifier.classify("yes",
                                         hasPendingQuestion: true,
                                         hasActiveContext: false),
            .clarificationReply)
        XCTAssertEqual(
            QuestionClassifier.classify("the second one",
                                         hasPendingQuestion: true,
                                         hasActiveContext: true),
            .clarificationReply)
    }

    // MARK: - Contextual follow-up

    func test_pronounWithActiveContext_isContextualFollowUp() {
        XCTAssertEqual(
            QuestionClassifier.classify("what colour is it?",
                                         hasPendingQuestion: false,
                                         hasActiveContext: true),
            .contextualFollowUp)
    }

    func test_ordinalReference_isContextualFollowUp() {
        XCTAssertEqual(
            QuestionClassifier.classify("open the second one",
                                         hasPendingQuestion: false,
                                         hasActiveContext: true),
            .contextualFollowUp)
    }

    func test_pronounWithoutActiveContext_isFactual() {
        // "it" with no recent context — treat as a regular question.
        XCTAssertEqual(
            QuestionClassifier.classify("what is it?",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .factualQuestion)
    }

    // MARK: - Memory questions

    func test_rememberCue_isMemoryQuestion() {
        XCTAssertEqual(
            QuestionClassifier.classify("what do you remember about Shopify?",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .memoryQuestion)
    }

    func test_didITellYouCue_isMemoryQuestion() {
        XCTAssertEqual(
            QuestionClassifier.classify("did I tell you about the launch yesterday",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .memoryQuestion)
    }

    // MARK: - Web-shaped questions

    func test_currentScoreQuery_isWebSearch() {
        XCTAssertEqual(
            QuestionClassifier.classify("what's the score in the match today?",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .webSearchQuestion)
    }

    func test_stockPriceQuery_isWebSearch() {
        XCTAssertEqual(
            QuestionClassifier.classify("what's the latest stock price for Apple",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .webSearchQuestion)
    }

    // MARK: - Factual questions

    func test_geographicQuestion_isFactual() {
        XCTAssertEqual(
            QuestionClassifier.classify("how tall is Snowdon",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .factualQuestion)
    }

    func test_questionMarkSuffix_isFactual() {
        XCTAssertEqual(
            QuestionClassifier.classify("is the moon a satellite?",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .factualQuestion)
    }

    // MARK: - General chat

    func test_thanks_isGeneralChat() {
        XCTAssertEqual(
            QuestionClassifier.classify("thanks Jarvis",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .generalChat)
    }

    func test_goodMorning_isGeneralChat() {
        XCTAssertEqual(
            QuestionClassifier.classify("good morning",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .generalChat)
    }

    // MARK: - Unsupported-command shape

    func test_actionVerbWithoutQuestionShape_isUnsupportedCommand() {
        // Looks like the user wants Jarvis to *do* something — but the
        // deterministic pipeline didn't recognise it.  Route to intent-JSON.
        XCTAssertEqual(
            QuestionClassifier.classify("set my desk lamp to half",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .unsupportedCommand)
    }

    // MARK: - Edge cases

    func test_emptyInput_isGeneralChat() {
        XCTAssertEqual(
            QuestionClassifier.classify("",
                                         hasPendingQuestion: false,
                                         hasActiveContext: false),
            .generalChat)
    }

    func test_pendingQuestion_overridesPronounRule() {
        // While Jarvis has a pending question, "yes please" is a reply,
        // not a generic factual question.
        XCTAssertEqual(
            QuestionClassifier.classify("yes please",
                                         hasPendingQuestion: true,
                                         hasActiveContext: true),
            .clarificationReply)
    }
}
