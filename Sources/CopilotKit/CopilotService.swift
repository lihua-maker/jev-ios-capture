import Foundation
import CoreGraphics
import ChatCapture
import JudgeClient

/// The composition the app (and any future surface) calls: screenshot in, judged conversation out.
///
/// Nothing here is iOS-specific — it takes a `CGImage`, so the same object runs on a phone and in a
/// macOS test.
public final class CopilotService {

    public struct Outcome {
        public let bubbles: [Bubble]
        public let transcript: String
        public let run: CopilotRun
        public let snapshot: AnalysisSnapshot
        public let droppedChrome: [DroppedLine]
    }

    private let settings: CopilotSettings
    private let knowledge: KnowledgeStore
    private let analysisStore: AnalysisStore
    private let transport: HTTPTransport
    private let reader: VisionTextReader
    private let keyProvider: (String) -> String?

    public init(settings: CopilotSettings = CopilotSettings.load(),
                knowledge: KnowledgeStore = KnowledgeStore(),
                analysisStore: AnalysisStore = AnalysisStore(),
                transport: HTTPTransport = URLSessionTransport(),
                reader: VisionTextReader = VisionTextReader(),
                keyProvider: @escaping (String) -> String? = KeychainStore.get) {
        self.settings = settings
        self.knowledge = knowledge
        self.analysisStore = analysisStore
        self.transport = transport
        self.reader = reader
        self.keyProvider = keyProvider
    }

    /// The transcript the judgments see. Sender labels are kept ("对方(王姐)" / "我") because who
    /// said what is part of what is being judged.
    public static func transcript(from bubbles: [Bubble]) -> String {
        bubbles.map { bubble in
            let who = bubble.side == .me ? "我" : (bubble.sender == "them" ? "对方" : "对方(\(bubble.sender))")
            let quoted = bubble.quote.isEmpty ? "" : "［引用 \(bubble.quote)］"
            return "\(who): \(quoted)\(bubble.text)"
        }
        .joined(separator: "\n")
    }

    // MARK: analysis

    /// Full path: screenshot → lines → bubbles → transcript → judgment → ranked candidates.
    public func analyze(image: CGImage, contactName: String? = nil,
                        providedCandidates: [String] = [],
                        draftCount: Int = 3) async throws -> Outcome {
        let document = try reader.read(image)
        let result = BubbleSegmenter.segment(document)
        let transcript = CopilotService.transcript(from: result.bubbles)
        var outcome = try await analyze(transcript: transcript, contactName: contactName,
                                        providedCandidates: providedCandidates, draftCount: draftCount)
        outcome = Outcome(bubbles: result.bubbles, transcript: outcome.transcript,
                          run: outcome.run, snapshot: outcome.snapshot,
                          droppedChrome: result.dropped)
        return outcome
    }

    /// Judgment path only, for text that arrived without an image (a pasted message, a share
    /// extension, a test).
    public func analyze(transcript: String, contactName: String? = nil,
                        providedCandidates: [String] = [], draftCount: Int = 3) async throws -> Outcome {
        let copilot = try Copilot(routes: settings.routes(keyProvider: keyProvider),
                                  transport: transport, policy: settings.policy)
        let facts = settings.useKnowledge ? knowledge.facts(contactName: contactName,
                                                           transcript: transcript) : nil
        let run = try await copilot.run(transcript: transcript, userFacts: facts,
                                        providedCandidates: providedCandidates,
                                        draftCount: draftCount)
        let snapshot = AnalysisSnapshot.from(run, transcript: transcript,
                                             contactName: contactName,
                                             model: settings.judgment.model.isEmpty
                                                 ? settings.judgment.routePreset.defaultModel : settings.judgment.model)
        analysisStore.save(snapshot)
        return Outcome(bubbles: [], transcript: transcript, run: run,
                       snapshot: snapshot, droppedChrome: [])
    }

    /// The app's per-route connectivity test.
    public func probe(_ kind: RouteKind) async -> ProbeResult {
        do {
            let route = try settings.routes(keyProvider: keyProvider).resolve(kind)
            switch kind {
            case .judgment:
                let backend: JudgmentBackend = route.preset == .typesafe
                    ? JevClient(route: route, transport: transport)
                    : LLMJudgeClient(route: route, transport: transport)
                return await backend.probe()
            case .reply, .vision:
                return await ChatClient(route: route, transport: transport).probe()
            }
        } catch {
            return ProbeResult(ok: false,
                               detail: (error as? RouteConfigurationError)?.description
                                   ?? error.localizedDescription,
                               millis: nil)
        }
    }
}