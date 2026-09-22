import Foundation
import JudgeClient

/// One configurable route as the app persists it. The key is NOT here — it lives in the Keychain
/// under `keyAccount`, and only ever travels to the endpoint.
public struct StoredRoute: Codable, Equatable {
    public var preset: String
    public var baseURL: String
    public var model: String
    /// Keychain account for this route's key (the judgment route's key is the one that inherits).
    public var keyAccount: String

    public init(preset: RoutePreset, baseURL: String = "", model: String = "", keyAccount: String) {
        self.preset = preset.rawValue
        self.baseURL = baseURL
        self.model = model
        self.keyAccount = keyAccount
    }

    public var routePreset: RoutePreset { RoutePreset(rawValue: preset) ?? .custom }

    public func config(keyProvider: (String) -> String? = KeychainStore.get) -> RouteConfig {
        RouteConfig(preset: routePreset,
                    baseURL: baseURL.isEmpty ? routePreset.defaultBaseURL : URL(string: baseURL),
                    apiKey: keyProvider(keyAccount),
                    model: model.isEmpty ? routePreset.defaultModel : model)
    }
}

/// Everything the app needs to run the copilot, persisted in the App Group so the keyboard reads
/// the same configuration.
public struct CopilotSettings: Codable, Equatable {

    public static let judgmentKeyAccount = "route.judgment"
    public static let replyKeyAccount = "route.reply"
    public static let visionKeyAccount = "route.vision"

    public var judgment: StoredRoute
    public var reply: StoredRoute
    public var vision: StoredRoute

    public var dangerAlert: Double
    public var lowConfidence: Double
    public var replyNowThreshold: Double

    /// Contacts and notes are pulled into the judgment as user facts.
    public var useKnowledge: Bool

    public init(judgment: StoredRoute = StoredRoute(preset: .typesafe,
                                                    keyAccount: CopilotSettings.judgmentKeyAccount),
                reply: StoredRoute = StoredRoute(preset: .openRouter,
                                                 keyAccount: CopilotSettings.replyKeyAccount),
                vision: StoredRoute = StoredRoute(preset: .qwenCompatible,
                                                  keyAccount: CopilotSettings.visionKeyAccount),
                dangerAlert: Double = 2.5, lowConfidence: Double = 0.5,
                replyNowThreshold: Double = 0.5, useKnowledge: Bool = true) {
        self.judgment = judgment
        self.reply = reply
        self.vision = vision
        self.dangerAlert = dangerAlert
        self.lowConfidence = lowConfidence
        self.replyNowThreshold = replyNowThreshold
        self.useKnowledge = useKnowledge
    }

    /// Keys are read through a provider so the whole configuration layer stays testable without a
    /// keychain (the app passes the default, tests pass a stub).
    public func routes(keyProvider: (String) -> String? = KeychainStore.get) -> RouteSet {
        RouteSet(judgment: judgment.config(keyProvider: keyProvider),
                 reply: reply.config(keyProvider: keyProvider),
                 vision: vision.config(keyProvider: keyProvider))
    }

    public var policy: JudgmentPolicy {
        JudgmentPolicy(lowConfidence: lowConfidence, dangerAlert: dangerAlert,
                       replyNowThreshold: replyNowThreshold)
    }

    // MARK: persistence

    private static let defaultsKey = "copilot.settings.v1"

    public static func load() -> CopilotSettings {
        guard let data = SharedContainer.defaults?.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(CopilotSettings.self, from: data) else {
            return CopilotSettings()
        }
        return settings
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        SharedContainer.defaults?.set(data, forKey: CopilotSettings.defaultsKey)
    }
}