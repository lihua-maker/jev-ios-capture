import Foundation

public struct ChatMessage: Equatable {
    public enum Content: Equatable {
        case text(String)
        case parts([Part])
    }

    public struct Part: Codable, Equatable {
        public struct ImageURL: Codable, Equatable {
            public let url: String
            public init(url: String) { self.url = url }
        }
        public let type: String
        public let text: String?
        public let imageURL: ImageURL?
        enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }
        public init(type: String, text: String? = nil, imageURL: ImageURL? = nil) {
            self.type = type; self.text = text; self.imageURL = imageURL
        }
    }

    public let role: String
    public let content: Content

    public init(role: String, content: Content) {
        self.role = role; self.content = content
    }

    public static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: "system", content: .text(text))
    }
    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: "user", content: .text(text))
    }
    public static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: "assistant", content: .text(text))
    }
    /// Multimodal user turn (the vision route): OpenAI-compatible image_url with a data URL.
    public static func userImage(prompt: String, base64PNG: String) -> ChatMessage {
        ChatMessage(role: "user", content: .parts([
            Part(type: "text", text: prompt),
            Part(type: "image_url", imageURL: ImageURL(url: "data:image/png;base64,\(base64PNG)")),
        ]))
    }
}

extension ChatMessage: Codable {
    enum CodingKeys: String, CodingKey { case role, content }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        content = try c.decode(Content.self, forKey: .content)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
    }
}

extension ChatMessage.Content: Codable {
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self) {
            self = .text(text)
            return
        }
        self = .parts(try single.decode([ChatMessage.Part].self))
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .text(let s): try single.encode(s)
        case .parts(let parts): try single.encode(parts)
        }
    }
}

/// Drafting prose over an OpenAI-compatible endpoint (reply route), and the vision route that
/// reads an image when text recognition is not enough.
public final class ChatClient {

    public let route: ResolvedRoute
    private let transport: HTTPTransport

    public init(route: ResolvedRoute, transport: HTTPTransport = URLSessionTransport()) {
        self.route = route
        self.transport = transport
    }

    private var headers: [String: String] {
        ["Authorization": "Bearer \(route.apiKey)",
         "Content-Type": "application/json",
         "Accept": "application/json"]
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let n: Int?
        let temperature: Double?
        let maxTokens: Int?
        enum CodingKeys: String, CodingKey {
            case model, messages, n, temperature
            case maxTokens = "max_tokens"
        }
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let text: String?
        }
        let choices: [Choice]?
    }

    /// Ask for `count` alternatives. Providers vary: some honour `n`, some return one answer with
    /// alternatives on separate lines. Both are handled, because a silently dropped alternative is
    /// a worse failure than a parse rule.
    public func chat(messages: [ChatMessage], count: Int = 1,
                     temperature: Double? = nil, maxTokens: Int? = nil) async throws -> [String] {
        guard let url = route.chatURL else {
            throw RouteConfigurationError.notAChatPreset(route.preset)
        }
        let body = RequestBody(model: route.model, messages: messages,
                               n: count > 1 ? count : nil,
                               temperature: temperature, maxTokens: maxTokens)
        let request = HTTPRequest(method: "POST", url: url, headers: headers,
                                  body: try JSONEncoder().encode(body))
        let response = try await transport.send(request)

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: response.body)
        } catch {
            throw HTTPError.malformedResponse("cannot decode chat completion: \(error.localizedDescription)")
        }
        var texts = (decoded.choices ?? []).compactMap { $0.message?.content ?? $0.text }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if texts.count == 1, count > 1 {
            let lines = texts[0].split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if lines.count > 1 { texts = lines }
        }
        guard !texts.isEmpty else {
            throw HTTPError.malformedResponse("the reply route returned no usable text")
        }
        return texts
    }

    /// The vision route: describe or read an image the text recogniser could not handle.
    public func readImage(base64PNG: String, prompt: String,
                          maxTokens: Int? = nil) async throws -> String {
        let texts = try await chat(messages: [.userImage(prompt: prompt, base64PNG: base64PNG)],
                                   count: 1, maxTokens: maxTokens)
        return texts[0]
    }

    public func probe() async -> ProbeResult {
        let started = Date()
        do {
            let response = try await transport.send(
                HTTPRequest(method: "GET", url: route.modelsURL, headers: headers,
                            body: nil, timeout: 20))
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            let names: [String]
            if let obj = response.json as? [String: Any] {
                let list = (obj["data"] as? [[String: Any]]) ?? (obj["models"] as? [[String: Any]]) ?? []
                names = list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            } else {
                names = []
            }
            return ProbeResult(ok: true,
                               detail: names.isEmpty ? "reachable"
                                                     : "reachable · \(names.count) model(s)",
                               millis: millis)
        } catch let error as HTTPError {
            return ProbeResult(ok: false, detail: error.description,
                               millis: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return ProbeResult(ok: false, detail: error.localizedDescription,
                               millis: Int(Date().timeIntervalSince(started) * 1000))
        }
    }
}