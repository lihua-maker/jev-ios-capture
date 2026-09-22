import XCTest
@testable import JudgeClient

final class RouteResolutionTests: XCTestCase {

    func testPresetDefaultsAndEndpointPaths() throws {
        let typesafe = try RouteSet.single(.preset(.typesafe, apiKey: "k")).resolve(.judgment)
        XCTAssertEqual(typesafe.judgmentURL.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(typesafe.modelsURL.absoluteString, "https://api.typesafe.ai/v1/models")
        XCTAssertNil(typesafe.chatURL, "TypeSafe serves typed judgments, not chat completions")
        XCTAssertEqual(typesafe.model, "jev-latest")

        let openRouter = try RouteSet.single(.preset(.openRouter, apiKey: "k")).resolve(.judgment)
        XCTAssertEqual(openRouter.chatURL?.absoluteString,
                       "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(openRouter.modelsURL.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(openRouter.model, "deepseek/deepseek-chat-v3.1")

        let deepSeek = try RouteSet.single(.preset(.deepSeek, apiKey: "k")).resolve(.reply)
        XCTAssertEqual(deepSeek.chatURL?.absoluteString,
                       "https://api.deepseek.com/v1/chat/completions")

        let qwen = try RouteSet.single(.preset(.qwenCompatible, apiKey: "k")).resolve(.reply)
        XCTAssertEqual(qwen.chatURL?.absoluteString,
                       "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    func testTrailingSlashInACustomBaseURLDoesNotDoubleUp() throws {
        let config = RouteConfig(preset: .custom, baseURL: URL(string: "https://x.test/v1/")!,
                                 apiKey: "k", model: "m")
        let route = try RouteSet.single(config).resolve(.reply)
        XCTAssertEqual(route.chatURL?.absoluteString, "https://x.test/v1/chat/completions")
    }

    func testBlankRoutesInheritKeyAddressAndModelFromAChatCapableJudgmentRoute() throws {
        // v1.3: "只有一把密钥也够用" — one key is enough.
        let routes = RouteSet(judgment: .preset(.openRouter, apiKey: "only-key"),
                              reply: RouteConfig(), vision: RouteConfig())
        let reply = try routes.resolve(.reply)
        XCTAssertEqual(reply.apiKey, "only-key")
        XCTAssertEqual(reply.baseURL.absoluteString, "https://openrouter.ai/api/v1")
        XCTAssertEqual(reply.model, "deepseek/deepseek-chat-v3.1")
    }

    func testTypeSafeOnlySetupDoesNotPointTheReplyRouteAtATypedEndpoint() {
        // Inheriting the typed-judgment address for chat completions would produce a confusing 404
        // at send time; an explicit configuration error is the honest outcome.
        let routes = RouteSet.single(.preset(.typesafe, apiKey: "k"))
        XCTAssertThrowsError(try routes.resolve(.reply)) { error in
            XCTAssertEqual(error as? RouteConfigurationError, .missingBaseURL(.reply))
        }
        // …but the key still inherits, so configuring only an address is enough.
        let configured = RouteSet(judgment: .preset(.typesafe, apiKey: "k"),
                                  reply: RouteConfig(preset: .deepSeek))
        XCTAssertEqual(try configured.resolve(.reply).apiKey, "k")
    }

    func testMissingKeyIsReportedPerRoute() {
        let routes = RouteSet.single(.preset(.typesafe, apiKey: ""))
        XCTAssertThrowsError(try routes.resolve(.judgment)) { error in
            XCTAssertEqual(error as? RouteConfigurationError, .missingKey(.judgment))
        }
    }

    func testVisionRouteResolvesIndependentlyOfTheReplyRoute() throws {
        let routes = RouteSet(judgment: .preset(.typesafe, apiKey: "k"),
                              reply: .preset(.openRouter, apiKey: "k"),
                              vision: .preset(.qwenCompatible, apiKey: "k"))
        let vision = try routes.resolve(.vision)
        XCTAssertEqual(vision.preset, .qwenCompatible)
        XCTAssertEqual(vision.chatURL?.absoluteString,
                       "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        XCTAssertEqual(vision.model, "qwen-plus")
    }

    func testEveryPresetDeclaresItsCapability() {
        XCTAssertFalse(RoutePreset.typesafe.isChatCapable)
        XCTAssertEqual(RoutePreset.typesafe.defaultBaseURL?.absoluteString, "https://api.typesafe.ai")
        for preset in RoutePreset.allCases where preset != .custom {
            XCTAssertNotNil(preset.defaultBaseURL, "\(preset) needs a default address")
            XCTAssertNotNil(preset.defaultModel, "\(preset) needs a default model")
        }
        XCTAssertTrue(RoutePreset.openRouter.isChatCapable)
        XCTAssertTrue(RoutePreset.deepSeek.isChatCapable)
        XCTAssertTrue(RoutePreset.qwenCompatible.isChatCapable)
    }
}