import Foundation

// MARK: - Response

/// The typed answers the judgment API returns. Every value carries its own probability
/// distribution; confidence measures how concentrated that distribution is, NOT permission to act.
public struct JudgmentResponse: Decodable, Equatable {
    public struct Usage: Decodable, Equatable {
        public let inputTokens: Int?
        public let outputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    public struct Answer: Decodable, Equatable {
        public let type: String
        public let noul: Double?
        public let score: Double?
        public let choice: String?
        public let confidence: Double?
        public let probabilities: [String: Double]?
        public let legend: [String: String]?
    }

    public let model: String?
    public let answers: [String: Answer]
    public let usage: Usage?

    // MARK: typed accessors

    /// Probability of "yes" for a `.noul` question.
    public func noul(_ name: String) -> Double? { answers[name]?.noul }

    /// `true`/`false` at a threshold, with the caller's policy — never a built-in default.
    public func bool(_ name: String, atLeast threshold: Double) -> Bool? {
        noul(name).map { $0 >= threshold }
    }

    public func choice(_ name: String) -> Answer? { answers[name] }

    public func score(_ name: String) -> Answer? { answers[name] }

    /// The description of the level a score landed on (the API echoes `legend` for this).
    public func scoreLabel(_ name: String) -> String? {
        guard let a = answers[name], let s = a.score, let legend = a.legend else { return nil }
        let level = String(Int(s.rounded()))
        return legend[level]
    }

    /// Probability of the level a score landed on.
    public func scorePeakProbability(_ name: String) -> Double? {
        guard let a = answers[name], let s = a.score, let probs = a.probabilities else { return nil }
        return probs[String(Int(s.rounded()))]
    }

    public func confidence(_ name: String) -> Double? { answers[name]?.confidence }
}

// MARK: - What the copilot asks

/// Thresholds are policy, not model properties: set them from your own data and consequences.
public struct JudgmentPolicy: Equatable {
    /// Below this, hand the decision to the user instead of acting on it.
    public var lowConfidence: Double
    /// Risk level (on the danger scale) that must be surfaced prominently.
    public var dangerAlert: Double
    /// How strongly "reply now" must hold before the copilot leads with a reply.
    public var replyNowThreshold: Double
    /// The single dimension candidates are scored on, so their scores stay comparable.
    public var candidateDimension: String

    public init(lowConfidence: Double = 0.5,
                dangerAlert: Double = 2.5,
                replyNowThreshold: Double = 0.5,
                candidateDimension: String =
                    "回复是否既守住底线（不垫款、不绕开公司流程、不打私人账户）又不无谓激怒对方") {
        self.lowConfidence = lowConfidence
        self.dangerAlert = dangerAlert
        self.replyNowThreshold = replyNowThreshold
        self.candidateDimension = candidateDimension
    }
}

public enum JudgmentPack {

    public static let dangerLevels = [
        "安全=正常对话，可以按常规处理",
        "需留意=略有异常但不影响基本判断",
        "可疑=有多处异常，应先核实再行动",
        "高度可疑=高度符合诈骗特征，切勿转账",
        "确定诈骗=已可判定为诈骗，立即止损",
    ]

    /// The four judgments the copilot runs on one conversation, asked together because they are
    /// independent and run in parallel. Each is one narrow, coherent question.
    public static func copilotQuestions(policy: JudgmentPolicy) throws -> [Question] {
        [
            try .choice(name: "intent",
                        instructions: "对方这一整串话最可能的真实意图是什么？",
                        options: [
                            .init("scam", "冒充身份或编织理由骗取钱款的诈骗/社交工程"),
                            .init("work", "真实的紧急工作或事务请求"),
                            .init("chat", "日常闲聊，没有具体诉求"),
                            .init("pressure", "情绪化施压但无明显恶意或金钱诉求"),
                        ]),
            try .score(name: "danger",
                       instructions: "这条对话对用户的资金/财产安全风险等级",
                       levels: dangerLevels),
            try .noul(name: "reply_now",
                      instructions: "用户是否应当立刻回复对方，而不是先去做身份核实？"),
            try .noul(name: "verify_first",
                      instructions: "是否应当先通过聊天以外的渠道（电话或当面）核实对方身份，再考虑任何金钱往来？"),
        ]
    }

    /// One score question per candidate, on the SAME dimension, so the scores are comparable and
    /// code can re-rank without re-running inference.
    public static func candidateQuestions(_ candidates: [String],
                                          policy: JudgmentPolicy) throws -> [Question] {
        try candidates.enumerated().map { index, _ in
            try .score(name: "candidate_\(index)",
                       instructions: "候选回复 \(index)（见 state 中的 `candidate_\(index)`）在这一维度上的表现：\(policy.candidateDimension)",
                       levels: [
                           "完全达不到要求：直接答应对方的要求",
                           "达不到要求且留下可被利用的口子",
                           "立场模糊：既不答应也不拒绝，容易被继续施压",
                           "基本达到要求，但语气或措辞可能让对方不快",
                           "既守住底线又给对方留了体面的台阶",
                       ])
        }
    }
}

/// The judgment the copilot makes about one conversation.
public struct Judgment: Equatable {
    public let policy: JudgmentPolicy
    public let response: JudgmentResponse

    public init(policy: JudgmentPolicy, response: JudgmentResponse) {
        self.policy = policy; self.response = response
    }

    public var intent: String? { response.answers["intent"]?.choice }
    public var intentConfidence: Double? { response.confidence("intent") }
    public var danger: Double? { response.answers["danger"]?.score }
    public var dangerLabel: String? { response.scoreLabel("danger") }
    public var replyNowProbability: Double? { response.noul("reply_now") }
    public var verifyProbability: Double? { response.noul("verify_first") }

    public var shouldReplyNow: Bool {
        (replyNowProbability ?? 0) >= policy.replyNowThreshold
    }

    public var needsVerification: Bool {
        (verifyProbability ?? 0) >= 0.5
    }

    /// True when any answer is too flat to act on. A choice/score confidence near 0.5 means the
    /// distribution is spread over alternatives — it is not "medium intensity". A noul answer has no
    /// distribution to concentrate, so its absent confidence counts as settled here.
    public var isLowConfidence: Bool {
        response.answers.values.contains { ($0.confidence ?? 1) < policy.lowConfidence }
    }

    /// The most severe reason to hand this conversation back to the user, if any.
    public var escalation: Escalation? {
        if let d = danger, d >= policy.dangerAlert {
            return .highRisk(level: Int(d.rounded()), label: dangerLabel ?? "")
        }
        if needsVerification { return .verificationRequired }
        if isLowConfidence {
            // Same rule as `isLowConfidence`: an answer without a distribution cannot be the
            // least-confident one, or the two verdicts would disagree about which question is at
            // fault.
            let (name, conf) = response.answers
                .map { ($0.key, $0.value.confidence ?? 1) }
                .min { $0.1 < $1.1 } ?? ("", 1)
            return .lowConfidence(question: name, confidence: conf)
        }
        return nil
    }
}

public enum Escalation: Equatable {
    case highRisk(level: Int, label: String)
    case verificationRequired
    case lowConfidence(question: String, confidence: Double)
}