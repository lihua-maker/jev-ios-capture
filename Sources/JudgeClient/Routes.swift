import Foundation

/// The three routes the app configures independently (v1.3 behaviour), plus the presets it ships.
public enum RouteKind: String, CaseIterable {
    case judgment   // intent / risk / should-I-reply-now
    case reply      // drafting prose
    case vision     // image understanding, used when text recognition is not enough
}

public enum RoutePreset: String, CaseIterable {
    case typesafe           // typed System One API (Jev) — the only one that returns typed answers
    case openRouter
    case deepSeek
    case qwenCompatible     // Aliyun DashScope OpenAI-compatible mode
    case custom             // own base URL

    public var defaultBaseURL: URL? {
        switch self {
        case .typesafe: return URL(string: "https://api.typesafe.ai")
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1")
        case .deepSeek: return URL(string: "https://api.deepseek.com/v1")
        case .qwenCompatible: return URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")
        case .custom: return nil
        }
    }

    public var defaultModel: String? {
        switch self {
        case .typesafe: return "jev-latest"
        case .openRouter: return "deepseek/deepseek-chat-v3.1"
        case .deepSeek: return "deepseek-chat"
        case .qwenCompatible: return "qwen-plus"
        case .custom: return nil
        }
    }

    /// Chat-completions path relative to the base URL. TypeSafe is not a chat API.
    public var chatPath: String? {
        switch self {
        case .typesafe: return nil
        default: return "chat/completions"
        }
    }

    /// True when the preset serves an OpenAI-compatible chat-completions endpoint.
    public var isChatCapable: Bool { chatPath != nil }

    /// Path used by the one-tap connectivity test — a cheap, token-free GET.
    public var modelsPath: String {
        switch self {
        case .typesafe: return "v1/models"
        default: return "models"
        }
    }
}

public struct RouteConfig: Equatable {
    public var preset: RoutePreset
    public var baseURL: URL?
    public var apiKey: String?
    public var model: String?

    public init(preset: RoutePreset = .custom, baseURL: URL? = nil,
                apiKey: String? = nil, model: String? = nil) {
        self.preset = preset; self.baseURL = baseURL; self.apiKey = apiKey; self.model = model
    }

    public static func preset(_ p: RoutePreset, apiKey: String? = nil, model: String? = nil) -> RouteConfig {
        RouteConfig(preset: p, baseURL: p.defaultBaseURL, apiKey: apiKey, model: model ?? p.defaultModel)
    }

    /// Fill this route from the judgment route where it is blank.
    ///
    /// v1.3: "只有一把密钥也够用，回复、视觉留空会自动继承" — one key is enough. The *key* therefore
    /// always inherits. Addresses and models only inherit inside one endpoint family: a chat route
    /// inherits from a chat-capable parent, never from the typed-judgment endpoint (which serves no
    /// chat-completions path at all). Without that rule a TypeSafe-only setup would silently point
    /// the reply route at an endpoint that cannot answer it.
    func inheriting(kind: RouteKind, parent: RouteConfig) -> RouteConfig {
        var out = self
        if out.baseURL == nil { out.baseURL = out.preset.defaultBaseURL }
        if out.baseURL == nil, kind != .judgment, parent.preset.isChatCapable {
            out.baseURL = parent.baseURL ?? parent.preset.defaultBaseURL
        }
        if out.apiKey?.isEmpty ?? true { out.apiKey = parent.apiKey }
        if out.model?.isEmpty ?? true { out.model = out.preset.defaultModel }
        // A blank route (preset .custom with nothing filled in) inherits the parent's model when
        // the parent speaks the same protocol family.
        if out.model?.isEmpty ?? true, out.preset == parent.preset || out.preset == .custom {
            out.model = parent.model
        }
        return out
    }
}

public struct ResolvedRoute: Equatable {
    public let kind: RouteKind
    public let preset: RoutePreset
    public let baseURL: URL
    public let apiKey: String
    public let model: String

    public func url(path: String) -> URL {
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "\(base)/\(clean)") ?? baseURL
    }

    public var chatURL: URL? { preset.chatPath.map { url(path: $0) } }
    public var judgmentURL: URL { url(path: "v1/systemone") }
    public var modelsURL: URL { url(path: preset.modelsPath) }
}

public enum RouteConfigurationError: Error, Equatable, CustomStringConvertible {
    case missingBaseURL(RouteKind)
    case missingKey(RouteKind)
    case notAChatPreset(RoutePreset)

    public var description: String {
        switch self {
        case .missingBaseURL(let k):
            return "the \(k.rawValue) route has no base URL — configure it (a typed-judgment "
                 + "endpoint cannot serve chat completions, so it is not inherited)"
        case .missingKey(let k): return "the \(k.rawValue) route has no API key (and none to inherit)"
        case .notAChatPreset(let p): return "\(p.rawValue) has no chat-completions endpoint"
        }
    }
}

/// The whole configurable surface: judgment / reply / vision, resolved with inheritance.
public struct RouteSet: Equatable {
    public var judgment: RouteConfig
    public var reply: RouteConfig
    public var vision: RouteConfig

    public init(judgment: RouteConfig, reply: RouteConfig = RouteConfig(),
                vision: RouteConfig = RouteConfig()) {
        self.judgment = judgment; self.reply = reply; self.vision = vision
    }

    /// One-key setup: everything inherits from the judgment route.
    public static func single(_ config: RouteConfig) -> RouteSet {
        RouteSet(judgment: config, reply: config, vision: config)
    }

    public func resolve(_ kind: RouteKind) throws -> ResolvedRoute {
        let parent = judgment
        let raw: RouteConfig
        switch kind {
        case .judgment: raw = judgment
        case .reply: raw = reply.inheriting(kind: .reply, parent: parent)
        case .vision: raw = vision.inheriting(kind: .vision, parent: parent)
        }
        guard let base = raw.baseURL else { throw RouteConfigurationError.missingBaseURL(kind) }
        let key = raw.apiKey ?? ""
        guard !key.isEmpty else { throw RouteConfigurationError.missingKey(kind) }
        let model = raw.model ?? ""
        if kind != .judgment, raw.preset.chatPath == nil {
            throw RouteConfigurationError.notAChatPreset(raw.preset)
        }
        return ResolvedRoute(kind: kind, preset: raw.preset, baseURL: base, apiKey: key, model: model)
    }
}