import Foundation

/// Which kind of judgment backend answered. The distinction is part of the result, not a hidden
/// implementation detail: only `typesafeTyped` returns calibrated typed answers.
public enum JudgmentBackendKind: String, Equatable {
    case typesafeTyped
    case llmJSON   // a chat model prompted for the same JSON shape — typed but NOT calibrated
}

public protocol JudgmentBackend {
    var kind: JudgmentBackendKind { get }
    func judge(state: String, questions: [Question]) async throws -> JudgmentResponse
    func probe() async -> ProbeResult
}

extension JudgmentBackend {
    /// The four judgments the copilot runs, asked together (they are independent and run in
    /// parallel; they cannot see each other's answers).
    public func judgeConversation(state: String,
                                  policy: JudgmentPolicy = JudgmentPolicy()) async throws -> Judgment {
        let response = try await judge(state: state,
                                       questions: try JudgmentPack.copilotQuestions(policy: policy))
        return Judgment(policy: policy, response: response)
    }

    /// Rank candidates by scoring each on the SAME dimension in one request, so the scores are
    /// comparable and code can re-rank or re-threshold without re-running inference.
    public func rank(candidates: [String], state: String,
                     policy: JudgmentPolicy = JudgmentPolicy()) async throws -> [RankedCandidate] {
        guard !candidates.isEmpty else { return [] }
        let questions = try JudgmentPack.candidateQuestions(candidates, policy: policy)
        let response = try await judge(state: state, questions: questions)
        return candidates.enumerated().map { index, text in
            let answer = response.answers["candidate_\(index)"]
            return RankedCandidate(text: text,
                                   score: answer?.score ?? 0,
                                   confidence: answer?.confidence ?? 0,
                                   label: response.scoreLabel("candidate_\(index)"))
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.confidence > rhs.confidence : lhs.score > rhs.score
        }
    }
}

/// Judgment obtained by prompting a chat model for the same JSON contract.
///
/// This exists because the app must keep working with only an OpenRouter/DeepSeek/Qwen key. It is
/// NOT equivalent to the typed API: the answers are uncalibrated, so every answer that omits
/// `confidence` is recorded with confidence 0 and therefore escalates to the user instead of
/// being acted on. Prefer the typed backend whenever a key for it exists.
public final class LLMJudgeClient: JudgmentBackend {

    public let kind: JudgmentBackendKind = .llmJSON
    public let route: ResolvedRoute
    private let chat: ChatClient

    public init(route: ResolvedRoute, transport: HTTPTransport = URLSessionTransport()) {
        self.route = route
        self.chat = ChatClient(route: route, transport: transport)
    }

    public static let systemPrompt = """
    You are a decision function, not a chat assistant. Given STATE and QUESTIONS, answer each
    question with a typed judgment and reply with ONE JSON object and nothing else:
    {"answers": {"<question name>": {"type": "noul"|"score"|"choice",
                                     "noul": <0..1>, "score": <level index>, "choice": "<option key>",
                                     "confidence": <0..1>}}}
    Rules: use the criteria exactly as given; for score, answer with the LEVEL INDEX that best
    describes the situation; for choice, answer with an option key; never explain, never add text
    outside the JSON object; if the evidence is ambiguous, give a low confidence rather than a
    confident wrong answer.
    """

    public func judge(state: String, questions: [Question]) async throws -> JudgmentResponse {
        let payload = QuestionsPayload(questions).jsonObject
        let questionsJSON = (try? JSONSerialization.data(withJSONObject: payload,
                                                        options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let prompt = """
        STATE:
        \(state)

        QUESTIONS (name -> {type, instructions, criteria}):
        \(questionsJSON)

        Answer with the JSON object described in the system message.
        """
        let texts = try await chat.chat(messages: [.system(LLMJudgeClient.systemPrompt),
                                                  .user(prompt)], count: 1)
        guard let object = LLMJudgeClient.firstJSONObject(in: texts[0]),
              let data = try? JSONSerialization.data(withJSONObject: object),
              var decoded = try? JSONDecoder().decode(JudgmentResponse.self, from: data) else {
            throw HTTPError.malformedResponse("the chat backend did not return the agreed JSON shape")
        }
        // Uncalibrated answers must not look confident: absent confidence becomes 0, which the
        // policy then escalates. A made-up confidence would be worse than none.
        decoded = decoded.withConfidenceDefaults()
        return decoded
    }

    public func probe() async -> ProbeResult { await chat.probe() }

    /// Pull the first balanced JSON object out of a model's reply (models like to wrap it in prose
    /// or code fences even when told not to).
    static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let candidate = String(text[start...index])
                    return (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) as? [String: Any]
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

extension JudgmentResponse {
    /// Fill absent confidences with 0 (explicitly uncalibrated) and normalise field types.
    func withConfidenceDefaults() -> JudgmentResponse {
        var answers: [String: Answer] = [:]
        for (name, a) in self.answers {
            answers[name] = Answer(type: a.type, noul: a.noul, score: a.score, choice: a.choice,
                                   confidence: a.confidence ?? 0,
                                   probabilities: a.probabilities, legend: a.legend)
        }
        return JudgmentResponse(model: model, answers: answers, usage: usage)
    }
}