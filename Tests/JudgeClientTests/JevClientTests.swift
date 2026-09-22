import XCTest
@testable import JudgeClient

final class JevClientTests: XCTestCase {

    private func client(_ response: @escaping () -> HTTPResponse) throws -> (JevClient, StubTransport) {
        let transport = StubTransport(response())
        return (JevClient(route: try RouteSet.typesafe().resolve(.judgment), transport: transport),
                transport)
    }

    // MARK: request

    func testJudgeSendsTheDocumentedContract() async throws {
        let (client, transport) = try self.client { TestJSON.response(Answers.scam()) }
        _ = try await client.judge(state: "TRANSCRIPT\n对方: 在吗",
                                   questions: [try .noul(name: "reply_now", instructions: "Reply now?")])

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-key")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Accept"], "application/json")

        let body = TestJSON.json(request)
        XCTAssertEqual(body["state"] as? String, "TRANSCRIPT\n对方: 在吗")
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertEqual((questions["reply_now"] as? [String: Any])?["type"] as? String, "noul")
        XCTAssertEqual((questions["reply_now"] as? [String: Any])?["instructions"] as? String, "Reply now?")
    }

    func testModelCanBeOverriddenPerCall() async throws {
        let (client, transport) = try self.client { TestJSON.response(Answers.scam()) }
        _ = try await client.judge(state: "x", questions: [try .noul(name: "a", instructions: "A?")],
                                   model: "jev-preview")
        XCTAssertEqual(TestJSON.json(transport.lastRequest)["model"] as? String, "jev-preview")
    }

    func testEmptyStateIsRejectedBeforeAnyRequest() async throws {
        let (client, transport) = try self.client { TestJSON.response(Answers.scam()) }
        do {
            _ = try await client.judge(state: "   \n ", questions: [])
            XCTFail("expected a rejection")
        } catch let error as HTTPError {
            guard case .malformedResponse = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertTrue(transport.calls.isEmpty, "no request should be sent for empty state")
    }

    // MARK: responses

    func testDecodesTypedAnswersWithProbabilities() async throws {
        let (client, _) = try self.client { TestJSON.response(Answers.scam()) }
        let response = try await client.judge(state: "x",
                                              questions: try JudgmentPack.copilotQuestions(policy: JudgmentPolicy()))
        XCTAssertEqual(response.model, "jev-1.13.0")
        XCTAssertEqual(response.answers["intent"]?.choice, "scam")
        XCTAssertEqual(response.answers["intent"]?.confidence, 1.0)
        XCTAssertEqual(response.answers["intent"]?.probabilities?["scam"], 1.0)
        XCTAssertEqual(response.noul("reply_now"), 0.1)
        XCTAssertEqual(response.noul("verify_first"), 0.95)
        XCTAssertEqual(response.answers["danger"]?.score ?? 0, 3.16, accuracy: 0.001)
        XCTAssertEqual(response.answers["danger"]?.confidence ?? 0, 0.82, accuracy: 0.001)
        XCTAssertEqual(response.usage?.inputTokens, 1560)
        XCTAssertEqual(response.usage?.outputTokens, 155)
    }

    func testScoreLabelComesFromTheLegendAtTheRoundedLevel() async throws {
        let (client, _) = try self.client { TestJSON.response(Answers.scam(dangerScore: 3.16)) }
        let response = try await client.judge(state: "x", questions: [])
        XCTAssertEqual(response.scoreLabel("danger"), "高度可疑=高度符合诈骗特征，切勿转账")
        XCTAssertEqual(response.scorePeakProbability("danger") ?? 0, 0.79, accuracy: 0.001)
    }

    func testThresholdsAreTakenFromPolicyNotBuiltIn() async throws {
        let (client, _) = try self.client { TestJSON.response(Answers.scam(replyNow: 0.6)) }
        let response = try await client.judge(state: "x", questions: [])
        XCTAssertEqual(response.bool("reply_now", atLeast: 0.5), true)
        XCTAssertEqual(response.bool("reply_now", atLeast: 0.7), false)
    }

    func testMalformedBodyIsReportedAsSuch() async throws {
        let (client, _) = try self.client { TestJSON.raw("<html>gateway timeout</html>") }
        do {
            _ = try await client.judge(state: "x", questions: [])
            XCTFail("expected a decode failure")
        } catch let error as HTTPError {
            guard case .malformedResponse = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    // MARK: transport-level errors surface unchanged

    func testTransportErrorsReachTheCallerWithTheProviderMessage() async throws {
        // 401/403 handling lives in the transport; the client must not swallow or re-wrap it.
        let transport = StubTransport { _ in
            throw HTTPError.unauthorized(status: 401, detail: "invalid api key", requestId: "req_1")
        }
        let client = JevClient(route: try RouteSet.typesafe().resolve(.judgment), transport: transport)
        do {
            _ = try await client.judge(state: "x", questions: [])
            XCTFail("expected the transport error")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .unauthorized(status: 401, detail: "invalid api key", requestId: "req_1"))
            XCTAssertTrue(error.description.contains("req_1"), "the request id belongs in the message")
        }
    }

    func testProductNotActivatedMessageIsPreserved() {
        // The real DashScope failure mode for a provider/model that was never enabled.
        let body = Data(#"{"error":{"message":"The product is not activated."}}"#.utf8)
        XCTAssertEqual(HTTPError.detail(fromJSON: body, fallback: "?"), "The product is not activated.")
    }

    func testErrorDetailExtractionShapes() {
        XCTAssertEqual(HTTPError.detail(fromJSON: Data(#"{"error":"plain"}"#.utf8), fallback: "?"),
                       "plain")
        XCTAssertEqual(HTTPError.detail(fromJSON: Data(#"{"message":"top level"}"#.utf8), fallback: "?"),
                       "top level")
        XCTAssertEqual(HTTPError.detail(fromJSON: Data("not json".utf8), fallback: "fallback"),
                       "fallback")
        XCTAssertEqual(HTTPError.detail(fromJSON: Data(#"{"error":{"code":7}}"#.utf8), fallback: "?"),
                       #"{"code":7}"#)
    }

    // MARK: models + probe

    func testModelsListingAcceptsBothShapes() async throws {
        let transport = StubTransport(TestJSON.response(["models": [["name": "jev-latest",
                                                                   "release_date": "2026-09-10"]]]))
        let client = JevClient(route: try RouteSet.typesafe().resolve(.judgment), transport: transport)
        XCTAssertEqual(try await client.models(), ["jev-latest"])

        let transport2 = StubTransport(TestJSON.response(["data": [["id": "jev-preview"]]]))
        let client2 = JevClient(route: try RouteSet.typesafe().resolve(.judgment), transport: transport2)
        XCTAssertEqual(try await client2.models(), ["jev-preview"])
    }

    func testProbeSucceedsAndReportsLatency() async throws {
        let (client, transport) = try self.client { TestJSON.response(["models": [["name": "jev-latest"]]]) }
        let result = await client.probe()
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.detail.contains("1 model"))
        XCTAssertNotNil(result.millis)
        XCTAssertEqual(transport.lastRequest?.url.absoluteString, "https://api.typesafe.ai/v1/models")
    }

    func testProbeNeverThrowsAndExplainsFailures() async throws {
        let transport = StubTransport { _ in
            throw HTTPError.httpStatus(code: 400, detail: "The product is not activated.", requestId: nil)
        }
        let client = JevClient(route: try RouteSet.typesafe().resolve(.judgment), transport: transport)
        let result = await client.probe()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("The product is not activated."))
    }
}