import Foundation
import CoreGraphics
import ImageIO
import Vision

/// The in-process recogniser: an image becomes line boxes, nothing else.
///
/// This is the piece the app needs and the CLI harness shares, so the same code path that CI
/// measures is the one that runs on a phone.
public struct VisionTextReader {

    public enum ReaderError: Error, CustomStringConvertible {
        case cannotDecode(URL)
        case recognitionFailed(String)

        public var description: String {
            switch self {
            case .cannotDecode(let url): return "cannot decode an image at \(url.lastPathComponent)"
            case .recognitionFailed(let why): return "text recognition failed: \(why)"
            }
        }
    }

    public let languages: [String]
    public let recognitionLevel: VNRequestTextRecognitionLevel

    public init(languages: [String] = ["zh-Hans", "en-US"],
                recognitionLevel: VNRequestTextRecognitionLevel = .accurate) {
        self.languages = languages
        self.recognitionLevel = recognitionLevel
    }

    /// Recognise text in an already-decoded image. **Pass the native-resolution screenshot**:
    /// measured on the same page, 3x gave 9/9 bubbles and 97.7% character accuracy while the 1x
    /// version gave 16 bubbles (seven read out of the avatar squares) and 86.9%.
    public func read(_ image: CGImage) throws -> OcrDocument {
        let width = Double(image.width)
        let height = Double(image.height)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw ReaderError.recognitionFailed(error.localizedDescription)
        }

        var lines: [OcrLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox          // normalised, bottom-left origin
            lines.append(OcrLine(
                text: candidate.string,
                x: round1(box.minX * CGFloat(width)),
                y: round1((1 - box.maxY) * CGFloat(height)),
                w: round1(box.width * CGFloat(width)),
                h: round1(box.height * CGFloat(height)),
                conf: Double(candidate.confidence)))
        }
        return OcrDocument(width: width, height: height, lines: lines)
    }

    public func read(url: URL) throws -> OcrDocument {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ReaderError.cannotDecode(url)
        }
        return try read(image)
    }

    private func round1(_ value: CGFloat) -> Double {
        (Double(value) * 10).rounded() / 10
    }
}