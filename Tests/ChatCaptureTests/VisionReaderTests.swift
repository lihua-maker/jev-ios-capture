import XCTest
import CoreGraphics
@testable import ChatCapture

/// End-to-end proof that the in-process recogniser + segmenter produce a usable transcript from the
/// corpus screenshots — the same code path the app runs on a phone, minus the phone.
///
/// Skipped images are reported, not hidden: if a shot cannot be decoded the test fails rather than
/// passing on an empty set.
final class VisionReaderTests: XCTestCase {

    /// <repo>/shots, located relative to this file so it works from any build directory.
    private func corpusDirectory() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)                 // <repo>/Tests/ChatCaptureTests/X.swift
        let repoRoot = thisFile
            .deletingLastPathComponent()                               // Tests/ChatCaptureTests
            .deletingLastPathComponent()                               // Tests
            .deletingLastPathComponent()                               // <repo>
        let shots = repoRoot.appendingPathComponent("shots")
        guard FileManager.default.fileExists(atPath: shots.path) else {
            throw XCTSkip("corpus screenshots not found at \(shots.path)")
        }
        return shots
    }

    func testReaderProducesLinesForEveryCorpusShot() throws {
        let shots = try corpusDirectory()
        let images = try FileManager.default.contentsOfDirectory(at: shots, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(images.count, 12, "corpus is unexpectedly small")

        let reader = VisionTextReader()
        for image in images {
            let document = try reader.read(url: image)
            XCTAssertGreaterThan(document.lines.count, 3,
                                 "\(image.lastPathComponent): no usable text was recognised")
            // The corpus covers 375/390/430pt-wide devices at 3x; anything below 1125px wide means
            // the image was resampled, which is the one thing this stage must never do.
            XCTAssertTrue([1125.0, 1170.0, 1290.0].contains(document.width),
                          "\(image.lastPathComponent): unexpected width \(document.width) — native 3x expected")
            XCTAssertEqual(document.height / document.width, 2.165, accuracy: 0.01,
                           "\(image.lastPathComponent): unexpected aspect ratio")
        }
    }

    func testTheWholeCapturePathReconstructsAKnownConversation() throws {
        let shots = try corpusDirectory()
        let reader = VisionTextReader()
        let document = try reader.read(url: shots.appendingPathComponent("s01_1v1_light_short.png"))
        let result = BubbleSegmenter.segment(document)

        XCTAssertEqual(result.bubbles.count, 4)
        XCTAssertEqual(result.bubbles.map { $0.text },
                       ["小陈，在吗？", "有个急事，今晚必须处理完", "李经理您好，具体是什么事？", "你手上的活先放一放"])
        XCTAssertEqual(result.bubbles.map { $0.side }, [.them, .them, .me, .them])
        XCTAssertTrue(result.dropped.contains { $0.region == "statusbar_nav_banner" })
        XCTAssertFalse(result.dropped.contains { $0.region == "banner_overlay" },
                       "the top bar must be caught by the nav band, not the banner rule")
    }

    func testNativeResolutionIsWhatMakesTheDifference() throws {
        // The 1x capture is in the corpus of fixtures: the same page, downscaled, loses accuracy and
        // invents bubbles out of avatar artwork. Re-asserting the geometry here keeps the "never
        // downscale" rule attached to the reader that the app actually calls.
        let shots = try corpusDirectory()
        let reader = VisionTextReader()
        let document = try reader.read(url: shots.appendingPathComponent("s09_banner_and_badge.png"))
        XCTAssertEqual(document.width, 1170, "the app must feed the reader native-resolution pixels")
    }
}