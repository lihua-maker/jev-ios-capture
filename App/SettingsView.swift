import SwiftUI
import CopilotKit
import JudgeClient

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("只有判断接口是必填的。回复、视觉留空会继承判断接口的密钥；地址只在同一类接口之间继承。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                RouteCard(kind: .judgment, title: "判断接口", subtitle: "给出意图 / 风险 / 该不该回（TypeSafe 提供真正的 typed answers）")
                RouteCard(kind: .reply, title: "回复接口", subtitle: "起草候选回复（OpenAI 兼容的 chat completions）")
                RouteCard(kind: .vision, title: "视觉接口", subtitle: "识别文字读不出来时的图像兜底")

                Section("判断阈值") {
                    slider("风险提醒阈值", value: $model.settings.dangerAlert, range: 1...4, format: "%.1f")
                    slider("低置信阈值", value: $model.settings.lowConfidence, range: 0.2...0.9, format: "%.2f")
                    slider("「该马上回」阈值", value: $model.settings.replyNowThreshold, range: 0.1...0.9, format: "%.2f")
                    Text("阈值要在你自己的数据上调 — 这里的默认值来自 12 段测试对话。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("知识库") {
                    Toggle("分析时带上联系人和笔记", isOn: $model.settings.useKnowledge)
                    if !SharedContainer.isAvailable {
                        Text("App Group 不可用（需要签名时勾选 group.ai.jevcopilot）。键盘将退回剪贴板插入。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("保存") { model.saveSettings() }
                }
            }
            .navigationTitle("接口")
        }
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.footnote.monospaced()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

/// One route: preset, address, model, key, and its own connectivity test.
private struct RouteCard: View {
    let kind: RouteKind
    let title: String
    let subtitle: String

    @EnvironmentObject private var model: AppModel
    @State private var key: String = ""
    @State private var probe: ProbeResult?
    @State private var probing = false

    private var route: Binding<StoredRoute> {
        switch kind {
        case .judgment: return $model.settings.judgment
        case .reply: return $model.settings.reply
        case .vision: return $model.settings.vision
        }
    }

    var body: some View {
        Section {
            Text(subtitle).font(.caption).foregroundStyle(.secondary)

            Picker("预设", selection: Binding(
                get: { route.wrappedValue.routePreset },
                set: { preset in
                    route.wrappedValue.preset = preset.rawValue
                    route.wrappedValue.baseURL = preset.defaultBaseURL?.absoluteString ?? ""
                    route.wrappedValue.model = preset.defaultModel ?? ""
                })) {
                    ForEach(RoutePreset.allCases, id: \.self) { preset in
                        Text(label(preset)).tag(preset)
                    }
                }

            TextField("地址", text: route.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            TextField("模型", text: route.model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("密钥（存在 Keychain，留空则继承判断接口的密钥）", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Button("保存密钥") {
                    try? KeychainStore.set(key.isEmpty ? nil : key, for: route.wrappedValue.keyAccount)
                    key = ""
                    model.saveSettings()
                }
                .font(.footnote)
                Spacer()
                Button {
                    probing = true
                    Task {
                        probe = await model.probe(kind)
                        probing = false
                    }
                } label: {
                    if probing { ProgressView() } else { Text("测试连通").font(.footnote) }
                }
            }

            if let probe {
                Label(probe.detail, systemImage: probe.ok ? "checkmark.circle" : "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(probe.ok ? .green : .red)
            }
            if let storedKey = KeychainStore.get(route.wrappedValue.keyAccount), !storedKey.isEmpty {
                Label("已保存密钥（\(storedKey.count) 位）", systemImage: "key")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        }
    }

    private func label(_ preset: RoutePreset) -> String {
        switch preset {
        case .typesafe: return "TypeSafe（typed judgment）"
        case .openRouter: return "OpenRouter"
        case .deepSeek: return "DeepSeek 官方"
        case .qwenCompatible: return "通义兼容"
        case .custom: return "自填地址"
        }
    }
}