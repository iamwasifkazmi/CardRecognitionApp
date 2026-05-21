import CoreGraphics
import Vision

/// Apple Vision OCR — fallback when ML Kit is not linked (macOS) or returns empty.
enum VisionOCRBackend: Sendable {
    struct Recognition: Sendable {
        var text: String
        var averageConfidence: Float
    }

    private static let suitGlyphCustomWords = [
        "♠", "♥", "♦", "♣", "♤", "♡", "♢", "♧",
        "S", "H", "D", "C", "s", "h", "d", "c",
        "spades", "hearts", "diamonds", "clubs",
    ]

    static func recognize(cgImage: CGImage, options: OCREngine.Options) -> Recognition {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = options.accurate ? .accurate : .fast
        req.usesLanguageCorrection = false
        req.recognitionLanguages = ["en-US"]
        req.minimumTextHeight = options.minimumTextHeight
        if options.suitGlyphLexicon {
            req.customWords = suitGlyphCustomWords
        }
        req.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([req])
        let summary = summarize(req.results)
        return Recognition(text: summary.text, averageConfidence: summary.avg)
    }

    private static func summarize(_ observations: [VNRecognizedTextObservation]?) -> (text: String, avg: Float) {
        guard let observations, observations.isEmpty == false else {
            return ("", 0)
        }

        var strings: [String] = []
        strings.reserveCapacity(observations.count)
        var confidences: [Float] = []
        confidences.reserveCapacity(observations.count)

        for obs in observations {
            let candidates = obs.topCandidates(3)
            guard candidates.isEmpty == false else { continue }
            strings.append(candidates.map(\.string).joined(separator: " "))
            let sliceAvg = candidates.reduce(Float(0)) { $0 + $1.confidence } / Float(candidates.count)
            confidences.append(sliceAvg)
        }

        let text = strings.joined(separator: " ")
        guard confidences.isEmpty == false else { return ("", 0) }
        let avg = confidences.reduce(0, +) / Float(confidences.count)
        return (text, avg)
    }
}
