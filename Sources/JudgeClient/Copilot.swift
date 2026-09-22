import Foundation

public struct RankedCandidate: Equatable {
    public let text: String
    public let score: Double
    public let confidence: Double
    public let label: String?

    public init(text: String, score: Double, confidence: Double, label: String? = nil) {
        self.text = text; self.score = score; self.confidence = confidence; self.label = label
    }
}

public struct CopilotRun: Equatable {
    public let judgment: Judgment
    /// Ranked best-first by the judged score (same dimension for every candidate), not by model order.
    public let candidates: [RankedCandidate]
    public let escalation: Escalation?
    /// True when this run drafted the candidates itself (the reply route was used).
    public let drafted: Bool
    /// Which backend produced the judgments — `llmJSON` answers are uncalibrated by construction.
    public let backend: JudgmentBackendKind

    public var recommended: RankedCandidate? { candidates.first }
}

/// The product's identity, in one call: **judge first, then write**.
///
/// 1. one request carrying four independent judgments over the reconstructed conversation
///    (intent, risk, reply-now, verify-first) — they run in parallel and cannot see each other;
/// 2. the reply route drafts candidates only when the judgment says a reply is due;
/// 3. a second request scores every candidate on ONE dimension, so the ranking is comparable and
///    code can re-rank or re-threshold without re-running inference;
/// 4. whatever is too flat or too risky is handed back to the user explicitly, never guessed.
public final class Copilot {

    public let policy: JudgmentPolicy
    public let backendKind: JudgmentBackendKind
    private let judge: JudgmentBackend
    private let chat: ChatClient?
    private let draftingSystemPrompt: String

    public init(judgment: JudgmentBackend, replyRoute: ResolvedRoute? = nil,
                transport: HTTPTransport = URLSessionTransport(),
                policy: JudgmentPolicy = JudgmentPolicy(),
                draftingSystemPrompt: String = Copilot.defaultDraftingPrompt) {
        self.policy = policy
        self.backendKind = judgment.kind
        self.judge = judgment
        self.chat = replyRoute.map { ChatClient(route: $0, transport: transport) }
        self.draftingSystemPrompt = draftingSystemPrompt
    }

    public convenience init(judgmentRoute: ResolvedRoute, replyRoute: ResolvedRoute? = nil,
                            transport: HTTPTransport = URLSessionTransport(),
                            policy: JudgmentPolicy = JudgmentPolicy()) {
        let backend: JudgmentBackend = judgmentRoute.preset == .typesafe
            ? JevClient(route: judgmentRoute, transport: transport)
            : LLMJudgeClient(route: judgmentRoute, transport: transport)
        self.init(judgment: backend, replyRoute: replyRoute, transport: transport, policy: policy)
    }

    /// Build from the app's route configuration. The reply route is optional: a typed-judgment-only
    /// setup can judge without one (and then cannot draft).
    public convenience init(routes: RouteSet, transport: HTTPTransport = URLSessionTransport(),
                            policy: JudgmentPolicy = JudgmentPolicy()) throws {
        let judgment = try routes.resolve(.judgment)
        let reply = try? routes.resolve(.reply)
        self.init(judgmentRoute: judgment, replyRoute: reply, transport: transport, policy: policy)
    }

    public static let defaultDraftingPrompt = """
    你是用户本人的聊天助手。根据下面的对话，给出可以直接发送的候选回复。
    要求：站在用户立场、语气自然、不要解释、不要加引号或编号；只能输出候选回复本身。
    """

    /// Build the state the judgments see. Everything factual goes here: the model reasons over the
    /// state it is given, and nothing else.
    public static func state(transcript: String, userFacts: String? = nil,
                             candidates: [String] = []) -> String {
        var out = """
        CONTEXT: 下面这段对话是端上从用户手机截图里重建出来的（用户是「我」）。OCR 可能带来错字或缺字，\
        判断必须容忍这种噪声。

        TRANSCRIPT（按屏幕顺序）:
        \(transcript)
        """
        if let facts = userFacts, !facts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "\n\nUSER FACTS:\n\(facts)"
        }
        if !candidates.isEmpty {
            out += "\n\nCANDIDATE REPLIES the user is considering sending:"
            for (index, text) in candidates.enumerated() {
                out += "\n- `candidate_\(index)`: \(text)"
            }
        }
        return out
    }

    public func run(transcript: String, userFacts: String? = nil,
                    providedCandidates: [String] = [], draftCount: Int = 3,
                    stateOverride: String? = nil) async throws -> CopilotRun {
        let conversationState = stateOverride
            ?? Copilot.state(transcript: transcript, userFacts: userFacts)

        let judgment = try await judge.judgeConversation(state: conversationState, policy: policy)

        var candidates = providedCandidates
        var drafted = false
        if candidates.isEmpty, let chat, draftCount > 0, judgment.shouldReplyNow {
            let reply = try await chat.chat(messages: [.system(draftingSystemPrompt),
                                                       .user(conversationState)],
                                            count: draftCount)
            candidates = reply
            drafted = true
        }

        var ranked: [RankedCandidate] = []
        if !candidates.isEmpty {
            let rankingState = Copilot.state(transcript: transcript, userFacts: userFacts,
                                             candidates: candidates)
            ranked = try await judge.rank(candidates: candidates, state: rankingState, policy: policy)
        }

        return CopilotRun(judgment: judgment, candidates: ranked,
                          escalation: judgment.escalation, drafted: drafted,
                          backend: backendKind)
    }
}