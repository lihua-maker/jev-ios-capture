import Foundation

public struct Contact: Codable, Identifiable, Equatable {
    public var id: UUID
    /// The name as it appears in the chat (a 1:1 title, or a group-chat sender label).
    public var name: String
    /// Cross-app aliases — the same person shows up as different names in different apps.
    public var aliases: [String]
    public var relation: String
    public var notes: String

    public init(id: UUID = UUID(), name: String, aliases: [String] = [],
                relation: String = "", notes: String = "") {
        self.id = id; self.name = name; self.aliases = aliases
        self.relation = relation; self.notes = notes
    }
}

public struct Note: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var body: String
    public var tags: [String]
    /// Pinned notes are always attached to the judgment, the way the original app's 「常驻」 works.
    public var pinned: Bool

    public init(id: UUID = UUID(), title: String, body: String,
                tags: [String] = [], pinned: Bool = false) {
        self.id = id; self.title = title; self.body = body; self.tags = tags; self.pinned = pinned
    }
}

/// The local knowledge base: notes (with tags and a pinned flag) and contact profiles. Everything
/// stays on the device; the only thing that leaves it is the text of `facts(...)`, which goes to the
/// user's own configured endpoint as part of the judgment state.
public final class KnowledgeStore {

    public private(set) var contacts: [Contact]
    public private(set) var notes: [Note]

    private let fileURL: URL
    private let maxFactsCharacters: Int

    public init(fileURL: URL? = nil, maxFactsCharacters: Int = 1200) {
        self.fileURL = fileURL ?? SharedContainer.url(for: "knowledge.json")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("knowledge.json")
        self.maxFactsCharacters = maxFactsCharacters
        let loaded = KnowledgeStore.read(from: self.fileURL)
        self.contacts = loaded.contacts
        self.notes = loaded.notes
    }

    // MARK: editing

    public func upsert(_ contact: Contact) {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
        save()
    }

    public func upsert(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
        save()
    }

    public func removeContact(_ id: UUID) { contacts.removeAll { $0.id == id }; save() }
    public func removeNote(_ id: UUID) { notes.removeAll { $0.id == id }; save() }

    public func save() {
        let payload = Payload(contacts: contacts, notes: notes)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Save a contact from a conversation (the original app's "长按气泡存为联系人").
    public func saveContact(fromSender sender: String, transcript: String) {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "them", trimmed != "me" else { return }
        if contacts.contains(where: { $0.name == trimmed || $0.aliases.contains(trimmed) }) { return }
        upsert(Contact(name: trimmed, notes: String(transcript.prefix(400))))
    }

    // MARK: retrieval

    public func contact(matching name: String?) -> Contact? {
        guard let name else { return nil }
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return contacts.first { $0.name == needle || $0.aliases.contains(needle) }
    }

    /// The facts handed to the judgment: who is talking, plus the notes that this conversation
    /// actually touches (pinned ones always, tagged ones when their tag or title appears in the
    /// text). Ordering is stable so the same conversation always produces the same state.
    public func facts(contactName: String?, transcript: String) -> String {
        var parts: [String] = []

        if let contact = contact(matching: contactName) {
            var lines = ["对方身份：\(contact.name)"]
            if !contact.relation.isEmpty { lines.append("关系：\(contact.relation)") }
            if !contact.aliases.isEmpty { lines.append("别名：\(contact.aliases.joined(separator: "、"))") }
            if !contact.notes.isEmpty { lines.append("备注：\(contact.notes)") }
            parts.append(lines.joined(separator: "\n"))
        }

        let relevant = notes.filter { note in
            note.pinned || note.tags.contains { tag in !tag.isEmpty && transcript.contains(tag) }
                || (!note.title.isEmpty && transcript.contains(note.title))
        }
        if !relevant.isEmpty {
            let rendered = relevant.map { note in
                let tags = note.tags.isEmpty ? "" : "［\(note.tags.joined(separator: "/"))］"
                return "- \(note.title)\(tags)：\(note.body)"
            }
            parts.append("相关资料：\n" + rendered.joined(separator: "\n"))
        }

        var out = parts.joined(separator: "\n\n")
        if out.count > maxFactsCharacters {
            out = String(out.prefix(maxFactsCharacters)) + "…"
        }
        return out
    }

    // MARK: storage

    private struct Payload: Codable {
        var contacts: [Contact]
        var notes: [Note]
    }

    private static func read(from url: URL) -> Payload {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Payload(contacts: [], notes: [])
        }
        return payload
    }
}