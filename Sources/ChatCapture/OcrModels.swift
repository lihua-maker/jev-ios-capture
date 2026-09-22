import Foundation

/// One recognised text line. This is the ONLY thing the capture stage needs from a recogniser,
/// which is what makes the rules below engine-independent.
public struct OcrLine: Codable, Equatable {
    public let text: String
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    /// Per-line recogniser confidence. `VNRecognizedTextObservation.confidence` on iOS;
    /// rules R8 ("this bubble could not be read") depends on it.
    public let conf: Double?

    public init(text: String, x: Double, y: Double, w: Double, h: Double, conf: Double? = nil) {
        self.text = text; self.x = x; self.y = y; self.w = w; self.h = h; self.conf = conf
    }
}

/// The recogniser's output for one screenshot, in pixels, top-left origin.
public struct OcrDocument: Codable {
    public let width: Double
    public let height: Double
    public let lines: [OcrLine]

    public init(width: Double, height: Double, lines: [OcrLine]) {
        self.width = width; self.height = height; self.lines = lines
    }
}

public enum Side: String, Codable {
    case them   // left-aligned bubble: the other party (or a named member in a group)
    case me     // right-aligned bubble: the user
}

/// One chat message as reconstructed from the screen.
public struct Bubble: Codable, Equatable {
    public let side: Side
    /// Display name from a group-chat label, `"them"` when unnamed, `"me"` for the user.
    public let sender: String
    /// Body text. Empty when the recogniser produced no usable text for this bubble (see R8).
    public let text: String
    /// Quoted block that precedes the body in the same bubble (WeChat 引用回复), else "".
    public let quote: String
    /// Top of the first line, pixels.
    public let y: Double
}

/// A line that was classified as screen chrome rather than message text.
public struct DroppedLine: Codable, Equatable {
    public let region: String
    public let text: String
}

public struct SegmentResult {
    public let bubbles: [Bubble]
    public let dropped: [DroppedLine]
}