import SwiftUI
import UIKit
import CopilotKit

/// One tap, one answerable line. Built so that verifying an install does not require sending
/// screenshots of a private conversation: the checks run against a corpus screenshot that ships
/// with the app.
struct SelfTestView: View {
    @EnvironmentObject private var model: AppModel
    @State private var report: SelfTestReport?
    @State private var running = false
    @State private var copied = false

    private var screenDescription: String {
        let b = UIScreen.main.bounds
        let s = UIScreen.main.scale
        return "\(Int(b.width))×\(Int(b.height))pt @\(Int(s))x = "
            + "\(Int(b.width * s))×\(Int(b.height * s))px"
            + (Int(b.width * s) == 1170 ? "（= 语料几何）" : "（≠ 语料 1170×2532，规则按比例仍适用）")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let report {
                        Label(report.passed ? "通过" : "有失败项",
                              systemImage: report.passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .foregroundStyle(report.passed ? .green : .red)
                            .font(.headline)
                    }
                    Button {
                        Task {
                            running = true
                            copied = false
                            report = await model.selfTest(screen: screenDescription)
                            running = false
                        }
                    } label: {
                        if running { ProgressView() } else { Text("运行自检") }
                    }
                    .disabled(running)
                } footer: {
                    Text("自检用的是随 app 打包的语料截图，不读你的聊天记录；结果只在本机显示，"
                         + "点下面可以复制成一行贴给我。")
                }

                if let report {
                    Section("检查项") {
                        ForEach(report.checks) { c in
                            HStack(alignment: .top, spacing: 8) {
                                Text(c.kind == .info ? "·" : (c.passed ? "✓" : "✗"))
                                    .foregroundStyle(c.kind == .info ? .secondary
                                                     : (c.passed ? .green : .red))
                                    .font(.body.monospaced())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.subheadline)
                                    Text(c.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section {
                        Button(copied ? "已复制" : "复制结果") {
                            UIPasteboard.general.string = report.summary
                            copied = true
                        }
                    }
                    if !report.transcript.isEmpty {
                        Section("本机识别出的会话（自检截图）") {
                            Text(report.transcript).font(.footnote.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("自检")
        }
    }
}