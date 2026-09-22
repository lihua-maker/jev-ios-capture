import XCTest
import ChatCapture
import JudgeClient
@testable import CopilotKit

/// A transport standing in for the network, so the whole app-side path is testable offline.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private var recorded: [HTTPRequest] = []
    private let responder: (HTTPRequest) throws -> HTTPResponse

    init(responder: @escaping (HTTPRequest) throws -> HTTPResponse) { self.responder = responder }

    convenience init(_ response: @autoclosure @escaping () -> HTTPResponse) {
        self.init { _ in response() }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.append(request)
        return try responder(request)
    }

    var calls: [HTTPRequest] { recorded }
}

enum Fake {
    static func judgment(danger: Double = 3.16, replyNow: Double = 0.9,
                         verify: Double = 0.1) -> HTTPResponse {
        let body: [String: Any] = [
            "model": "jev-1.13.0",
            "answers": [
                "intent": ["type": "choice", "choice": "scam", "confidence": 1.0],
                "danger": ["type": "score", "score": danger, "confidence": 0.9,
                           "legend": ["3": "高度可疑=高度符合诈骗特征，切勿转账"],
                           "probabilities": ["3": 0.8]],
                "reply_now": ["type": "noul", "noul": replyNow],
                "verify_first": ["type": "noul", "noul": verify],
            ],
        ]
        return HTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    static func ranking(_ scores: [Double]) -> HTTPResponse {
        var answers: [String: Any] = [:]
        for (index, score) in scores.enumerated() {
            answers["candidate_\(index)"] = ["type": "score", "score": score, "confidence": 0.9,
                                             "legend": ["4": "既守住底线又给对方留了体面的台阶"],
                                             "probabilities": ["4": 0.9]]
        }
        let body: [String: Any] = ["model": "jev-1.13.0", "answers": answers]
        return HTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    static func scripted() -> ScriptedTransport {
        ScriptedTransport { request in
            let questions = (try? JSONSerialization.jsonObject(with: request.body ?? Data())
                as? [String: Any])?["questions"] as? [String: Any] ?? [:]
            let isRanking = questions.keys.contains { $0.hasPrefix("candidate_") }
            return isRanking ? ranking([1.0, 3.5]) : judgment()
        }
    }
}

private func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("jev-tests-\(UUID().uuidString)")
        .appendingPathComponent(name)
}

// MARK: - clipboard handoff

final class ClipboardHandoffTests: XCTestCase {
    func testRoundTrip() {
        let encoded = ClipboardHandoff.encode("好的，我看看")
        XCTAssertEqual(ClipboardHandoff.decode(encoded), "好的，我看看")
    }

    func testUnrelatedClipboardContentIsRejected() {
        XCTAssertNil(ClipboardHandoff.decode("随便复制的一段话"))
        XCTAssertNil(ClipboardHandoff.decode(nil))
        XCTAssertNil(ClipboardHandoff.decode(ClipboardHandoff.marker), "an empty body is not a suggestion")
    }
}

// MARK: - knowledge

final class KnowledgeStoreTests: XCTestCase {
    private func store() -> KnowledgeStore {
        let url = tempURL("knowledge.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return KnowledgeStore(fileURL: url)
    }

    func testContactMatchesByAlias() {
        let store = self.store()
        store.upsert(Contact(name: "李经理", aliases: ["老李", "Lee"], relation: "上级",
                             notes: "公司客户部"))
        XCTAssertEqual(store.contact(matching: "老李")?.name, "李经理")
        XCTAssertEqual(store.contact(matching: "李经理")?.name, "李经理")
        XCTAssertNil(store.contact(matching: "王姐"))
    }

    func testFactsIncludeTheContactAndOnlyRelevantNotes() {
        let store = self.store()
        store.upsert(Contact(name: "李经理", aliases: [], relation: "上级", notes: "客户部负责人"))
        store.upsert(Note(title: "垫款规定", body: "任何垫款都要走财务审批", tags: ["垫款"]))
        store.upsert(Note(title: "报销流程", body: "先审批后报销", tags: ["报销"]))
        store.upsert(Note(title: "常驻提醒", body: "注意保护个人信息", pinned: true))

        let facts = store.facts(contactName: "李经理", transcript: "帮我垫一笔款，明天还你")
        XCTAssertTrue(facts.contains("对方身份：李经理"))
        XCTAssertTrue(facts.contains("关系：上级"))
        XCTAssertTrue(facts.contains("垫款规定"), "a note tagged with a word in the transcript must attach")
        XCTAssertTrue(facts.contains("常驻提醒"), "pinned notes always attach")
        XCTAssertFalse(facts.contains("报销流程"), "an unrelated tagged note must not attach")
    }

    func testFactsSurviveAReload() {
        let url = tempURL("knowledge.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let first = KnowledgeStore(fileURL: url)
        first.upsert(Contact(name: "王姐", relation: "同事"))
        first.upsert(Note(title: "合同", body: "三处修改", tags: ["合同"]))

        let second = KnowledgeStore(fileURL: url)
        XCTAssertEqual(second.contacts.count, 1)
        XCTAssertEqual(second.notes.first?.title, "合同")
        XCTAssertTrue(second.facts(contactName: "王姐", transcript: "合同改好了吗").contains("合同"))
    }

    func testSavingAContactFromAConversationDoesNotDuplicate() {
        let store = self.store()
        store.saveContact(fromSender: "赵工", transcript: "帮我看下超时")
        store.saveContact(fromSender: "赵工", transcript: "帮我看下超时")
        XCTAssertEqual(store.contacts.count, 1)
        store.saveContact(fromSender: "them", transcript: "x")
        store.saveContact(fromSender: "me", transcript: "x")
        XCTAssertEqual(store.contacts.count, 1, "unnamed other party and the user are not contacts")
    }

    func testFactsAreBounded() {
        let store = self.store()
        for index in 0..<50 {
            store.upsert(Note(title: "长笔记\(index)", body: String(repeating: "内容", count: 200),
                              pinned: true))
        }
        let facts = store.facts(contactName: nil, transcript: "x")
        XCTAssertLessThanOrEqual(facts.count, 1300, "facts handed to the model must stay bounded")
    }
}

// MARK: - settings

final class CopilotSettingsTests: XCTestCase {
    func testStoredRouteMapsToARouteConfig() {
        let stored = StoredRoute(preset: .qwenCompatible, baseURL: "", model: "qwen-max",
                                 keyAccount: "route.vision")
        let config = stored.config()
        XCTAssertEqual(config.preset, .qwenCompatible)
        XCTAssertEqual(config.baseURL?.absoluteString,
                       "https://dashscope.aliyuncs.com/compatible-mode/v1",
                       "an empty field falls back to the preset default")
        XCTAssertEqual(config.model, "qwen-max")
    }

    func testOverridesWinOverPresetDefaults() {
        let stored = StoredRoute(preset: .custom, baseURL: "https://example.test/v1",
                                 model: "my-model", keyAccount: "route.reply")
        let config = stored.config()
        XCTAssertEqual(config.baseURL?.absoluteString, "https://example.test/v1")
        XCTAssertEqual(config.model, "my-model")
    }

    func testPolicyFollowsTheStoredThresholds() {
        var settings = CopilotSettings()
        settings.dangerAlert = 1.5
        settings.lowConfidence = 0.7
        settings.replyNowThreshold = 0.25
        XCTAssertEqual(settings.policy.dangerAlert, 1.5)
        XCTAssertEqual(settings.policy.lowConfidence, 0.7)
        XCTAssertEqual(settings.policy.replyNowThreshold, 0.25)
    }

    func testSettingsRoundTrip() {
        var settings = CopilotSettings()
        settings.judgment.model = "jev-preview"
        settings.dangerAlert = 1.1
        let data = try? JSONEncoder().encode(settings)
        let restored = data.flatMap { try? JSONDecoder().decode(CopilotSettings.self, from: $0) }
        XCTAssertEqual(restored?.judgment.model, "jev-preview")
        XCTAssertEqual(restored?.dangerAlert, 1.1)
        XCTAssertEqual(restored?.reply.preset, RoutePreset.openRouter.rawValue)
    }
}

// MARK: - analysis handoff

final class AnalysisStoreTests: XCTestCase {
    private func store() -> AnalysisStore {
        let url = tempURL("latest-analysis.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return AnalysisStore(fileURL: url)
    }

    func testRoundTripAndFreshness() {
        let store = self.store()
        let snapshot = AnalysisSnapshot(transcript: "我: 在的", contactName: "李经理",
                                        intent: "scam", danger: 3.16, dangerLabel: "高度可疑",
                                        replyNowProbability: 0.9, verifyProbability: 0.95,
                                        escalationSummary: "建议先核实",
                                        candidates: [.init(id: 0, text: "回复", score: 4,
                                                           confidence: 0.9, label: nil)],
                                        backend: "typesafeTyped", model: "jev-latest")
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)

        let stale = Date().addingTimeInterval(-AnalysisStore.freshness - 1)
        store.save(AnalysisSnapshot(createdAt: stale, transcript: "x", contactName: nil, intent: nil,
                                    danger: nil, dangerLabel: nil, replyNowProbability: nil,
                                    verifyProbability: nil, escalationSummary: nil, candidates: [],
                                    backend: "typesafeTyped", model: nil))
        XCTAssertNil(store.loadFresh(), "a stale suggestion must not be offered in the keyboard")
        XCTAssertNotNil(store.load())
    }

    func testSnapshotMapsTheRunIntoKeyboardFriendlyText() async throws {
        let routes = RouteSet(judgment: .preset(.typesafe, apiKey: "k"),
                              reply: .preset(.openRouter, apiKey: "k"))
        let copilot = Copilot(judgmentRoute: try routes.resolve(.judgment),
                              replyRoute: try routes.resolve(.reply),
                              transport: Fake.scripted())
        let run = try await copilot.run(transcript: "对方: 帮我垫一笔款",
                                        providedCandidates: ["不方便走流程", "好的我转给您"])
        let snapshot = AnalysisSnapshot.from(run, transcript: "对方: 帮我垫一笔款",
                                             contactName: "李经理", model: "jev-latest")
        XCTAssertEqual(snapshot.intent, "scam")
        XCTAssertEqual(snapshot.candidates.first?.text, "好的我转给您", "0.9 confidence beats 0.1 here")
        XCTAssertEqual(snapshot.candidates.count, 2)
        XCTAssertEqual(snapshot.escalationSummary, "风险等级 3：高度可疑=高度符合诈骗特征，切勿转账")
        XCTAssertEqual(snapshot.contactName, "李经理")
        XCTAssertEqual(snapshot.backend, "typesafeTyped")
    }
}

// MARK: - the app's service

final class CopilotServiceTests: XCTestCase {

    private func service(transport: HTTPTransport) -> CopilotService {
        var settings = CopilotSettings()
        settings.useKnowledge = false
        settings.judgment = StoredRoute(preset: .typesafe, baseURL: "https://api.typesafe.ai",
                                        model: "jev-latest", keyAccount: "test.key")
        settings.reply = StoredRoute(preset: .openRouter, baseURL: "https://openrouter.ai/api/v1",
                                     model: "m", keyAccount: "test.key")
        // Keys come from a stub here: the real provider reads the keychain, which CI runners
        // cannot be relied on for, and the keychain is not what these tests are about.
        let analysisURL = tempURL("latest-analysis.json")
        try? FileManager.default.createDirectory(at: analysisURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return CopilotService(settings: settings,
                              knowledge: KnowledgeStore(fileURL: tempURL("k.json")),
                              analysisStore: AnalysisStore(fileURL: analysisURL),
                              transport: transport,
                              keyProvider: { _ in "test-key" })
    }

    func testAnalyzeTextProducesAndStoresASnapshot() async throws {
        let service = self.service(transport: Fake.scripted())
        let outcome = try await service.analyze(transcript: "对方(李经理): 帮我垫一笔款",
                                                contactName: "李经理",
                                                providedCandidates: ["不方便", "好我转"])
        XCTAssertEqual(outcome.run.judgment.intent, "scam")
        XCTAssertEqual(outcome.snapshot.candidates.count, 2)
        XCTAssertNotNil(outcome.snapshot.candidates.first?.text)
    }

    func testTranscriptFormattingKeepsWhoSaidWhat() {
        let bubbles = [
            Bubble(side: .them, sender: "王姐", text: "合同改好了吗", quote: "", y: 0),
            Bubble(side: .them, sender: "them", text: "在忙吗", quote: "", y: 10),
            Bubble(side: .me, sender: "me", text: "今天下午六点前发您", quote: "李经理：方案", y: 20),
        ]
        let transcript = CopilotService.transcript(from: bubbles)
        XCTAssertEqual(transcript, """
        对方(王姐): 合同改好了吗
        对方: 在忙吗
        我: ［引用 李经理：方案］今天下午六点前发您
        """)
    }

    func testProbeReportsAConfigurationProblemInsteadOfCrashing() async {
        var settings = CopilotSettings()
        settings.reply = StoredRoute(preset: .custom, baseURL: "", model: "", keyAccount: "missing.key")
        let service = CopilotService(settings: settings,
                                     knowledge: KnowledgeStore(fileURL: tempURL("k.json")),
                                     analysisStore: AnalysisStore(fileURL: tempURL("a.json")),
                                     transport: Fake.scripted())
        let result = await service.probe(.reply)
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.detail.isEmpty, "the user must get a reason, not a silent failure")
    }
}