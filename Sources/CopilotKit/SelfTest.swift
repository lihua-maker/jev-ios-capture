import Foundation
import CoreGraphics
import ChatCapture
import JudgeClient

/// One line of the on-device self-test report.
public struct SelfTestCheck: Identifiable {
    public enum Kind: Equatable {
        /// Must pass: it is deterministic given this device.
        case check
        /// Reported for diagnosis; never fails the run.
        case info
    }

    public let id = UUID()
    public let kind: Kind
    public let name: String
    public let passed: Bool
    public let detail: String
}

public struct SelfTestReport {
    public let checks: [SelfTestCheck]
    public let transcript: String

    public var passed: Bool {
        checks.allSatisfy { $0.kind == .info || $0.passed }
    }

    /// One pastable line, so a device result can be reported without screenshots.
    public var summary: String {
        let failures = checks.filter { $0.kind == .check && !$0.passed }
        let head = passed ? "SELFTEST PASS" : "SELFTEST FAIL(\(failures.count))"
        let body = checks.map { c in
            let mark = c.kind == .info ? "·" : (c.passed ? "✓" : "✗")
            return "\(mark) \(c.name): \(c.detail)"
        }.joined(separator: "\n")
        return "\(head)\n\(body)"
    }
}

/// Runs the whole capture stage on the device, against a screenshot and an expected result that ship
/// with the app.
///
/// The point is that installing on a phone should produce a single answerable line rather than a
/// photo of a screen. Two of the checks are deliberately different in kind:
///
///  · the fixture check feeds the RECORDED line boxes through the segmenter, so it is deterministic
///    and tests the rules the app is about to run on this device;
///  · the recogniser check runs this device's own Vision on the bundled PNG, where boxes may differ
///    slightly from the CI runner's, so it asserts character agreement rather than exact boxes.
public enum SelfTest {

    public static func run(settings: CopilotSettings = .load(),
                           screen: String = "?",
                           transport: HTTPTransport = URLSessionTransport(),
                           reader: VisionTextReader = VisionTextReader()) async -> SelfTestReport {
        var checks: [SelfTestCheck] = []
        var transcript = ""

        checks.append(SelfTestCheck(kind: .info, name: "屏幕", passed: true, detail: screen))

        // The bundled fixture: a native 3x corpus render plus the output the reference
        // implementation produced for it (Apple Vision boxes, PingFang SC render).
        let fixture = loadFixture()
        let png = resourceURL("corpus", "png")

        // 1. Deterministic: the ported rules must reproduce the recorded output from recorded boxes.
        if let fixture {
            let doc = OcrDocument(width: fixture.width, height: fixture.height, lines: fixture.lines)
            let result = BubbleSegmenter.segment(doc)
            let mismatches = compare(result, fixture)
            checks.append(SelfTestCheck(
                kind: .check, name: "切分规则复现 fixture", passed: mismatches.isEmpty,
                detail: mismatches.isEmpty
                    ? "\(result.bubbles.count) 个气泡、\(result.dropped.count) 条 chrome 与记录一致"
                    : mismatches.prefix(2).joined(separator: " / ")))
        } else {
            checks.append(SelfTestCheck(kind: .check, name: "切分规则复现 fixture", passed: false,
                                        detail: "fixture 资源缺失"))
        }

        // 2. This device's recogniser on the bundled screenshot, tolerant on exact boxes.
        if let png {
            do {
                let document = try reader.read(url: png)
                let result = BubbleSegmenter.segment(OcrDocument(width: document.width,
                                                                 height: document.height,
                                                                 lines: document.lines))
                transcript = result.bubbles.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
                let got = result.bubbles.map(\.text).joined()
                let want = (fixture?.expectedText ?? "")
                let accuracy = want.isEmpty ? 0 : TextCompare.similarity(got, want)
                checks.append(SelfTestCheck(
                    kind: .check, name: "本机识别 + 转录", passed: accuracy >= 0.9,
                    detail: String(format: "%d 行 → %d 个气泡，与期望文字一致度 %.1f%%",
                                   document.lines.count, result.bubbles.count, accuracy * 100)))
            } catch {
                checks.append(SelfTestCheck(kind: .check, name: "本机识别 + 转录", passed: false,
                                            detail: "Vision 失败：\(error)"))
            }
        } else {
            checks.append(SelfTestCheck(kind: .check, name: "本机识别 + 转录", passed: false,
                                        detail: "截图资源缺失"))
        }

        // 3. Keys must survive a Keychain round-trip; without one the app cannot call anything.
        let probe = "selftest-\(UUID().uuidString.prefix(8))"
        try? KeychainStore.set(probe, for: "selftest.probe")
        let readBack = KeychainStore.get("selftest.probe")
        checks.append(SelfTestCheck(kind: .check, name: "Keychain 读写", passed: readBack == probe,
                                    detail: readBack == probe ? "可写可读" : "读回不一致：\(readBack ?? "nil")"))
        KeychainStore.remove("selftest.probe")

        // 4. Information the developer normally has to ask for.
        checks.append(SelfTestCheck(
            kind: .info, name: "App Group（键盘共享）", passed: SharedContainer.isAvailable,
            detail: SharedContainer.isAvailable
                ? "可用：键盘直接读取分析结果"
                : "不可用：走剪贴板回退（app 会写明）"))
        checks.append(SelfTestCheck(
            kind: .info, name: "判断接口", passed: !settings.judgment.keyAccount.isEmpty,
            detail: settings.judgment.keyAccount.isEmpty ? "未配置" : "已配置 \(settings.judgment.preset)"))

        // 5. A live judgment call, only when a key is actually present.
        if !settings.judgment.keyAccount.isEmpty {
            do {
                let route = try settings.routes(keyProvider: KeychainStore.get).resolve(.judgment)
                let backend: JudgmentBackend = route.preset == .typesafe
                    ? JevClient(route: route, transport: transport)
                    : LLMJudgeClient(route: route, transport: transport)
                let result = await backend.probe()
                checks.append(SelfTestCheck(kind: .check, name: "判断接口连通", passed: result.ok,
                                            detail: result.detail))
            } catch {
                checks.append(SelfTestCheck(kind: .check, name: "判断接口连通", passed: false,
                                            detail: "\(error)"))
            }
        } else {
            checks.append(SelfTestCheck(kind: .info, name: "判断接口连通", passed: true,
                                        detail: "跳过（未配置密钥）"))
        }

        return SelfTestReport(checks: checks, transcript: transcript)
    }

    // MARK: - Fixture resource

    struct Fixture {
        let width: Double
        let height: Double
        let lines: [OcrLine]
        let bubbles: [(side: Side, sender: String, text: String, quote: String)]
        let dropped: [(region: String, text: String)]

        var expectedText: String { bubbles.map(\.text).joined() }
    }

    static func resourceURL(_ name: String, _ ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "selftest")
    }

    static func loadFixture() -> Fixture? {
        guard let url = resourceURL("expected", "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expected = root["expected"] as? [String: Any],
              let rawLines = root["lines"] as? [[String: Any]] else { return nil }

        let lines: [OcrLine] = rawLines.compactMap { l in
            guard let text = l["text"] as? String, let x = l["x"] as? Double, let y = l["y"] as? Double,
                  let w = l["w"] as? Double, let h = l["h"] as? Double else { return nil }
            return OcrLine(text: text, x: x, y: y, w: w, h: h)
        }
        let bubbles = ((expected["bubbles"] as? [[String: Any]]) ?? []).compactMap { b -> (Side, String, String, String)? in
            guard let text = b["text"] as? String, let sender = b["sender"] as? String else { return nil }
            let side: Side = (b["side"] as? String) == "me" ? .me : .them
            return (side, sender, text, (b["quote"] as? String) ?? "")
        }
        let dropped = ((expected["dropped"] as? [[String: Any]]) ?? []).compactMap { d -> (String, String)? in
            guard let region = d["region"] as? String, let text = d["text"] as? String else { return nil }
            return (region, text)
        }
        return Fixture(width: (root["width"] as? Double) ?? 1170,
                       height: (root["height"] as? Double) ?? 2532,
                       lines: lines, bubbles: bubbles, dropped: dropped)
    }

    static func compare(_ result: SegmentResult, _ fixture: Fixture) -> [String] {
        var problems: [String] = []
        if result.bubbles.count != fixture.bubbles.count {
            problems.append("气泡数 \(result.bubbles.count) ≠ \(fixture.bubbles.count)")
        }
        for (i, want) in fixture.bubbles.enumerated() where i < result.bubbles.count {
            let got = result.bubbles[i]
            if got.side != want.side { problems.append("[\(i)] 归属 \(got.side) ≠ \(want.side)") }
            if got.text != want.text { problems.append("[\(i)] 文字 \(got.text) ≠ \(want.text)") }
            if got.sender != want.sender { problems.append("[\(i)] 发送者 \(got.sender) ≠ \(want.sender)") }
        }
        if result.dropped.count != fixture.dropped.count {
            problems.append("chrome 数 \(result.dropped.count) ≠ \(fixture.dropped.count)")
        }
        for (i, want) in fixture.dropped.enumerated() where i < result.dropped.count {
            let got = result.dropped[i]
            if got.region != want.region || got.text != want.text {
                problems.append("[\(i)] chrome \(got.region)/\(got.text) ≠ \(want.region)/\(want.text)")
            }
        }
        return problems
    }
}