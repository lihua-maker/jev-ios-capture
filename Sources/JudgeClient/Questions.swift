import Foundation

public enum QuestionValidationError: Error, Equatable, CustomStringConvertible {
    case emptyName
    case emptyInstructions(String)
    case scoreNeedsTwoLevels(String)
    case choiceNeedsKeyAndDescription(String)
    case duplicateChoiceKey(String, String)

    public var description: String {
        switch self {
        case .emptyName: return "a question needs a name"
        case .emptyInstructions(let n): return "question \(n): instructions cannot be empty"
        case .scoreNeedsTwoLevels(let n):
            return "question \(n): a score needs at least two ordered levels"
        case .choiceNeedsKeyAndDescription(let n):
            return "question \(n): every choice option needs a key AND a description"
        case .duplicateChoiceKey(let n, let k): return "question \(n): duplicate option key \(k)"
        }
    }
}

/// One typed question. Invalid shapes are unrepresentable: a `score` cannot be built without two
/// ordered levels, and a `choice` cannot be built without a key *and* a description per option —
/// the API rejects a bare label ("choice criteria need name=description"), so the type enforces it
/// instead of a runtime string check.
public struct Question: Equatable {
    public enum Kind: String { case noul, score, choice }

    public struct Option: Equatable {
        public let key: String
        public let description: String
        public init(_ key: String, _ description: String) {
            self.key = key; self.description = description
        }
    }

    public let name: String
    public let kind: Kind
    public let instructions: String
    /// Ordered levels for `.score`; nil otherwise.
    public let levels: [String]?
    /// Options for `.choice`; nil otherwise.
    public let options: [Option]?

    private init(name: String, kind: Kind, instructions: String,
                 levels: [String]? = nil, options: [Option]? = nil) {
        self.name = name; self.kind = kind; self.instructions = instructions
        self.levels = levels; self.options = options
    }

    public static func noul(name: String, instructions: String) throws -> Question {
        try validate(name: name, instructions: instructions)
        return Question(name: name, kind: .noul, instructions: instructions)
    }

    /// Levels are ordered from 0 upward; each must describe a concrete situation.
    public static func score(name: String, instructions: String, levels: [String]) throws -> Question {
        try validate(name: name, instructions: instructions)
        guard levels.count >= 2, levels.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw QuestionValidationError.scoreNeedsTwoLevels(name)
        }
        return Question(name: name, kind: .score, instructions: instructions, levels: levels)
    }

    public static func choice(name: String, instructions: String, options: [Option]) throws -> Question {
        try validate(name: name, instructions: instructions)
        guard options.count >= 2 else { throw QuestionValidationError.scoreNeedsTwoLevels(name) }
        var seen = Set<String>()
        for o in options {
            guard !o.key.isEmpty, !o.description.isEmpty else {
                throw QuestionValidationError.choiceNeedsKeyAndDescription(name)
            }
            guard seen.insert(o.key).inserted else {
                throw QuestionValidationError.duplicateChoiceKey(name, o.key)
            }
        }
        return Question(name: name, kind: .choice, instructions: instructions, options: options)
    }

    private static func validate(name: String, instructions: String) throws {
        guard !name.isEmpty else { throw QuestionValidationError.emptyName }
        guard !instructions.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw QuestionValidationError.emptyInstructions(name)
        }
    }

    /// The wire shape: `{"type": …, "instructions": …, "criteria": <string|[levels]|{key: desc}>}`.
    public var jsonObject: [String: Any] {
        var out: [String: Any] = ["type": kind.rawValue, "instructions": instructions]
        switch kind {
        case .noul:
            break
        case .score:
            out["criteria"] = levels ?? []
        case .choice:
            var mapping: [String: String] = [:]
            for o in options ?? [] { mapping[o.key] = o.description }
            out["criteria"] = mapping
        }
        return out
    }
}

public struct QuestionsPayload {
    public let questions: [Question]
    public init(_ questions: [Question]) { self.questions = questions }

    public var jsonObject: [String: Any] {
        var map: [String: Any] = [:]
        for q in questions { map[q.name] = q.jsonObject }
        return map
    }
}