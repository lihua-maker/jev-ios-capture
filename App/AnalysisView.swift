import SwiftUI
import PhotosUI
import UIKit
import CopilotKit
import JudgeClient

struct AnalysisView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pickedItem: PhotosPickerItem?
    @State private var pasted: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    intakeRow
                    switch model.phase {
                    case .reading: progress("正在识别截图…")
                    case .judging: progress("正在判断…")
                    case .failed(let message): failure(message)
                    case .idle, .done: EmptyView()
                    }
                    if let outcome = model.outcome { result(outcome) }
                }
                .padding()
            }
            .navigationTitle("Jev 助手")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let note = model.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var intakeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await model.analyzeNewestScreenshot() }
            } label: {
                Label("分析最新截图", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            PhotosPicker(selection: $pickedItem, matching: .screenshots) {
                Label("从相册选截图", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            HStack {
                TextField("或粘贴一段对话", text: $pasted, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button("分析") {
                    let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    Task { await model.analyze(text: text) }
                }
                .buttonStyle(.bordered)
            }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await model.analyze(image: image)
                } else {
                    model.phase = .failed("这张截图读不出来")
                }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) { ProgressView(); Text(text).font(.footnote) }
    }

    private func failure(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.red)
    }

    @ViewBuilder
    private func result(_ outcome: CopilotService.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let escalation = outcome.snapshot.escalationSummary {
                Label(escalation, systemImage: "exclamationmark.shield")
                    .font(.footnote.weight(.semibold))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }

            DangerBadge(danger: outcome.run.judgment.danger,
                        label: outcome.run.judgment.dangerLabel)

            HStack(spacing: 14) {
                metric("对方意图", outcome.run.judgment.intent ?? "—")
                metric("该马上回", percent(outcome.run.judgment.replyNowProbability))
                metric("先核实身份", percent(outcome.run.judgment.verifyProbability))
            }

            if !outcome.bubbles.isEmpty {
                DisclosureGroup("识别到的对话（\(outcome.bubbles.count) 条）") {
                    Text(outcome.transcript)
                        .font(.footnote.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !outcome.run.candidates.isEmpty {
                Text("候选回复（按判断排序）").font(.subheadline.weight(.semibold))
                ForEach(Array(outcome.run.candidates.enumerated()), id: \.offset) { index, candidate in
                    candidateRow(index: index, candidate: candidate)
                }
            } else {
                Text("判断认为现在不必急着回，没有起草回复。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    model.saveContactFromConversation()
                } label: { Label("存为联系人", systemImage: "person.badge.plus") }
                .buttonStyle(.bordered)
                if !CopilotKit.SharedContainer.isAvailable {
                    Text("App Group 不可用：键盘将通过剪贴板插入").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium))
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private func candidateRow(index: Int, candidate: RankedCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.text).font(.callout)
            HStack(spacing: 10) {
                Text(String(format: "%.1f", candidate.score)).font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let label = candidate.label, !label.isEmpty {
                    Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("复制") { model.copyForKeyboard(candidate.text) }
                    .font(.caption)
                Button("发给键盘") { model.copyForKeyboard(candidate.text) }
                    .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index == 0 ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}