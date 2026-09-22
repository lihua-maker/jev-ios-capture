import Foundation
import JudgeClient

/// What the app hands to the keyboard: the judged conversation and the ranked replies, in a form
/// the extension can render without doing any work of its own (extensions have a tight memory
/// budget, so they read a finished result instead of computing one).
public struct AnalysisSnapshot: Codable, Equatable {

    public struct Candidate: Codable, Equatable, Identifiable {
        public var id: Int
        public var text: String
        public var score: Double
        public var confidence: Double
        public var label: String?

        public init(id: Int, text: String, score: Double, confidence: Double, label: String?) {
            self.id = id; self.text = text; self.score = score
            self.confidence = confidence; self.label = label
        }
    }

    public var createdAt: Date
    public var transcript: String
    public var contactName: String?
    public var intent: String?
    public var danger: Double?
    public var dangerLabel: String?
    public var replyNowProbability: Double?
    public var verifyProbability: Double?
    public var escalationSummary: String?
    public var candidates: [Candidate]
    public var backend: String
    public var model: String?

    public init(createdAt: Date = Date(), transcript: String, contactName: String?,
                intent: String?, danger: Double?, dangerLabel: String?,
                replyNowProbability: Double?, verifyProbability: Double?,
                escalationSummary: String?, candidates: [Candidate],
                backend: String, model: String?) {
        self.createdAt = createdAt; self.transcript = transcript; self.contactName = contactName
        self.intent = intent; self.danger = danger; self.dangerLabel = dangerLabel
        self.replyNowProbability = replyNowProbability; self.verifyProbability = verifyProbability
        self.escalationSummary = escalationSummary; self.candidates = candidates
        self.backend = backend; self.model = model
    }

    /// Build from a finished run, so the summary text lives in one place.
    public static func from(_ run: CopilotRun, transcript: String, contactName: String?,
                            model: String?) -> AnalysisSnapshot {
        var escalation: String?
        switch run.escalation {
        case .highRisk(let level, let label):
            escalation = "风险等级 \(level)：\(label)"
        case .verificationRequired:
            escalation = "建议先通过电话或当面核实身份，再谈钱款"
        case .lowConfidence(let question, let confidence):
            escalation = "判断不确定（\(question) 置信度 \(String(format: "%.2f", confidence))），请自己决定"
        case nil:
            escalation = nil
        }
        let candidates = run.candidates.enumerated().map { index, candidate in
            Candidate(id: index, text: candidate.text, score: candidate.score,
                      confidence: candidate.confidence, label: candidate.label)
        }
        return AnalysisSnapshot(
            transcript: transcript, contactName: contactName,
            intent: run.judgment.intent, danger: run.judgment.danger,
            dangerLabel: run.judgment.dangerLabel,
            replyNowProbability: run.judgment.replyNowProbability,
            verifyProbability: run.judgment.verifyProbability,
            escalationSummary: escalation, candidates: candidates,
            backend: run.backend.rawValue, model: model)
    }
}

/// The latest analysis, in the App Group container so the keyboard can read it.
public final class AnalysisStore {

    public static let fileName = "latest-analysis.json"
    /// An analysis older than this is not offered in the keyboard — a stale suggestion in a live
    /// conversation is worse than none.
    public static let freshness: TimeInterval = 15 * 60

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? SharedContainer.url(for: AnalysisStore.fileName)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(AnalysisStore.fileName)
    }

    public func save(_ snapshot: AnalysisSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func load() -> AnalysisSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AnalysisSnapshot.self, from: data)
    }

    public func loadFresh(now: Date = Date()) -> AnalysisSnapshot? {
        guard let snapshot = load() else { return nil }
        return now.timeIntervalSince(snapshot.createdAt) <= AnalysisStore.freshness ? snapshot : nil
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}