import Foundation

public struct ProbeResult: Equatable {
    public let ok: Bool
    public let detail: String
    public let millis: Int?
}

/// The typed-judgment client (TypeSafe System One / Jev).
///
/// Wire contract, mirrored from the reference CLI and verified against the live API in Phase 0:
///   POST {base}/v1/systemone   {"state": …, "model": …, "questions": {name: {type, instructions, criteria}}}
///   GET  {base}/v1/models
/// Headers: `Authorization: Bearer <key>`, `Content-Type: application/json`, `Accept: application/json`.
public final class JevClient: JudgmentBackend {

    public let kind: JudgmentBackendKind = .typesafeTyped
    public let route: ResolvedRoute
    private let transport: HTTPTransport

    public init(route: ResolvedRoute, transport: HTTPTransport = URLSessionTransport()) {
        self.route = route
        self.transport = transport
    }

    /// `JudgmentBackend` conformance.
    public func judge(state: String, questions: [Question]) async throws -> JudgmentResponse {
        try await judge(state: state, questions: questions, model: nil)
    }

    private var headers: [String: String] {
        ["Authorization": "Bearer \(route.apiKey)",
         "Content-Type": "application/json",
         "Accept": "application/json"]
    }

    public func judge(state: String, questions: [Question],
                      model: String? = nil) async throws -> JudgmentResponse {
        guard !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPError.malformedResponse("state is empty — the model has nothing to judge on")
        }
        let body: [String: Any] = [
            "state": state,
            "model": model ?? route.model,
            "questions": QuestionsPayload(questions).jsonObject,
        ]
        let request = HTTPRequest(method: "POST", url: route.judgmentURL, headers: headers,
                                  body: try JSONSerialization.data(withJSONObject: body))
        let response = try await transport.send(request)
        do {
            return try JSONDecoder().decode(JudgmentResponse.self, from: response.body)
        } catch {
            throw HTTPError.malformedResponse("cannot decode answers: \(error.localizedDescription)")
        }
    }

    /// The judgments the copilot runs, typed and policy-driven — available on every backend.
    public func models() async throws -> [String] {
        let response = try await transport.send(
            HTTPRequest(method: "GET", url: route.modelsURL, headers: headers, body: nil, timeout: 20))
        guard let obj = response.json as? [String: Any] else {
            throw HTTPError.malformedResponse("models listing is not a JSON object")
        }
        let list = (obj["models"] as? [[String: Any]]) ?? (obj["data"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["name"] as? String) ?? ($0["id"] as? String) }
    }

    /// The one-tap connectivity test each route has in the app: never throws, always explains.
    public func probe() async -> ProbeResult {
        let started = Date()
        do {
            let names = try await models()
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            let detail = names.isEmpty ? "reachable, but the key exposes no models"
                                      : "reachable · \(names.count) model(s): \(names.prefix(3).joined(separator: ", "))"
            return ProbeResult(ok: true, detail: detail, millis: millis)
        } catch let error as HTTPError {
            return ProbeResult(ok: false, detail: error.description,
                               millis: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return ProbeResult(ok: false, detail: error.localizedDescription,
                               millis: Int(Date().timeIntervalSince(started) * 1000))
        }
    }
}