// visionlines — measure Apple's recogniser over a folder of screenshots and emit line boxes in the
// same JSON shape the offline pipeline uses, so both engines can be compared with one evaluator.
//
// The recognition itself lives in the ChatCapture package (`VisionTextReader`), so the code path CI
// measures is exactly the one the iOS app runs.
//
//   usage: visionlines <in-dir> <out-dir>

import Foundation
import ChatCapture

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: visionlines <in-dir> <out-dir>\n".utf8))
    exit(2)
}
let inDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let exts: Set<String> = ["png", "jpg", "jpeg", "heic"]
let images = ((try? FileManager.default.contentsOfDirectory(at: inDir,
                                                            includingPropertiesForKeys: nil)) ?? [])
    .filter { exts.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !images.isEmpty else {
    FileHandle.standardError.write(Data("no images found in \(inDir.path)\n".utf8))
    exit(3)
}

let reader = VisionTextReader()
var failures = 0

for image in images {
    do {
        let document = try reader.read(url: image)
        let payload: [String: Any] = [
            "width": document.width,
            "height": document.height,
            "engine": "apple-vision",
            "lines": document.lines.map { line -> [String: Any] in
                var out: [String: Any] = [
                    "text": line.text, "x": line.x, "y": line.y, "w": line.w, "h": line.h,
                ]
                if let conf = line.conf { out["conf"] = (conf * 1000).rounded() / 1000 }
                return out
            },
        ]
        let outURL = outDir.appendingPathComponent(
            image.deletingPathExtension().lastPathComponent + ".ocr.json")
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outURL)
        print("OK    \(image.lastPathComponent) -> \(outURL.lastPathComponent)  "
              + "\(Int(document.width))x\(Int(document.height))  lines=\(document.lines.count)")
    } catch {
        print("FAIL  \(image.lastPathComponent): \(error)")
        failures += 1
    }
}

if failures > 0 {
    FileHandle.standardError.write(Data("\(failures) image(s) failed\n".utf8))
    exit(1)
}