import Vision

enum TextRecognition: Sendable {
    struct OCRSnapshot: Sendable {
        /// All recognized text pooled together.
        var combinedText: String
        var topStripText: String
        var averageConfidence: Float
    }

    /// Reads index corner typography and a full-card pass for on-screen typography.
    static func extract(cardCrop: CGImage) -> OCRSnapshot {
        let strip = VNRecognizeTextRequest()
        strip.recognitionLevel = .accurate
        strip.usesLanguageCorrection = false
        /// Vision origin is bottom-left; this targets the visually “upper” indexing corner.
        strip.regionOfInterest = CGRect(x: 0.03, y: 0.64, width: 0.5, height: 0.35)

        let full = VNRecognizeTextRequest()
        full.recognitionLevel = .accurate
        full.usesLanguageCorrection = false
        full.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

        let handler = VNImageRequestHandler(cgImage: cardCrop, orientation: .up, options: [:])
        try? handler.perform([strip, full])

        let top = summarize(strip.results)
        let whole = summarize(full.results)

        let combined = [top.text, whole.text].filter { !$0.isEmpty }.joined(separator: "\n")

        let averageConfidence: Float
        let confs = [top.avg, whole.avg].filter { $0 > 0 }
        averageConfidence = confs.isEmpty ? 0 : confs.reduce(0, +) / Float(confs.count)

        return OCRSnapshot(combinedText: combined, topStripText: top.text, averageConfidence: averageConfidence)
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
            guard let candidate = obs.topCandidates(1).first else { continue }
            strings.append(candidate.string)
            confidences.append(candidate.confidence)
        }

        let text = strings.joined(separator: " ")
        guard confidences.isEmpty == false else { return ("", 0) }
        let avg = confidences.reduce(0, +) / Float(confidences.count)
        return (text, avg)
    }
}
