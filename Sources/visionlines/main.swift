// visionlines — run Apple's Vision text recogniser over a folder of screenshots and emit
// line boxes in the SAME JSON shape the Windows/offline pipeline uses, so the two engines can
// be compared with one evaluator:
//
//   {"width":1170,"height":2532,"engine":"apple-vision",
//    "lines":[{"text":"小陈，在吗？","x":217.0,"y":465.0,"w":262.0,"h":47.0,"conf":0.9}]}
//
// x/y are the TOP-LEFT corner in pixels (Vision's boundingBox is normalised with a
// bottom-left origin, hence the flip). "conf" is extra information the iOS pipeline needs
// for the unreadable-bubble path; the evaluator ignores unknown keys.
//
// usage: visionlines <in-dir> <out-dir>

import Foundation
import Vision
import ImageIO
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: visionlines <in-dir> <out-dir>\n".utf8))
    exit(2)
}
let inDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let exts: Set<String> = ["png", "jpg", "jpeg", "heic"]
let entries = (try? FileManager.default.contentsOfDirectory(at: inDir,
                                                            includingPropertiesForKeys: nil)) ?? []
let images = entries
    .filter { exts.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !images.isEmpty else {
    FileHandle.standardError.write(Data("no images found in \(inDir.path)\n".utf8))
    exit(3)
}

func round1(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }

var failures = 0
for img in images {
    guard let source = CGImageSourceCreateWithURL(img as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("SKIP  \(img.lastPathComponent): cannot decode")
        failures += 1
        continue
    }
    let width = cgImage.width
    let height = cgImage.height

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
    } catch {
        print("FAIL  \(img.lastPathComponent): \(error)")
        failures += 1
        continue
    }

    var lines: [[String: Any]] = []
    for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let bb = observation.boundingBox          // normalised, origin bottom-left
        lines.append([
            "text": candidate.string,
            "x": round1(bb.minX * CGFloat(width)),
            "y": round1((1 - bb.maxY) * CGFloat(height)),
            "w": round1(bb.width * CGFloat(width)),
            "h": round1(bb.height * CGFloat(height)),
            "conf": (Double(candidate.confidence) * 1000).rounded() / 1000,
        ])
    }

    let payload: [String: Any] = [
        "width": width,
        "height": height,
        "engine": "apple-vision",
        "lines": lines,
    ]
    let outURL = outDir.appendingPathComponent(
        img.deletingPathExtension().lastPathComponent + ".ocr.json")
    do {
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outURL)
        print("OK    \(img.lastPathComponent) -> \(outURL.lastPathComponent)  \(width)x\(height)  lines=\(lines.count)")
    } catch {
        print("FAIL  write \(outURL.path): \(error)")
        failures += 1
    }
}

if failures > 0 {
    FileHandle.standardError.write(Data("\(failures) image(s) failed\n".utf8))
    exit(1)
}