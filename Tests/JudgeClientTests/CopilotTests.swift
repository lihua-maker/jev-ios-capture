import XCTest
@testable import JudgeClient

final class CopilotTests: XCTestCase {

    private let candidateA = "李经理，垫款我这边不太方便，麻烦走一下公司流程，我配合您把材料准备好。"
    private let candidateB = "好的李经理，2980我马上转给您，私户还是原来的账号吗？"
    private let candidateC = "李经理，这事我得先跟您电话确认一下，方便现在打给您吗？"

    /// A transport that plays the two roles in one run: typed judgments, and drafting.
    private func scripted(judgment: [String: Any], ranking: [String: Any]? = nil,
                          draft: [String]? = nil) -> StubTransport {
        StubTransport { request in
            if request.url.path.hasSuffix("/chat/completions") {
                let choices = (draft ?? []).map { ["message": ["content": $0]] }
                return TestJSON.response(["choices": choices])
            }
            let questions = (TestJSON.json(request)["questions"] as? [String: Any]) ?? [:]
            let isRanking = questions.keys.contains { $0.hasPrefix("candidate_") }
            if isRanking, let ranking { return TestJSON.response(ranking) }
            return TestJSON.response(judgment)
        }
    }

    private func copilot(_ transport: StubTransport, withReplyRoute: Bool = false,
                         policy: JudgmentPolicy = JudgmentPolicy()) throws -> Copilot {
        let routes = RouteSet(judgment: .preset(.typesafe, apiKey: "k"),
                              reply: withReplyRoute ? .preset(.openRouter, apiKey: "k") : RouteConfig(),
                              vision: RouteConfig())
        return Copilot(judgmentRoute: try routes.resolve(.judgment),
                       replyRoute: try? routes.resolve(.reply),
                       transport: transport, policy: policy)
    }

    // MARK: judge first

    func testJudgmentRunsBeforeAnyDrafting() async throws {
        let transport = scripted(judgment: Answers.scam(replyNow: 0.1))
        let run = try await copilot(transport).run(transcript: "对方: 在吗", userFacts: nil)
        XCTAssertEqual(transport.calls.count, 1, "with a low reply-now only the judgment is asked")
        XCTAssertEqual(run.judgment.intent, "scam")
        XCTAssertFalse(run.judgment.shouldReplyNow)
        XCTAssertTrue(run.candidates.isEmpty)
        XCTAssertFalse(run.drafted)
        XCTAssertEqual(run.backend, .typesafeTyped)
    }

    func testRankingOrderFollowsTheJudgedScoresNotTheModelOrder() async throws {
        let transport = scripted(judgment: Answers.scam(replyNow: 0.9, verifyFirst: 0.1),
                                 ranking: Answers.ranking([1.2, 3.9, 2.6]))
        let run = try await copilot(transport)
            .run(transcript: "x", providedCandidates: [candidateA, candidateB, candidateC])

        XCTAssertEqual(run.candidates.map { $0.text }, [candidateB, candidateC, candidateA])
        XCTAssertEqual(run.recommended?.text, candidateB)
        XCTAssertEqual(run.recommended?.score ?? 0, 3.9, accuracy: 0.001)
        XCTAssertEqual(run.candidates.last?.score ?? 0, 1.2, accuracy: 0.001)
        XCTAssertFalse(run.drafted, "candidates were supplied, nothing was drafted")
    }

    func testDraftingUsesTheReplyRouteAndThenRanksWhatItDrafted() async throws {
        let transport = scripted(judgment: Answers.scam(replyNow: 0.9, verifyFirst: 0.1),
                                 ranking: Answers.ranking([3.0, 1.0]),
                                 draft: ["草稿一", "草稿二"])
        let run = try await copilot(transport, withReplyRoute: true)
            .run(transcript: "x", draftCount: 2)

        XCTAssertTrue(run.drafted)
        XCTAssertEqual(run.candidates.map { $0.text }, ["草稿一", "草稿二"])
        XCTAssertEqual(transport.calls.compactMap { $0.url.path }, [
            "/v1/systemone", "/chat/completions", "/v1/systemone",
        ])
        // the ranking request must carry the candidates as backticked state paths
        let rankingBody = TestJSON.json(transport.calls.last)
        let state = try XCTUnwrap(rankingBody["state"] as? String)
        XCTAssertTrue(state.contains("`candidate_0`"), "state: \(state)")
        XCTAssertTrue(state.contains("`candidate_1`"))
    }

    // MARK: escalation

    func testHighRiskEscalatesWithTheLevelLabel() async throws {
        let transport = scripted(judgment: Answers.scam(dangerScore: 3.16))
        let run = try await copilot(transport).run(transcript: "x")
        XCTAssertEqual(run.escalation, Escalation.highRisk(level: 3, label: "高度可疑=高度符合诈骗特征，切勿转账"))
        XCTAssertEqual(run.judgment.dangerLabel, "高度可疑=高度符合诈骗特征，切勿转账")
    }

    func testVerificationEscalatesWhenTheModelSaysCheckTheIdentity() async throws {
        let transport = scripted(judgment: Answers.scam(dangerScore: 0.5, verifyFirst: 0.9))
        let run = try await copilot(transport).run(transcript: "x")
        XCTAssertEqual(run.escalation, Escalation.verificationRequired)
    }

    func testLowConfidenceEscalatesInsteadOfBeingActedOn() async throws {
        let transport = scripted(judgment: Answers.scam(dangerScore: 0.4, verifyFirst: 0.2,
                                                        intentConfidence: 0.4, dangerConfidence: 0.9))
        let run = try await copilot(transport).run(transcript: "x")
        XCTAssertEqual(run.escalation, Escalation.lowConfidence(question: "intent", confidence: 0.4))
    }

    func testASettledBenignConversationEscalatesNothing() async throws {
        let transport = scripted(judgment: Answers.scam(dangerScore: 0.1, verifyFirst: 0.02,
                                                        intentConfidence: 0.99, dangerConfidence: 0.98,
                                                        intent: "work"))
        let run = try await copilot(transport).run(transcript: "x")
        XCTAssertEqual(run.judgment.intent, "work")
        XCTAssertNil(run.escalation)
    }

    func testPolicyThresholdsDriveTheEscalation() async throws {
        var policy = JudgmentPolicy()
        policy.dangerAlert = 1.0
        let transport = scripted(judgment: Answers.scam(dangerScore: 1.2, verifyFirst: 0.0))
        let run = try await copilot(transport, policy: policy).run(transcript: "x")
        XCTAssertEqual(run.escalation, Escalation.highRisk(level: 1, label: run.judgment.dangerLabel ?? ""))
    }

    // MARK: state

    func testStateCarriesTranscriptFactsAndCandidates() {
        let state = Copilot.state(transcript: "我方: 在的\n对方: 帮个忙",
                                  userFacts: "没有垫款权限",
                                  candidates: ["回复一"])
        XCTAssertTrue(state.contains("我方: 在的"))
        XCTAssertTrue(state.contains("USER FACTS:\n没有垫款权限"))
        XCTAssertTrue(state.contains("- `candidate_0`: 回复一"))
        XCTAssertTrue(state.contains("OCR 可能带来错字"), "the OCR-noise warning must reach the judge")
    }

    func testStateOmitsEmptySections() {
        let state = Copilot.state(transcript: "x", userFacts: "   ")
        XCTAssertFalse(state.contains("USER FACTS"))
        XCTAssertFalse(state.contains("CANDIDATE"))
    }

    // MARK: the chat-model backend

    func testLLMBackendIsMarkedAndUncalibratedAnswersEscalate() async throws {
        // A chat model answering the JSON contract omits confidence; treating that as confidence
        // would let an uncalibrated answer drive the product.
        let llmAnswer = """
        Sure! Here is the judgment:
        {"answers": {"intent": {"type": "choice", "choice": "scam"},
                     "danger": {"type": "score", "score": 1},
                     "reply_now": {"type": "noul", "noul": 0.2},
                     "verify_first": {"type": "noul", "noul": 0.1}}}
        """
        let transport = StubTransport { _ in
            TestJSON.response(["choices": [["message": ["content": llmAnswer]]]])
        }
        let route = try RouteSet.single(.preset(.openRouter, apiKey: "k")).resolve(.judgment)
        let run = try await Copilot(judgmentRoute: route, replyRoute: nil, transport: transport)
            .run(transcript: "x")

        XCTAssertEqual(run.backend, .llmJSON)
        XCTAssertEqual(run.judgment.intent, "scam")
        XCTAssertEqual(run.judgment.response.answers["intent"]?.confidence, 0)
        XCTAssertTrue(run.judgment.isLowConfidence)
        guard case .lowConfidence(_, let confidence)? = run.escalation else {
            return XCTFail("expected the uncalibrated answer to escalate, got \(String(describing: run.escalation))")
        }
        XCTAssertEqual(confidence, 0)
    }

    func testJSONExtractionSurvivesProseAndCodeFences() {
        let fenced = "```json\n{\"answers\": {\"a\": {\"type\": \"noul\", \"noul\": 0.5}}}\n```"
        let extracted = LLMJudgeClient.firstJSONObject(in: fenced)
        XCTAssertNotNil(extracted)
        XCTAssertEqual((extracted?["answers"] as? [String: Any])?["a"] != nil, true)
        XCTAssertNil(LLMJudgeClient.firstJSONObject(in: "no json here"))
        // a brace inside a string must not unbalance the scan
        let tricky = #"{"answers": {"a": {"type": "chat", "note": "use } carefully"}}}"#
        XCTAssertNotNil(LLMJudgeClient.firstJSONObject(in: tricky))
    }
}