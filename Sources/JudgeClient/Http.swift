import Foundation

public struct HTTPRequest: Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:],
                body: Data? = nil, timeout: TimeInterval = 30) {
        self.method = method; self.url = url; self.headers = headers
        self.body = body; self.timeout = timeout
    }
}

public struct HTTPResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }

    public var json: Any? { try? JSONSerialization.jsonObject(with: body) }
    public var text: String { String(data: body, encoding: .utf8) ?? "" }
}

/// Everything the clients need from the network, so tests can run without one.
public protocol HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum HTTPError: Error, Equatable, CustomStringConvertible {
    case unreachable(String)
    case timedOut
    case unauthorized(status: Int, detail: String, requestId: String?)
    case httpStatus(code: Int, detail: String, requestId: String?)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .unreachable(let why): return "could not reach the API: \(why)"
        case .timedOut: return "the API did not answer in time"
        case .unauthorized(let s, let d, let r):
            return "key rejected by the API (\(s)): \(d)\(r.map { " (request_id=\($0))" } ?? "")"
        case .httpStatus(let c, let d, let r):
            return "API error \(c): \(d)\(r.map { " (request_id=\($0))" } ?? "")"
        case .malformedResponse(let why): return "unusable API response: \(why)"
        }
    }

    /// Human-readable detail out of an error body, mirroring the CLI's extraction:
    /// `{"error": ...}` or `{"message": ...}`, possibly nested one level.
    static func detail(fromJSON data: Data, fallback: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }
        if let dict = obj["error"] as? [String: Any] {
            if let m = dict["message"] as? String { return m }
            return (try? JSONSerialization.data(withJSONObject: dict))
                .flatMap { String(data: $0, encoding: .utf8) } ?? fallback
        }
        if let e = obj["error"] as? String { return e }
        if let m = obj["message"] as? String { return m }
        return fallback
    }
}

/// Production transport.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url, timeoutInterval: request.timeout)
        req.httpMethod = request.method
        req.httpBody = request.body
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            if error.code == .timedOut { throw HTTPError.timedOut }
            throw HTTPError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.malformedResponse("not an HTTP response")
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            headers[String(describing: k).lowercased()] = String(describing: v)
        }
        let result = HTTPResponse(status: http.statusCode, headers: headers, body: data)

        if !(200...299).contains(http.statusCode) {
            let detail = HTTPError.detail(fromJSON: data, fallback: result.text.prefix(300).description)
            let rid = headers["x-request-id"] ?? headers["request-id"]
            if http.statusCode == 401 || http.statusCode == 403 {
                throw HTTPError.unauthorized(status: http.statusCode, detail: detail, requestId: rid)
            }
            throw HTTPError.httpStatus(code: http.statusCode, detail: detail, requestId: rid)
        }
        return result
    }
}