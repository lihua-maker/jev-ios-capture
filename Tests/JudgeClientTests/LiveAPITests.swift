import XCTest
@testable import JudgeClient

/// Opt-in live checks. They run only when a key is present, so CI stays green without secrets —
/// and when the key *is* configured, the same verdict Phase 0 measured from the Python CLI has to
/// come back out of the Swift client.
///
///     TYPESAFE_API_KEY=… swift test --filter LiveAPITests
final class LiveAPITests: XCTestCase {

    private var key: String? {
        let value = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? ""
        return value.isEmpty ? nil : value
    }

    /// The conversation the whole spike is built around: a "manager" who switched numbers and wants
    /// the user to advance money to a private account.
    private let scamTranscript = """
    对方(李经理): 小陈，在吗？
    对方(李经理): 有个急事，今晚必须处理完
    对方(李经理): 你手上的活先放一放
    对方(李经理): 对了，我换号了，之前那个不用了
    对方(李经理): 能不能先帮我垫一笔款，2980，明天财务走完流程就还你
    对方(李经理): 走我的私人账户就行，别跟其他人说
    我: 李经理您好，具体是什么事？
    我: 垫款的话我需要走一下审批流程
    对方(李经理): 流程太慢了，你先垫上，我这边给你担保
    """

    private let holdsTheLine = "李经理，垫款我这边不太方便，麻烦走一下公司流程，我配合您把材料准备好。"
    private let paysUp = "好的李经理，2980我马上转给您，私户还是原来的账号吗？"
    private let verifiesFirst = "李经理，这事我得先跟您电话确认一下，方便现在打给您吗？"

    func testLiveJudgmentReproducesThePhase0Verdict() async throws {
        guard let key else { throw XCTSkip("TYPESAFE_API_KEY not set — live check skipped") }

        let copilot = try Copilot(routes: RouteSet.single(.preset(.typesafe, apiKey: key)))
        let run = try await copilot.run(
            transcript: scamTranscript,
            userFacts: "用户是普通员工，没有代公司垫款的权限；公司要求报销走财务审批并有记录。",
            providedCandidates: [holdsTheLine, paysUp, verifiesFirst])

        XCTAssertEqual(run.backend, .typesafeTyped)
        XCTAssertEqual(run.judgment.intent, "scam", "Phase 0 measured p=1.00 for this transcript")
        XCTAssertGreaterThanOrEqual(run.judgment.danger ?? 0, 2.5)
        XCTAssertGreaterThanOrEqual(run.judgment.verifyProbability ?? 0, 0.5)
        XCTAssertLessThan(run.judgment.replyNowProbability ?? 1, 0.5)

        XCTAssertEqual(run.recommended?.text, holdsTheLine,
                       "the boundary-holding reply must outrank the one that pays")
        XCTAssertEqual(run.candidates.last?.text, paysUp)
        guard case .highRisk? = run.escalation else {
            return XCTFail("a scam transcript must escalate, got \(String(describing: run.escalation))")
        }
    }

    func testLiveBenignConversationDoesNotCryWolf() async throws {
        guard let key else { throw XCTSkip("TYPESAFE_API_KEY not set — live check skipped") }
        let copilot = try Copilot(routes: RouteSet.single(.preset(.typesafe, apiKey: key)))
        let run = try await copilot.run(transcript: """
        对方(赵工): 生产环境的告警我看了，是订单服务的连接池被打满了，我先把最大连接数调高临时顶一下
        我: 好，那我把监控面板的阈值也调一下，免得半夜又告警
        对方(赵工): 行
        """)
        XCTAssertLessThan(run.judgment.danger ?? 1, 2.5, "ordinary work talk must not be flagged as risk")
        guard case .highRisk? = run.escalation else { return }
        XCTFail("benign work chat escalated as high risk")
    }

    func testLiveConnectivityProbe() async throws {
        guard let key else { throw XCTSkip("TYPESAFE_API_KEY not set — live check skipped") }
        let route = try RouteSet.single(.preset(.typesafe, apiKey: key)).resolve(.judgment)
        let probe = await JevClient(route: route).probe()
        XCTAssertTrue(probe.ok, probe.detail)
        XCTAssertNotNil(probe.millis)
    }
}