import Foundation
import XCTest
@testable import JudgeClient

/// A transport that answers from a script and records what was asked, so every client behaviour
/// is testable without a network — and so the exact request shape can be asserted.
///
/// Test-only and deliberately unlocked: actions run sequentially and a lock would trip the
/// "unavailable from asynchronous contexts" diagnostic that becomes an error in Swift 6.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private var recorded: [HTTPRequest] = []
    private let responder: (HTTPRequest) throws -> HTTPResponse

    init(responder: @escaping (HTTPRequest) throws -> HTTPResponse) {
        self.responder = responder
    }

    convenience init(_ response: @autoclosure @escaping () -> HTTPResponse) {
        self.init { _ in response() }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.append(request)
        return try responder(request)
    }

    var calls: [HTTPRequest] { recorded }
    var lastRequest: HTTPRequest? { recorded.last }
}

enum TestJSON {
    static func body(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
    static func response(_ object: Any, status: Int = 200,
                         headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: body(object))
    }
    static func raw(_ text: String, status: Int = 200,
                    headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(text.utf8))
    }
    /// The request body as a JSON object, for assertions.
    static func json(_ request: HTTPRequest?) -> [String: Any] {
        guard let data = request?.body,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

extension RouteSet {
    static func typesafe(key: String = "test-key", model: String = "jev-latest") -> RouteSet {
        .single(.preset(.typesafe, apiKey: key, model: model))
    }

    static func withReply(key: String = "test-key") -> RouteSet {
        RouteSet(judgment: .preset(.typesafe, apiKey: key),
                 reply: .preset(.openRouter, apiKey: key),
                 vision: RouteConfig())
    }
}

enum Answers {
    /// The shape the live API returns (verified in Phase 0 against jev-1.13.0).
    static func scam(_ dangerScore: Double = 3.16, replyNow: Double = 0.1,
                     verifyFirst: Double = 0.95, intentConfidence: Double = 1.0,
                     dangerConfidence: Double = 0.82,
                     intent: String = "scam") -> [String: Any] {
        [
            "model": "jev-1.13.0",
            "answers": [
                "intent": ["type": "choice", "choice": intent, "confidence": intentConfidence,
                           "probabilities": ["scam": intent == "scam" ? 1.0 : 0.0,
                                             "work": intent == "work" ? 1.0 : 0.0]],
                "danger": ["type": "score", "score": dangerScore, "confidence": dangerConfidence,
                           "legend": ["3": "高度可疑=高度符合诈骗特征，切勿转账",
                                      "4": "确定诈骗=已可判定为诈骗，立即止损"],
                           "probabilities": ["3": 0.79, "4": 0.19]],
                "reply_now": ["type": "noul", "noul": replyNow],
                "verify_first": ["type": "noul", "noul": verifyFirst],
            ],
            "usage": ["input_tokens": 1560, "output_tokens": 155],
        ]
    }

    static func ranking(_ scores: [Double]) -> [String: Any] {
        var answers: [String: Any] = [:]
        for (index, score) in scores.enumerated() {
            answers["candidate_\(index)"] = [
                "type": "score", "score": score, "confidence": 0.9,
                "legend": ["4": "既守住底线又给对方留了体面的台阶"],
                "probabilities": ["4": 0.9],
            ]
        }
        return ["model": "jev-1.13.0", "answers": answers]
    }
}