import Foundation

/// Screenshot → ordered chat transcript. A direct port of the validated Python reference
/// (`capture.py`); every rule below carries the measurement that forced it — see PORT_SPEC.md.
///
/// Deliberately engine-independent: Apple Vision's ink boxes are ~25% taller than Windows OCR's
/// for identical text (59px vs 47px at 3x), so any rule with a fixed multiple of the line height
/// silently breaks on one of them. This port is verified against 24 fixture sets (12 screenshots
/// × 2 recognisers) that the Python reference produced.
public enum BubbleSegmenter {

    // MARK: - R5 threshold

    /// Split consecutive-line gaps into "same bubble" vs "new bubble" adaptively.
    ///
    /// The gap distribution on a chat screen is bimodal (in-bubble line pitch vs between-bubble
    /// margin) and the modes move with the recogniser, so cut at the largest relative jump.
    /// Measured on one screenshot: Vision 55.3px, Windows 88.5px — each correct for its own
    /// metrics, where a fixed `1.9 × medianHeight` merged three bubbles into one under Vision.
    static func gapThreshold(_ gaps: [Double], _ medH: Double) -> Double {
        let g = gaps.filter { $0 >= 0 }.sorted()
        var thresh: Double?
        if g.count >= 3 {
            var bestRatio = 1.0
            var bestI: Int?
            for i in 0..<(g.count - 1) {
                let ratio = (g[i + 1] + 1) / (g[i] + 1)
                if ratio > bestRatio { bestRatio = ratio; bestI = i }
            }
            if let bi = bestI, bestRatio >= 1.4 {
                thresh = (g[bi] + g[bi + 1]) / 2
            }
        }
        let t = thresh ?? (1.2 * medH)
        return min(max(t, 0.5 * medH), 2.6 * medH)
    }

    static func medianHeight(_ lines: [OcrLine]) -> Double {
        let hs = lines.map { $0.h }.sorted()
        return hs.isEmpty ? 1 : hs[hs.count / 2]
    }

    // MARK: - Open bubble (mutable while lines are being attached)

    private struct Partial {
        var side: Side
        var lines: [OcrLine]
        var label: String?
        var x0: Double, x1: Double
        var y0: Double, h0: Double
        var w: Double
        var y: Double
    }

    // MARK: - Segment

    public static func segment(_ doc: OcrDocument) -> SegmentResult {
        let W = doc.width, H = doc.height

        // Stable sort by y, matching the reference implementation exactly: equal-y lines must keep
        // their input order, and Swift's sort is not stable.
        let sorted = doc.lines.enumerated()
            .sorted { a, b in
                a.element.y == b.element.y ? a.offset < b.offset : a.element.y < b.element.y
            }
            .map { $0.element }

        var dropped: [DroppedLine] = []
        var kept: [OcrLine] = []
        guard !sorted.isEmpty else { return SegmentResult(bubbles: [], dropped: dropped) }
        var medH = medianHeight(sorted)

        for ln in sorted {
            let cx = ln.x + ln.w / 2
            let cy = ln.y + ln.h / 2
            let tn = TextMetrics.norm(ln.text)

            // R1 — status bar (44pt) + nav bar (44pt) = 88pt of a 320…440pt-wide screen.
            if cy < 0.226 * W {
                dropped.append(DroppedLine(region: "statusbar_nav_banner", text: ln.text)); continue
            }
            // R1b — a notification banner insets its text left of the message rail (bubble ink
            // starts ~0.185*W, banner text ~0.137*W) and can sit below the nav band.
            if cy < 0.30 * H && ln.x < 0.15 * W {
                dropped.append(DroppedLine(region: "banner_overlay", text: ln.text)); continue
            }
            // R1 — input bar + home-indicator safe area.
            if cy > H - 0.235 * W {
                dropped.append(DroppedLine(region: "inputbar", text: ln.text)); continue
            }
            // R2 — centred and small: "21:38" timestamp or "以下是新消息" system notice.
            if abs(cx - W / 2) < 0.08 * W && ln.w < 0.6 * W && ln.h <= 0.85 * medH {
                dropped.append(DroppedLine(region: "timesep_or_system", text: ln.text)); continue
            }
            // R3 — icon/badge artwork read as text. A single CJK character is a real message
            // ("行"), so length alone must never disqualify a line.
            let glyphish = TextMetrics.isGlyphish(tn)
            let tinyBadge = tn.count <= 2 && ln.h <= 0.8 * medH && ln.w <= 0.06 * W
            let nearRail = ln.x < 0.135 * W || (ln.x + ln.w) > 0.865 * W
            if nearRail && (glyphish || (tinyBadge && ln.h < 0.9 * medH)) {
                dropped.append(DroppedLine(region: "icon_or_badge", text: ln.text)); continue
            }
            kept.append(ln)
        }

        guard !kept.isEmpty else { return SegmentResult(bubbles: [], dropped: dropped) }
        medH = medianHeight(kept)

        // R4 — sender name labels in group chats.
        // The advance margin is the only thing separating an 11pt name label from a 14pt card
        // title sitting over a 15pt amount: measured labels 0.74–0.85, that card title 0.93.
        var labels: [Int: String] = [:]
        var used = Set<Int>()
        if kept.count >= 2 {
            for i in 0..<(kept.count - 1) {
                let ln = kept[i], nxt = kept[i + 1]
                let gap = nxt.y - (ln.y + ln.h)
                if TextMetrics.advance(ln) < 0.88 * TextMetrics.advance(nxt)
                    && abs(ln.x - nxt.x) < 0.04 * W
                    && gap >= 0 && gap < 1.45 * medH
                    && (ln.x + ln.w / 2) < W / 2
                    && ln.w < 0.4 * W
                    && TextMetrics.norm(ln.text).count <= 8 {
                    labels[i + 1] = ln.text
                    used.insert(i)
                }
            }
        }

        // R5 — per-side gap sample for the adaptive threshold (labels already removed).
        var gaps: [Double] = []
        var prevSide: Side?
        var prevLine: OcrLine?
        for (i, ln) in kept.enumerated() where !used.contains(i) {
            let side: Side = (ln.x + ln.w / 2) < W / 2 ? .them : .me
            if let ps = prevSide, let pl = prevLine, ps == side {
                gaps.append(ln.y - (pl.y + pl.h))
            }
            prevSide = side
            prevLine = ln
        }
        let split = gapThreshold(gaps, medH)

        // R5/R5b — cluster lines into bubbles. The open bubble is always the last one appended.
        var bubbles: [Partial] = []
        for (i, ln) in kept.enumerated() where !used.contains(i) {
            let side: Side = (ln.x + ln.w / 2) < W / 2 ? .them : .me
            if !bubbles.isEmpty, bubbles[bubbles.count - 1].side == side {
                var c = bubbles[bubbles.count - 1]
                let gap = ln.y - (c.y0 + c.h0)
                let xov = min(c.x1, ln.x + ln.w) - max(c.x0, ln.x)
                // R5b — a card's icon indents its title, so its footer line both starts further
                // left and sits further away than a normal line pitch.
                let indented = (c.x0 - ln.x) > 0.04 * W
                if (gap < split || (indented && gap < 2.2 * medH)) && xov > -0.5 * min(c.w, ln.w) {
                    c.lines.append(ln)
                    c.y0 = ln.y
                    c.h0 = ln.h
                    c.x0 = min(c.x0, ln.x)
                    c.x1 = max(c.x1, ln.x + ln.w)
                    c.w = c.x1 - c.x0
                    bubbles[bubbles.count - 1] = c
                    continue
                }
            }
            bubbles.append(Partial(side: side, lines: [ln], label: labels[i], x0: ln.x,
                                   x1: ln.x + ln.w, y0: ln.y, h0: ln.h, w: ln.w, y: ln.y))
        }

        // R5c — orphan absorption. A wrapped trailing fragment can land on the wrong half of the
        // screen and become a bubble attributed to the wrong person (Vision split "…审批流程" into
        // "…审批流" plus a lone "程" at x=307, w=58).
        var absorbed: [Partial] = []
        for b in bubbles {
            if let last = absorbed.last,
               b.lines.count == 1,
               TextMetrics.norm(b.lines[0].text).count <= 3,
               last.side != b.side,
               abs(b.x0 - last.x0) < 0.02 * W,
               b.y0 - (last.y0 + last.h0) >= 0,
               b.y0 - (last.y0 + last.h0) < 2.2 * medH {
                var p = last
                p.lines += b.lines
                p.y0 = b.y0
                p.h0 = b.h0
                p.x0 = min(p.x0, b.x0)
                p.x1 = max(p.x1, b.x1)
                p.w = p.x1 - p.x0
                absorbed[absorbed.count - 1] = p
                continue
            }
            absorbed.append(b)
        }

        // R6/R7 — body vs quote, then attribution.
        var out: [Bubble] = []
        for b in absorbed {
            let lines = b.lines.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            // Font size from the MEDIAN advance of multi-character lines: a lone character's box
            // carries too much padding to measure (Vision: 58.5px advance for a single 你).
            let multi = lines.filter { TextMetrics.norm($0.text).count >= 2 }
                .map { TextMetrics.advance($0) }.sorted()
            let bodyAdv = multi.isEmpty
                ? (lines.map { TextMetrics.advance($0) }.max() ?? 1)
                : multi[multi.count / 2]

            var smallIdx: [Int] = []
            for (i, l) in lines.enumerated()
            where TextMetrics.norm(l.text).count >= 2 && TextMetrics.advance(l) < 0.85 * bodyAdv {
                smallIdx.append(i)
            }
            var bigIdx = Array(0..<lines.count).filter { !smallIdx.contains($0) }
            // A secondary-font block is a quote only when it PRECEDES the body; a card footer or a
            // voice transcript after the body belongs to the body.
            if !smallIdx.isEmpty, !bigIdx.isEmpty, (smallIdx.min() ?? 0) > (bigIdx.max() ?? 0) {
                bigIdx += smallIdx
                smallIdx = []
            }
            out.append(Bubble(side: b.side,
                              sender: b.label ?? (b.side == .me ? "me" : "them"),
                              text: bigIdx.map { lines[$0].text }.joined(),
                              quote: smallIdx.map { lines[$0].text }.joined(),
                              y: (b.y * 10).rounded() / 10))
        }
        return SegmentResult(bubbles: out, dropped: dropped)
    }
}