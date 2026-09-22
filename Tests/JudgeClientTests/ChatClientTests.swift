import XCTest
@testable import JudgeClient

final class ChatClientTests: XCTestCase {

    private func client(_ response: @escaping () -> HTTPResponse,
                        preset: RoutePreset = .openRouter) throws -> (ChatClient, StubTransport) {
        let transport = StubTransport(response())
        let route = try RouteSet(judgment: .preset(.typesafe, apiKey: "k"),
                                 reply: .preset(preset, apiKey: "k")).resolve(.reply)
        return (ChatClient(route: route, transport: transport), transport)
    }

    private func completion(_ contents: [String]) -> HTTPResponse {
        TestJSON.response(["choices": contents.map { ["message": ["role": "assistant", "content": $0]] }])
    }

    func testTextMessagesEncodeContentAsAString() async throws {
        let (client, transport) = try self.client { self.completion(["你好"]) }
        _ = try await client.chat(messages: [.system("sys"), .user("hi")], count: 1)
        let body = TestJSON.json(transport.lastRequest)
        XCTAssertEqual(body["model"] as? String, "deepseek/deepseek-chat-v3.1")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "sys")
        XCTAssertNil(body["n"], "n is omitted for a single answer")
    }

    func testMultipleAlternativesSendN() async throws {
        let (client, transport) = try self.client { self.completion(["a", "b", "c"]) }
        let texts = try await client.chat(messages: [.user("hi")], count: 3)
        XCTAssertEqual(texts, ["a", "b", "c"])
        XCTAssertEqual(TestJSON.json(transport.lastRequest)["n"] as? Int, 3)
    }

    func testProvidersIgnoringNReturnOneAnswerWithLines() async throws {
        // Some providers answer a request for 3 alternatives with one multi-line message; dropping
        // the alternatives silently would be worse than a parse rule.
        let (client, _) = try self.client { self.completion(["第一句\n第二句\n\n第三句"]) }
        let texts = try await client.chat(messages: [.user("hi")], count: 3)
        XCTAssertEqual(texts, ["第一句", "第二句", "第三句"])
    }

    func testEmptyCompletionIsAnError() async throws {
        let (client, _) = try self.client { self.completion(["   "]) }
        do {
            _ = try await client.chat(messages: [.user("hi")])
            XCTFail("expected an error")
        } catch let error as HTTPError {
            guard case .malformedResponse = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testVisionMessageEncodesAnImageDataURL() async throws {
        let (client, transport) = try self.client { self.completion(["转账卡片截图"]) }
        let text = try await client.readImage(base64PNG: "AAAB", prompt: "读一下这张图")
        XCTAssertEqual(text, "转账卡片截图")
        let messages = try XCTUnwrap(TestJSON.json(transport.lastRequest)["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "读一下这张图")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,AAAB")
    }

    func testTheVisionRouteUsesItsOwnEndpoint() async throws {
        let transport = StubTransport(self.completion(["ok"]))
        let routes = RouteSet(judgment: .preset(.typesafe, apiKey: "k"),
                              reply: .preset(.openRouter, apiKey: "k"),
                              vision: .preset(.qwenCompatible, apiKey: "k"))
        let client = ChatClient(route: try routes.resolve(.vision), transport: transport)
        _ = try await client.readImage(base64PNG: "AA", prompt: "p")
        XCTAssertEqual(transport.lastRequest?.url.absoluteString,
                       "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    func testProbeUsesTheModelsEndpoint() async throws {
        let (client, transport) = try self.client {
            TestJSON.response(["data": [["id": "a"], ["id": "b"]]])
        }
        let result = await client.probe()
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.detail.contains("2 model"))
        XCTAssertEqual(transport.lastRequest?.url.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(transport.lastRequest?.method, "GET")
    }

    func testProbeReportsAnUnreachableRoute() async throws {
        let transport = StubTransport { _ in throw HTTPError.unreachable("no route to host") }
        let route = try RouteSet(judgment: .preset(.typesafe, apiKey: "k"),
                                 reply: .preset(.openRouter, apiKey: "k")).resolve(.reply)
        let result = await ChatClient(route: route, transport: transport).probe()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("no route to host"))
    }
}