import SwiftUI
import CopilotKit

@main
struct JevCopilotApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                AnalysisView().tabItem { Label("分析", systemImage: "text.bubble") }
                SettingsView().tabItem { Label("接口", systemImage: "slider.horizontal.3") }
                KnowledgeView().tabItem { Label("知识库", systemImage: "person.crop.rectangle.stack") }
                SelfTestView().tabItem { Label("自检", systemImage: "checkmark.seal") }
            }
            .environmentObject(model)
        }
    }
}

/// Shared styling for the danger readout — one place, so the banner and the keyboard agree.
struct DangerBadge: View {
    let danger: Double?
    let label: String?

    var body: some View {
        if let danger {
            let level = Int(danger.rounded())
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: level))
                    .frame(width: 10, height: 10)
                Text("风险 \(level)/4")
                    .font(.footnote.weight(.semibold))
                if let label, !label.isEmpty {
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func color(for level: Int) -> Color {
        switch level {
        case 0, 1: return .green
        case 2: return .yellow
        case 3: return .orange
        default: return .red
        }
    }
}