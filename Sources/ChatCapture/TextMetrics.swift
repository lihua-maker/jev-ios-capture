import Foundation

/// Text measurements the segmentation rules depend on.
///
/// Two of these are load-bearing and easy to get wrong:
///  * `norm` — comparison/normalisation used for every length and equality test.
///  * `advance` — the per-character advance width, which is how font size is measured. Ink
///    height is useless for this: full-width punctuation makes a 12pt quote line measure
///    TALLER than 16pt body text (measured: 50px vs 47px at 3x).
enum TextMetrics {

    /// Punctuation dropped before comparison. Colons are KEPT (they carry meaning in times).
    static let strip: Set<Character> = Set("，。？、！…;；·.．,'’‘\"″“”")

    /// Glyphs that a recogniser emits for icon/badge artwork rather than for text.
    static let glyphs: Set<Character> = Set("0OoQ●○·.,-—~|[](){}<>「」/\\")

    static func norm(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.filter { ch in
            !ch.isWhitespace && !strip.contains(ch)
        }
    }

    /// Per-character advance weight: CJK/full-width ~1.0, Latin/digit ~0.55.
    static func weight(_ t: String) -> Double {
        var sum = 0.0
        for ch in t {
            let scalar = ch.unicodeScalars.first?.value ?? 0
            sum += scalar < 0x2E80 ? 0.55 : 1.0
        }
        return sum == 0 ? 1.0 : sum
    }

    /// Estimated font size in pixels for this line.
    static func advance(_ ln: OcrLine) -> Double {
        ln.w / weight(ln.text)
    }

    /// True when every character is icon artwork rather than text ("0", "·", "]" …).
    static func isGlyphish(_ normalized: String) -> Bool {
        !normalized.isEmpty && normalized.allSatisfy { glyphs.contains($0) }
    }
}