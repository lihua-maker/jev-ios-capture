import UIKit
import SwiftUI
import CopilotKit

/// The keyboard cannot read other apps' screens either — what it CAN do is put a finished
/// suggestion into the text field. So it renders the app's last analysis (from the App Group) and
/// inserts on tap, and falls back to the clipboard when no App Group is available.
final class KeyboardViewController: UIInputViewController {

    private var hosting: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        install()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The user may have run a new analysis while the keyboard was up.
        refresh()
    }

    private func install() {
        let host = UIHostingController(rootView: makeView())
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hosting = host

        let height = view.heightAnchor.constraint(equalToConstant: 300)
        height.priority = .defaultHigh
        height.isActive = true
    }

    private func refresh() {
        hosting?.rootView = makeView()
    }

    private func makeView() -> KeyboardView {
        let clipboardReply = ClipboardHandoff.decode(UIPasteboard.general.string)
        return KeyboardView(
            snapshot: AnalysisStore().loadFresh(),
            clipboardReply: hasFullAccess ? clipboardReply : nil,
            needsFullAccess: !hasFullAccess,
            appGroupAvailable: SharedContainer.isAvailable,
            insert: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            nextKeyboard: { [weak self] in self?.advanceToNextInputMode() })
    }
}

struct KeyboardView: View {
    let snapshot: AnalysisSnapshot?
    let clipboardReply: String?
    let needsFullAccess: Bool
    let appGroupAvailable: Bool
    let insert: (String) -> Void
    let deleteBackward: () -> Void
    let nextKeyboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let snapshot {
                if let escalation = snapshot.escalationSummary {
                    Text(escalation)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if snapshot.candidates.isEmpty {
                    Text("判断认为现在不必急着回。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(snapshot.candidates.prefix(3)) { candidate in
                    Button {
                        insert(candidate.text)
                    } label: {
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f", candidate.score))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Text(candidate.text).font(.caption).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text(appGroupAvailable
                     ? "还没有分析结果。先在 App 里分析一张截图。"
                     : "App Group 不可用：在 App 里点「复制」，然后按下面的按钮插入。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if needsFullAccess {
                Text("需要在设置里给键盘打开「完全访问权限」才能读剪贴板和发网络请求。")
                    .font(.caption2).foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button { nextKeyboard() } label: { Image(systemName: "globe") }
                Button { deleteBackward() } label: { Image(systemName: "delete.left") }
                Spacer()
                if let clipboardReply {
                    Button {
                        insert(clipboardReply)
                    } label: {
                        Label("插入剪贴板", systemImage: "doc.on.clipboard").font(.caption2)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Jev").font(.caption.weight(.bold))
            if let snapshot {
                if let intent = snapshot.intent {
                    Text(intent).font(.caption2).foregroundStyle(.secondary)
                }
                if let danger = snapshot.danger {
                    Text(String(format: "风险 %.1f", danger))
                        .font(.caption2)
                        .foregroundStyle(danger >= 2.5 ? .red : .secondary)
                }
            }
            Spacer()
            if let snapshot {
                Text(snapshot.createdAt, style: .time)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}