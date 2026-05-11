import CoreGraphics
import CoreImage
import CoreVideo
import Vision

/// End-to-end slot-machine-style scan: localize up to five rectangular cards and interpret them together.
enum CardVisionPipeline: Sendable {
    struct ScanResult: Sendable {
        var cards: [RecognizedPlayingCard]
    }

    /// Optional Core ML request (e.g. image classifier built via Create ML). Assign before scanning for improved accuracy vs. OCR-only UIs.
    nonisolated(unsafe) static var coreMLClassifierRequest: VNCoreMLRequest?

    static func analyze(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> ScanResult {
        guard let upright = FrameNormalizer.uprightCGImage(pixelBuffer: pixelBuffer, orientation: orientation) else {
            throw CardScanError.couldNotNormalizeFrame
        }
        return try analyzeUpright(cgImage: upright)
    }

    static func analyze(cgImage: CGImage) throws -> ScanResult {
        try analyzeUpright(cgImage: cgImage)
    }

    private static func analyzeUpright(cgImage: CGImage) throws -> ScanResult {
        let observations = try detectCardRectangles(cgImage: cgImage)
        let picks = CardRectangleSelector.select(observations: observations)
        let ciBase = CIImage(cgImage: cgImage)

        var results: [RecognizedPlayingCard] = []
        results.reserveCapacity(5)

        for (idx, pick) in picks.enumerated() {
            let warped: CGImage?
            switch pick {
            case .perspective(let obs):
                warped = PerspectiveCorrection.warpedCardCGImage(base: ciBase, observation: obs)
            case .column(let rect):
                warped = PerspectiveCorrection.croppedCardCGImage(base: ciBase, normalizedRect: rect)
            }

            guard let cardImage = warped else {
                results.append(
                    RecognizedPlayingCard(
                        confidence: 0,
                        diagnosis: "Slot \(idx + 1): failed to normalize perspective"
                    )
                )
                continue
            }

            let ocr = TextRecognition.extract(cardCrop: cardImage)
            let mlBest = classifyWithCoreMLIfAvailable(cardImage)

            let rank = mlBest.flatMap { CardTextParser.parseRank(from: $0.identifier) }
                ?? CardTextParser.parseRank(from: ocr.combinedText)
            var suit = mlBest.flatMap { CardTextParser.parseSuit(from: $0.identifier) }
                ?? CardTextParser.parseSuit(from: ocr.combinedText)

            if suit == nil, rank != nil {
                suit = SuitColorHeuristic.infer(for: cardImage)
            }

            let confidence = mlBest.map { $0.confidence } ?? ocr.averageConfidence

            let diagnosisLines: [String] = [
                ocr.topStripText.isEmpty ? nil : "OCR corner ▸ \(ocr.topStripText)",
                ocr.combinedText.isEmpty ? nil : "OCR overall ▸ \(ocr.combinedText)",
                mlBest.map { "ML ▸ \($0.identifier) (\(String(format: "%.02f", $0.confidence)))" },
            ].compactMap(\.self)

            results.append(
                RecognizedPlayingCard(
                    rank: rank,
                    suit: suit,
                    confidence: confidence,
                    diagnosis: diagnosisLines.joined(separator: "\n")
                )
            )
        }

        if results.count < 5 {
            for i in results.count ..< 5 {
                results.append(
                    RecognizedPlayingCard(
                        confidence: 0,
                        diagnosis: "Slot \(i + 1): unused (no detection candidate)"
                    )
                )
            }
        }

        return ScanResult(cards: Array(results.prefix(5)))
    }

    private static func detectCardRectangles(cgImage: CGImage) throws -> [VNRectangleObservation] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 20
        request.minimumConfidence = 0.48
        request.minimumAspectRatio = 0.42
        request.maximumAspectRatio = 0.95
        request.quadratureTolerance = 40

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    private static func classifyWithCoreMLIfAvailable(_ cgImage: CGImage) -> VNClassificationObservation? {
        guard let request = coreMLClassifierRequest else { return nil }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results as? [VNClassificationObservation] else {
            return nil
        }
        return observations.first
    }
}

// MARK: - Geometry selection

private enum CardRectangleSelector {
    enum Pick {
        case perspective(VNRectangleObservation)
        case column(CGRect)
    }

    static func select(
        observations: [VNRectangleObservation]
    ) -> [Pick] {
        let minArea = 0.0055 /// ~0.55% of the frame — keeps tiny UI chrome out.
        let filtered = observations
            .filter { $0.confidence >= 0.45 }
            .filter { normalizedArea($0.boundingBox) >= minArea }
            .filter { aspectInCardRange($0.boundingBox) }

        let kept = nonMaximumSuppression(observations: filtered, iouThreshold: 0.32)
            .sorted { $0.boundingBox.midX < $1.boundingBox.midX }

        if kept.count >= 5 {
            return Array(kept.prefix(5).map { .perspective($0) })
        }

        if kept.count == 1, kept[0].boundingBox.width > 0.46 {
            return fiveColumns(in: clip(kept[0].boundingBox))
        }

        if kept.count > 1, kept.count < 5 {
            let unionBox = clip(boundingUnion(of: kept))
            if unionBox.width > 0.52 {
                return fiveColumns(in: unionBox)
            }
            return kept.map { .perspective($0) }
        }

        if kept.isEmpty {
            /// Slot reels are usually centered — this synthetic strip keeps the workflow alive for manual tuning.
            return fiveColumns(in: CGRect(x: 0.03, y: 0.18, width: 0.94, height: 0.64))
        }

        return kept.map { .perspective($0) }
    }

    private static func clip(_ rect: CGRect) -> CGRect {
        rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func boundingUnion(of observations: [VNRectangleObservation]) -> CGRect {
        var rect = observations[0].boundingBox
        for obs in observations.dropFirst() {
            rect = rect.union(obs.boundingBox)
        }
        return rect
    }

    private static func fiveColumns(in normalized: CGRect) -> [Pick] {
        guard normalized.width > 0.01 else { return [] }
        let step = normalized.width / 5
        return (0 ..< 5).map { index in
            let column = CGRect(
                x: normalized.minX + CGFloat(index) * step,
                y: normalized.minY,
                width: step,
                height: normalized.height
            )
            return Pick.column(clip(column))
        }
    }

    private static func normalizedArea(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func aspectInCardRange(_ rect: CGRect) -> Bool {
        guard rect.height > 0.0001 else { return false }
        let ar = rect.width / rect.height
        return ar > 0.45 && ar < 0.97
    }

    private static func nonMaximumSuppression(
        observations: [VNRectangleObservation],
        iouThreshold: CGFloat
    ) -> [VNRectangleObservation] {
        let ranked = observations.sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                return normalizedArea(lhs.boundingBox) > normalizedArea(rhs.boundingBox)
            }
            return lhs.confidence > rhs.confidence
        }

        var selected: [VNRectangleObservation] = []
        for candidate in ranked {
            let overlaps = selected.contains { iou(candidate.boundingBox, $0.boundingBox) > iouThreshold }
            if overlaps == false {
                selected.append(candidate)
            }
        }
        return selected
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard intersection.isNull == false else { return 0 }
        let interArea = intersection.width * intersection.height
        let unionArea = normalizedArea(a) + normalizedArea(b) - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }
}
