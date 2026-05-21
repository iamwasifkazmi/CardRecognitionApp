#if canImport(MLKitTextRecognition) && canImport(UIKit)
import CoreGraphics
import Foundation
import MLKitTextRecognition
import MLKitVision
import UIKit

/// Google ML Kit Text Recognition (Latin) — loaded via CocoaPods `GoogleMLKit/TextRecognition`.
enum GoogleMLKitOCR: Sendable {
    struct Recognition: Sendable {
        var text: String
        var averageConfidence: Float
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recognizer: TextRecognizer?

    static var isAvailable: Bool { true }

    static func recognize(cgImage: CGImage) -> Recognition {
        let textRecognizer = sharedRecognizer()
        let visionImage = VisionImage(image: UIImage(cgImage: cgImage))
        visionImage.orientation = .up

        var output = Recognition(text: "", averageConfidence: 0)
        let semaphore = DispatchSemaphore(value: 0)

        textRecognizer.process(visionImage) { result, error in
            defer { semaphore.signal() }
            if let error {
                SlotRecognitionDiagnostics.log("MLKit OCR: \(error.localizedDescription)")
                return
            }
            guard let result else { return }

            var lines: [String] = []
            for block in result.blocks {
                for line in block.lines {
                    let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard t.isEmpty == false else { continue }
                    lines.append(t)
                }
            }

            let text = lines.joined(separator: " ")
            /// ML Kit v6 `TextLine` has no `confidence` — use a fixed score when text is present.
            let avg: Float = text.isEmpty ? 0 : 0.78
            output = Recognition(text: text, averageConfidence: avg)
        }

        semaphore.wait()
        return output
    }

    private static func sharedRecognizer() -> TextRecognizer {
        lock.lock()
        defer { lock.unlock() }
        if let recognizer { return recognizer }
        let created = TextRecognizer.textRecognizer(options: TextRecognizerOptions())
        recognizer = created
        return created
    }
}
#endif
