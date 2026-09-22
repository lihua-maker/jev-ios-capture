import SwiftUI
import CopilotKit

struct KnowledgeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newNote = Note(title: "", body: "", tags: [], pinned: false)
    @State private var newContact = Contact(name: "", aliases: [], relation: "", notes: "")
    @State private var tagText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("这些内容只存在手机上，只在分析那一刻随判断请求发给你自己配置的接口。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("常驻 / 标签笔记") {
                    ForEach(model.knowledge.notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(note.title).font(.callout.weight(.medium))
                                if note.pinned { Image(systemName: "pin.fill").font(.caption2) }
                                Spacer()
                                Button(role: .destructive) {
                                    model.knowledge.removeNote(note.id)
                                    model.objectWillChange.send()
                                } label: { Image(systemName: "trash").font(.caption) }
                            }
                            if !note.tags.isEmpty {
                                Text(note.tags.map { "#\($0)" }.joined(separator: " "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(note.body).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    noteEditor
                }

                Section("联系人档案") {
                    ForEach(model.knowledge.contacts) { contact in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(contact.name).font(.callout.weight(.medium))
                                if !contact.relation.isEmpty {
                                    Text(contact.relation).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    model.knowledge.removeContact(contact.id)
                                    model.objectWillChange.send()
                                } label: { Image(systemName: "trash").font(.caption) }
                            }
                            if !contact.aliases.isEmpty {
                                Text("别名：" + contact.aliases.joined(separator: "、"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if !contact.notes.isEmpty {
                                Text(contact.notes).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    contactEditor
                }
            }
            .navigationTitle("知识库")
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("标题", text: $newNote.title)
            TextField("内容", text: $newNote.body, axis: .vertical).lineLimit(2...5)
            TextField("标签，用空格分开（命中标签的笔记会自动带上）", text: $tagText)
            Toggle("常驻（每次分析都带上）", isOn: $newNote.pinned)
            Button("添加笔记") {
                var note = newNote
                note.tags = tagText.split(whereSeparator: { $0 == " " || $0 == "、" })
                    .map(String.init).filter { !$0.isEmpty }
                guard !note.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                model.knowledge.upsert(note)
                newNote = Note(title: "", body: "", tags: [], pinned: false)
                tagText = ""
                model.objectWillChange.send()
            }
            .font(.footnote)
        }
    }

    private var contactEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("昵称（和聊天里显示的一致）", text: $newContact.name)
            TextField("跨 App 别名，用空格分开", text: Binding(
                get: { newContact.aliases.joined(separator: " ") },
                set: { newContact.aliases = $0.split(separator: " ").map(String.init) }))
            TextField("关系（同事 / 上级 / 家人…）", text: $newContact.relation)
            TextField("备注", text: $newContact.notes, axis: .vertical).lineLimit(2...4)
            Button("添加联系人") {
                guard !newContact.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                model.knowledge.upsert(newContact)
                newContact = Contact(name: "", aliases: [], relation: "", notes: "")
                model.objectWillChange.send()
            }
            .font(.footnote)
        }
    }
}