/// Public comparison helpers.
///
/// Kept deliberately narrow: the segmentation internals (`TextMetrics`) stay internal, but the app
/// needs one primitive to check this device's recogniser against the recorded expectation.
public enum TextCompare {
    /// Character-level agreement, 1.0 when identical after punctuation/whitespace normalisation.
    public static func similarity(_ a: String, _ b: String) -> Double {
        TextMetrics.similarity(a, b)
    }
}
