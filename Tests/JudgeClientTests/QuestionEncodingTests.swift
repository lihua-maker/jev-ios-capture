import XCTest
@testable import JudgeClient

/// The wire shape of a question is where a CLI user learns the rules the hard way
/// ("choice criteria need name=description"). Here it is enforced by the type instead.
final class QuestionEncodingTests: XCTestCase {

    func testNoulCarriesTypeAndInstructionsOnly() throws {
        let q = try Question.noul(name: "reply_now", instructions: "Should the user reply now?")
        let json = q.jsonObject
        XCTAssertEqual(json["type"] as? String, "noul")
        XCTAssertEqual(json["instructions"] as? String, "Should the user reply now?")
        XCTAssertNil(json["criteria"])
    }

    func testScoreCarriesLevelsAsAnOrderedArray() throws {
        let q = try Question.score(name: "danger", instructions: "Risk?",
                                   levels: ["safe", "watch", "suspect"])
        let json = q.jsonObject
        XCTAssertEqual(json["type"] as? String, "score")
        XCTAssertEqual(json["criteria"] as? [String], ["safe", "watch", "suspect"])
    }

    func testChoiceCarriesKeyToDescriptionMap() throws {
        let q = try Question.choice(name: "intent", instructions: "Intent?",
                                    options: [.init("scam", "a fraud attempt"),
                                              .init("work", "a genuine request")])
        let criteria = try XCTUnwrap(q.jsonObject["criteria"] as? [String: String])
        XCTAssertEqual(criteria, ["scam": "a fraud attempt", "work": "a genuine request"])
    }

    func testChoiceRejectsBareLabels() {
        // The live API rejects this shape, so it must not be constructible.
        XCTAssertThrowsError(try Question.choice(name: "intent", instructions: "Intent?",
                                                 options: [.init("scam", ""), .init("work", "x")])) { error in
            XCTAssertEqual(error as? QuestionValidationError, .choiceNeedsKeyAndDescription("intent"))
        }
    }

    func testScoreNeedsAtLeastTwoLevels() {
        XCTAssertThrowsError(try Question.score(name: "danger", instructions: "Risk?",
                                                levels: ["only one"])) { error in
            XCTAssertEqual(error as? QuestionValidationError, .scoreNeedsTwoLevels("danger"))
        }
    }

    func testDuplicateOptionKeysAreRejected() {
        XCTAssertThrowsError(try Question.choice(name: "intent", instructions: "Intent?",
                                                 options: [.init("a", "x"), .init("a", "y")])) { error in
            XCTAssertEqual(error as? QuestionValidationError, .duplicateChoiceKey("intent", "a"))
        }
    }

    func testEmptyInstructionsAreRejected() {
        XCTAssertThrowsError(try Question.noul(name: "q", instructions: "   ")) { error in
            XCTAssertEqual(error as? QuestionValidationError, .emptyInstructions("q"))
        }
    }

    func testPayloadIsAMapKeyedByQuestionName() throws {
        let payload = QuestionsPayload([
            try .noul(name: "a", instructions: "A?"),
            try .noul(name: "b", instructions: "B?"),
        ])
        let json = payload.jsonObject
        XCTAssertEqual(json.keys.sorted(), ["a", "b"])
        XCTAssertEqual((json["a"] as? [String: Any])?["instructions"] as? String, "A?")
    }

    func testCopilotPackShapeMatchesTheLiveContract() throws {
        let questions = try JudgmentPack.copilotQuestions(policy: JudgmentPolicy())
        XCTAssertEqual(questions.map { $0.name }, ["intent", "danger", "reply_now", "verify_first"])
        let payload = QuestionsPayload(questions).jsonObject

        let intent = try XCTUnwrap(payload["intent"] as? [String: Any])
        XCTAssertEqual(intent["type"] as? String, "choice")
        XCTAssertEqual((intent["criteria"] as? [String: String])?.keys.sorted(),
                       ["chat", "pressure", "scam", "work"])

        let danger = try XCTUnwrap(payload["danger"] as? [String: Any])
        XCTAssertEqual(danger["type"] as? String, "score")
        XCTAssertEqual((danger["criteria"] as? [String])?.count, 5)
        XCTAssertTrue((danger["criteria"] as? [String])?.first?.hasPrefix("安全") ?? false)

        XCTAssertEqual((payload["reply_now"] as? [String: Any])?["type"] as? String, "noul")
        XCTAssertEqual((payload["verify_first"] as? [String: Any])?["type"] as? String, "noul")
    }

    func testCandidateQuestionsScoreEveryCandidateOnOneDimension() throws {
        let policy = JudgmentPolicy()
        let questions = try JudgmentPack.candidateQuestions(["a", "b", "c"], policy: policy)
        XCTAssertEqual(questions.map { $0.name }, ["candidate_0", "candidate_1", "candidate_2"])
        for q in questions {
            XCTAssertEqual(q.kind, .score)
            XCTAssertEqual(q.levels?.count, 5, "levels must be identical across candidates")
            XCTAssertTrue(q.instructions.contains("candidate_"), "instructions must name the candidate")
        }
    }
}