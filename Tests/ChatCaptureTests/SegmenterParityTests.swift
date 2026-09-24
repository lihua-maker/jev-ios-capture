import XCTest
@testable import ChatCapture

/// Parity tests: the Swift segmenter must reproduce the validated Python reference EXACTLY on the
/// same line boxes. Fixtures come from `make_fixtures.py` — 12 screenshots through each of three
/// font/recogniser combinations (Apple Vision over Windows-rendered PNGs, Apple Vision over
/// macOS-rendered PNGs i.e. PingFang SC, Windows OCR in Microsoft YaHei) plus the 1x capture where
/// artwork really was recognised as text — so a port bug cannot hide behind "the engine or the font
/// behaves differently".
///
/// The rule tests below were written by running the reference implementation on the same inputs
/// first; every expected value here is measured output, not intuition.
final class SegmenterParityTests: XCTestCase {

    struct Fixture: Decodable {
        struct Expected: Decodable {
            struct Bubble: Decodable {
                let side: String
                let sender: String
                let text: String
                let quote: String
            }
            struct Dropped: Decodable {
                let region: String
                let text: String
            }
            let bubbles: [Bubble]
            let dropped: [Dropped]
        }
        let id: String
        let engine: String
        let width: Double
        let height: Double
        let lines: [OcrLine]
        let expected: Expected
    }

    private func line(_ t: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> OcrLine {
        OcrLine(text: t, x: x, y: y, w: w, h: h)
    }

    // MARK: - Fixture parity

    func testSegmenterMatchesReferenceOnEveryFixture() throws {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil),
                                "Fixtures directory missing from the test bundle")
        let files = try FileManager.default.contentsOfDirectory(at: dir,
                                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(files.count, 24, "fixture set unexpectedly small")

        var checked = 0
        var engines = Set<String>()
        for file in files {
            let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
            let tag = "\(fx.engine)/\(fx.id)"
            engines.insert(fx.engine)

            let result = BubbleSegmenter.segment(
                OcrDocument(width: fx.width, height: fx.height, lines: fx.lines))

            XCTAssertEqual(result.bubbles.count, fx.expected.bubbles.count,
                           "\(tag): bubble count")
            for (i, exp) in fx.expected.bubbles.enumerated() where i < result.bubbles.count {
                let got = result.bubbles[i]
                XCTAssertEqual(got.side.rawValue, exp.side, "\(tag) bubble \(i): side")
                XCTAssertEqual(got.sender, exp.sender, "\(tag) bubble \(i): sender")
                XCTAssertEqual(got.text, exp.text, "\(tag) bubble \(i): text")
                XCTAssertEqual(got.quote, exp.quote, "\(tag) bubble \(i): quote")
            }
            XCTAssertEqual(result.dropped.count, fx.expected.dropped.count,
                           "\(tag): dropped chrome count")
            for (i, exp) in fx.expected.dropped.enumerated() where i < result.dropped.count {
                XCTAssertEqual(result.dropped[i].region, exp.region, "\(tag) dropped \(i): region")
                XCTAssertEqual(result.dropped[i].text, exp.text, "\(tag) dropped \(i): text")
            }
            checked += 1
        }
        XCTAssertEqual(engines, ["vision", "visionmac", "windows", "windows1x"],
                       "every font/recogniser combination must be covered")
        print("parity OK: \(checked) fixtures across \(engines.sorted())")
    }

    // MARK: - The rules this port exists for

    /// R2 — the system-line filter needs all three conditions, and the third one is not decoration.
    ///
    /// A real "21:38" divider is centred to within 0.0021*W of the screen centre, while the closest
    /// small line INSIDE a bubble (a quote block, a voice transcript) sits at 0.0479*W. Size alone
    /// cannot decide this: the ink-height ratio against a global median flipped 0.73 -> 0.89 when
    /// the same HTML was rendered in PingFang SC instead of Microsoft YaHei, and a divider grew
    /// into a bubble. Geometry alone cannot decide it either — see the test below.
    func testSystemLineFilterSeparatesDividersFromSmallTextInsideBubbles() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("那个款项你考虑得怎么样", 214, 545, 541, 59),        // body, sets the body advance
            line("以下是新消息", 482, 780, 205, 45),                  // 12pt, dead centre
            line("转文字：明天记得把合同带过来", 214, 900, 560, 45),   // 12pt, inside a bubble
        ]))
        XCTAssertEqual(result.dropped.map { $0.region }, ["timesep_or_system"])
        XCTAssertEqual(result.dropped.first?.text, "以下是新消息")
        XCTAssertTrue(result.bubbles.contains { $0.text.contains("转文字") },
                      "small text inside a bubble is conversation, not chrome")
    }

    /// R2 again — the case that rules out a pure-geometry filter.
    ///
    /// In a right-aligned bubble whose lines differ in width, the narrower lines float off the
    /// right rail, so a real message line can land on the screen centre: s08's
    /// "我今天下午六点前发您" measures 0.0017*W off centre with a 0.42*W box. Only the advance
    /// condition keeps it, because it is set at body size.
    func testNarrowBodyLineInARightAlignedBubbleIsNotASystemLine() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("那个款项你考虑得怎么样", 214, 545, 541, 59),
            line("我今天下午六点前发您", 341, 900, 492, 59),
        ]))
        XCTAssertTrue(result.dropped.isEmpty, "a body-sized line is never a system line")
        XCTAssertEqual(result.bubbles.count, 2)
    }

    /// R5c — a wrapped continuation line of a RIGHT-anchored bubble is not the other person.
    ///
    /// The bubble is right-anchored, so a last line that wrapped short is inset on the right and its
    /// ink centre drifts left of the screen centre: measured 0.036*W left of the middle at 14px body.
    /// Attributing it to the counterparty is the error that makes the model describe the user's own
    /// words as someone else's, so the clustering inherits the open bubble's side for such a line.
    func testWrappedContinuationLineStaysWithTheUser() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("好的王姐，我今天下班前改完发", 312, 678, 587, 41),
            line("您，另外付款条款那部分我想跟您", 313, 738, 629, 41),
            line("确认一下时间节点的口径", 312, 799, 462, 41),   // centre 543: left of 585
        ]))
        XCTAssertEqual(result.bubbles.count, 1, "one wrapped message, not a message plus a fragment")
        XCTAssertEqual(result.bubbles.first?.side, .me)
        XCTAssertEqual(result.bubbles.first?.text, "好的王姐，我今天下班前改完发您，另外付款条款那部分我想跟您确认一下时间节点的口径")
    }

    /// R2 — the size threshold that separates body text from secondary text must FOLLOW the body
    /// size, not sit at a constant.
    ///
    /// 0.85 assumes secondary text is at least 15% smaller than body, which is only true at the
    /// default type size. A 12px timestamp over a 14px body measures 0.857 and escaped: at a 14px or
    /// 18px body font the corpus leaked a chrome line into the transcript (s04, s08) and lost a
    /// quote block, with the device's recogniser. The threshold is now the midpoint between the
    /// measured body size (recovered as advance/W, which is scale-invariant) and the 12px secondary
    /// size the apps use.
    func testSecondarySizeThresholdFollowsTheBodySize() {
        XCTAssertEqual(BubbleSegmenter.secondaryThreshold(48, 1170), 0.875, accuracy: 0.005)
        XCTAssertEqual(BubbleSegmenter.secondaryThreshold(42, 1170), 0.929, accuracy: 0.005)
        XCTAssertEqual(BubbleSegmenter.secondaryThreshold(54, 1170), 0.833, accuracy: 0.005)
    }

    /// R2 again — at a 14px body, a 12px centred timestamp is still chrome, and the small text
    /// INSIDE a bubble at 12px is still conversation. Both are 0.857 and 0.857 of the body advance.
    func testSecondaryTextIsClassifiedByTheMeasuredBodySize() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("那个款项你考虑得怎么样", 214, 600, 462, 41),      // 14px body: 42px per character
            line("21:38", 535.5, 500, 99, 30),                    // 12px, dead centre -> chrome
            line("转文字：明天记得把合同带过来", 214, 700, 468, 41), // 12px, inside a bubble -> conversation
        ]))
        XCTAssertEqual(result.dropped.map { $0.region }, ["timesep_or_system"])
        XCTAssertEqual(result.dropped.first?.text, "21:38")
        XCTAssertEqual(result.bubbles.map { $0.text },
                       ["那个款项你考虑得怎么样", "转文字：明天记得把合同带过来"])
    }

    /// R3 — a lone CJK character is a message, not icon artwork.
    func testSingleCharacterMessageSurvivesTheHallucinationFilter() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("行", 216, 800, 47, 47),
        ]))
        XCTAssertEqual(result.bubbles.count, 1)
        XCTAssertEqual(result.bubbles.first?.text, "行")
        XCTAssertEqual(result.bubbles.first?.side, Side.them)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    /// R1/R1b/R2/R3 on one realistic screen: chrome bands, the centred timestamp, avatar and
    /// unread-badge artwork read as text, and the input bar.
    func testChromeAndArtworkAreRemovedButMessagesSurvive() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("21:47", 68, 50, 112, 34),            // status bar
            line("对方正在输入…", 480, 180, 210, 40),    // nav bar (typing indicator)
            line("21:38", 520, 350, 90, 29),           // centred timestamp
            line("小陈，在吗？", 216, 465, 262, 47),
            line("有个急事，今晚必须处理完", 216, 625, 574, 47),
            line("0", 40, 800, 36, 30),                // avatar block read as text
            line("3", 150, 760, 36, 30),               // unread badge
            line("李经理您好", 800, 1100, 200, 47),      // the user's own message
            line("输入消息…", 73, 2430, 200, 44),        // input bar
        ]))
        XCTAssertEqual(result.bubbles.map { $0.text },
                       ["小陈，在吗？", "有个急事，今晚必须处理完", "李经理您好"])
        XCTAssertEqual(result.bubbles.map { $0.side }, [.them, .them, .me])
        XCTAssertEqual(result.dropped.map { $0.region },
                       ["statusbar_nav_banner", "statusbar_nav_banner", "timesep_or_system",
                        "icon_or_badge", "icon_or_badge", "inputbar"])
    }

    /// R1b — a notification banner sits below the nav band and is inset left of the message rail.
    func testNotificationBannerBelowTheNavBandIsNotAMessage() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("王姐：合同改好了吗", 160.9, 243, 375.4, 44.3),
            line("在忙吗", 214.5, 340.8, 151.1, 58.4),
        ]))
        XCTAssertEqual(result.bubbles.count, 1)
        XCTAssertEqual(result.bubbles.first?.text, "在忙吗")
        XCTAssertEqual(result.dropped.map { $0.region }, ["banner_overlay"])
    }

    /// R5c — a right-aligned bubble's wrapped trailing fragment lands on the wrong half of the
    /// screen; it must come back, and stay attributed to the user.
    func testRightAlignedWrappedFragmentIsAbsorbedAndStaysWithTheUser() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("垫款的话我需要走一下审批流", 307.1, 988, 633.8, 59),
            line("程", 307.1, 1056.6, 58.5, 58.4),
        ]))
        XCTAssertEqual(result.bubbles.count, 1)
        XCTAssertEqual(result.bubbles.first?.side, Side.me)
        XCTAssertEqual(result.bubbles.first?.text, "垫款的话我需要走一下审批流程")
    }

    /// R6 — the quoted block is separated from the body because it precedes it (and because ink
    /// height cannot measure font size: see the card footer below).
    func testQuoteBlockIsSeparatedWhenItPrecedesTheBody() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("李经理：你能不能今天就把方案发我", 354, 493, 600, 50),
            line("我今天下午六点前发您", 354, 574, 480, 47),
        ]))
        XCTAssertEqual(result.bubbles.count, 1)
        XCTAssertEqual(result.bubbles.first?.quote, "李经理：你能不能今天就把方案发我")
        XCTAssertEqual(result.bubbles.first?.text, "我今天下午六点前发您")
    }

    /// R4 — the group-chat sender label is a smaller line above the bubble.
    func testGroupSenderLabelIsAttributedToItsBubble() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("王姐", 187, 433, 65, 31),
            line("今天的联调结果出来了", 216, 518, 477, 47),
        ]))
        XCTAssertEqual(result.bubbles.count, 1)
        XCTAssertEqual(result.bubbles.first?.sender, "王姐")
        XCTAssertEqual(result.bubbles.first?.text, "今天的联调结果出来了")
    }

    /// R5b — a card's footer starts further left and further away than a normal line pitch, and
    /// must stay with the card (a 15pt title over a 14pt amount is also why R4's margin is 0.88).
    func testCardFooterStaysWithItsCard() {
        let result = BubbleSegmenter.segment(OcrDocument(width: 1170, height: 2532, lines: [
            line("转账", 346, 505, 83, 41),
            line("¥2980.00", 355, 570, 203, 36),
            line("请收款", 217, 673, 107, 35),
            line("收到了", 812, 818, 138, 46),
        ]))
        XCTAssertEqual(result.bubbles.count, 2)
        XCTAssertEqual(result.bubbles.first?.text, "转账¥2980.00请收款")
        XCTAssertEqual(result.bubbles.first?.side, Side.them)
        XCTAssertEqual(result.bubbles.last?.side, Side.me)
    }

    /// R5 — the merge threshold adapts to the recogniser's box metrics.
    func testAdaptiveSplitThresholdFollowsTheGapDistribution() {
        // Same screen measured two ways: Vision's taller boxes produce smaller gaps.
        XCTAssertEqual(BubbleSegmenter.gapThreshold([14, 96.6, 145], 58), 55.3, accuracy: 0.05)
        XCTAssertEqual(BubbleSegmenter.gapThreshold([67, 110, 112], 46), 88.5, accuracy: 0.05)
        // Unimodal (every bubble a single line) → fall back to the line-height rule.
        XCTAssertEqual(BubbleSegmenter.gapThreshold([], 47), 1.2 * 47, accuracy: 0.001)
        XCTAssertEqual(BubbleSegmenter.gapThreshold([5, 6], 47), 1.2 * 47, accuracy: 0.001)
    }
}