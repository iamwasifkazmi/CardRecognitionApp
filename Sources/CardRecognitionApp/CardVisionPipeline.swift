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
        SlotRecognitionDiagnostics.log("━━━━━━━━ scan start ━━━━━━━━ \(cgImage.width)×\(cgImage.height) px")
        let observations = try detectCardRectangles(cgImage: cgImage)
        SlotRecognitionDiagnostics.log("VNDetectRectangles raw count=\(observations.count)")
        let picks = CardRectangleSelector.select(
            observations: observations,
            imageWidth: CGFloat(cgImage.width),
            imageHeight: CGFloat(cgImage.height)
        )
        SlotRecognitionDiagnostics.log("Geometry picks(count=\(picks.count)): left→right slot order")

        let ciBase = CIImage(cgImage: cgImage)

        var results: [RecognizedPlayingCard] = []
        results.reserveCapacity(5)

        for (idx, pick) in picks.enumerated() {
            SlotRecognitionDiagnostics.log("── slot \(idx + 1) ──")

            let warped: CGImage?
            switch pick {
            case .perspective(let obs):
                SlotRecognitionDiagnostics.log(
                    "  mode=perspective Vision conf=\(String(format: "%.3f", obs.confidence))"
                )
                SlotRecognitionDiagnostics.logRectNorm("  bbox(norm, bottom-left origin)", obs.boundingBox)
                warped = PerspectiveCorrection.warpedCardCGImage(base: ciBase, observation: obs)
                    ?? PerspectiveCorrection.croppedCardCGImage(base: ciBase, normalizedRect: obs.boundingBox)
            case .column(let rect):
                SlotRecognitionDiagnostics.log("  mode=fiveColumnSlice")
                SlotRecognitionDiagnostics.logRectNorm("  column rect(norm)", rect)
                warped = PerspectiveCorrection.croppedCardCGImage(base: ciBase, normalizedRect: rect)
            }

            guard let cardImage = warped else {
                SlotRecognitionDiagnostics.log("  ⚠️ warped crop is nil — pipeline cannot OCR this slot")
                results.append(
                    RecognizedPlayingCard(
                        confidence: 0,
                        diagnosis: "Slot \(idx + 1): failed to normalize perspective"
                    )
                )
                continue
            }

            SlotRecognitionDiagnostics.log("  crop pixels: \(cardImage.width)×\(cardImage.height)")
            let ocr = TextRecognition.extract(cardCrop: cardImage, slotIndex: idx + 1)
            let mlBest = classifyWithCoreMLIfAvailable(cardImage)

            let rankSources = [
                ocr.topStripText,
                ocr.suitCornerText,
                ocr.bottomStripText,
                ocr.fullCardText,
                ocr.combinedText,
            ]
            let suitSources = [
                ocr.topStripText,
                ocr.suitCornerText,
                ocr.bottomStripText,
                ocr.fullCardText,
                ocr.combinedText,
            ]

            let rank = mlBest.flatMap { CardTextParser.parseRank(from: $0.identifier) }
                ?? CardTextParser.firstRank(in: rankSources)

            var suit = mlBest.flatMap { CardTextParser.parseSuit(from: $0.identifier) }
                ?? CardTextParser.firstSuit(in: suitSources)

            var suitFromColor = false
            var suitFromShape = false
            let pigment = rank != nil && SuitColorHeuristic.courtShowsRedPipPigment(cardImage)
            /// Only propose ♥/♦ hue when ROI shows real red pigment; otherwise black ♠ ♣ falsely become ♦ in fill-correlation models.
            if suit == nil, pigment {
                suit = SuitColorHeuristic.infer(for: cardImage)
                suitFromColor = suit != nil
            }
            if suit == nil, pigment {
                suit = SuitTemplateShapeMatcher.inferRedSuitsOnly(for: cardImage)
                suitFromShape = suit != nil
            }
            if suit == nil, rank != nil, pigment == false {
                suit = SuitTemplateShapeMatcher.inferBlackSuitsOnly(for: cardImage)
                suitFromShape = suit != nil
            }

            SlotRecognitionDiagnostics.log(
                "  parse → rank=\(rank.map(\.rawValue) ?? "?") suit=\(suit.map(\.rawValue) ?? "?") ml=\(mlBest?.identifier ?? "–") suitFromColorHint=\(suitFromColor) suitFromTemplate=\(suitFromShape)"
            )

            let decodedAnything = rank != nil || suit != nil
            var confidence: Float
            if let mlBest {
                confidence = mlBest.confidence
            } else if decodedAnything {
                confidence = ocr.averageConfidence
            } else {
                confidence = 0
            }
            if suitFromColor, suit != nil {
                /// OCR was silent on pips; color only separates ♥/♦ — never claim “100%” like text OCR.
                confidence = min(confidence, 0.62)
            } else if suitFromShape, suit != nil {
                confidence = min(confidence, 0.70)
            } else if rank != nil, suit == nil {
                /// Rank OCR may stay high while ♠♣ silhouette match failed.
                confidence = min(confidence, 0.78)
            }

            let diagnosisLines: [String] = [
                ocr.topStripText.isEmpty ? nil : "OCR corner ▸ \(ocr.topStripText)",
                ocr.suitCornerText.isEmpty ? nil : "OCR suit ▸ \(ocr.suitCornerText)",
                ocr.bottomStripText.isEmpty ? nil : "OCR mirror ▸ \(ocr.bottomStripText)",
                ocr.fullCardText.isEmpty ? nil : "OCR full ▸ \(ocr.fullCardText)",
                mlBest.map { "ML ▸ \($0.identifier) (\(String(format: "%.02f", $0.confidence)))" },
            ].compactMap(\.self)
            var diagnosis = diagnosisLines.joined(separator: "\n")
            if suitFromColor, suit != nil {
                let note = "Suit ▸ pip color (hue on court ROI)"
                diagnosis = diagnosis.isEmpty ? note : "\(diagnosis)\n\(note)"
            }
            if suitFromShape, suit != nil {
                let note = "Suit ▸ silhouette vs SF Symbol template"
                diagnosis = diagnosis.isEmpty ? note : "\(diagnosis)\n\(note)"
            }

            results.append(
                RecognizedPlayingCard(
                    rank: rank,
                    suit: suit,
                    confidence: confidence,
                    diagnosis: diagnosis
                )
            )
            if decodedAnything == false {
                SlotRecognitionDiagnostics.log(
                    "  ⚠️ no rank/suit after OCR — check OCR lines above (empty ROIs vs parser filter vs black suit)."
                )
            }
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

        SlotRecognitionDiagnostics.log("━━━━━━━━ scan end ━━━━━━━━")
        return ScanResult(cards: Array(results.prefix(5)))
    }

    private static func detectCardRectangles(cgImage: CGImage) throws -> [VNRectangleObservation] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 20
        request.minimumConfidence = 0.42
        request.minimumAspectRatio = 0.42
        request.maximumAspectRatio = 0.95
        request.quadratureTolerance = 40

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])
        let raw = request.results ?? []
        if SlotRecognitionDiagnostics.isLoggingEnabled, raw.count <= 25 {
            for (i, o) in raw.enumerated() {
                SlotRecognitionDiagnostics.logRectNorm(
                    "  cand[\(i)] conf=\(String(format: "%.3f", o.confidence))",
                    o.boundingBox
                )
            }
        }
        return raw
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
        observations: [VNRectangleObservation],
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> [Pick] {
        let canvasAR = imageWidth / max(imageHeight, 1)
        /// Ultra-wide thumbnails (five cards in one row ≪ image height) also produce many tiny UI rectangles —
        /// require a larger **normalized** bbox area only in that regime so chromes/shards drop out before NMS.
        let minArea: CGFloat = canvasAR >= 2.35 ? 0.036 : 0.0042
        SlotRecognitionDiagnostics.log(
            "filter thresholds: canvasAR=\(String(format: "%.2f", Double(canvasAR))) minNormArea=\(String(format: "%.4f", Double(minArea)))"
        )

        let filtered = observations
            .filter { $0.confidence >= 0.40 }
            .filter { normalizedArea($0.boundingBox) >= minArea }
            .filter { aspectInCardRange($0.boundingBox, imageWidth: imageWidth, imageHeight: imageHeight) }

        SlotRecognitionDiagnostics.log(
            "filter: \(observations.count) raw → \(filtered.count) pass area & pixel-aspect & conf≥0.40 (image \(Int(imageWidth))×\(Int(imageHeight)))"
        )

        let kept = nonMaximumSuppression(observations: filtered, iouThreshold: 0.32)
            .sorted { $0.boundingBox.midX < $1.boundingBox.midX }

        SlotRecognitionDiagnostics.log("NMS+sort: \(kept.count) kept (left→right)")

        if kept.count >= 5 {
            SlotRecognitionDiagnostics.log("strategy=take_first5_perspective_rectangles")
            return Array(kept.prefix(5).map { .perspective($0) })
        }

        if kept.isEmpty {
            SlotRecognitionDiagnostics.log("strategy=SYNTHETIC_fallback_strip (no Vision rectangles passed filters)")
            /// Slot reels are usually centered — this synthetic strip keeps the workflow alive for manual tuning.
            return fiveColumns(in: CGRect(x: 0.03, y: 0.18, width: 0.94, height: 0.64))
        }

        /// Vision often finds only 2–4 rectangles (see partial yellow boxes on some photos). Using those crops alone
        /// leaves empty slots and shuffles which column maps to which reel. Prefer an even 5-way split of the row hull.
        if kept.count == 1 {
            let box = clip(kept[0].boundingBox)
            if box.width >= 0.36 {
                SlotRecognitionDiagnostics.log("strategy=SPLIT_one_wide_rectangle_into_5_columns")
                SlotRecognitionDiagnostics.logRectNorm("strip", box)
                return fiveColumns(in: box)
            }
            SlotRecognitionDiagnostics.log("strategy=single_tight_rectangle_perspective_only (no split)")
            return [.perspective(kept[0])]
        }

        let unionBox = clip(boundingUnion(of: kept))
        /// Panorama hulls like two partial hits can dip just under 0.28 wide (see 0.235 logs).
        let rowLike = unionBox.width >= 0.195 && unionBox.height >= 0.05
        if rowLike {
            SlotRecognitionDiagnostics.log("strategy=SPLIT_union_of_partial_rectangles_into_5_columns")
            SlotRecognitionDiagnostics.logRectNorm("union", unionBox)
            return fiveColumns(in: unionBox)
        }

        SlotRecognitionDiagnostics.log("strategy=FALLBACK_individual_perspective_only count=\(kept.count) (union not row-like)")
        SlotRecognitionDiagnostics.logRectNorm("union_was", unionBox)
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
        /// Smaller gutters keep slightly more reel art in each column (helps OCR on centered indices).
        let pad = step * 0.006
        return (0 ..< 5).map { index in
            let column = CGRect(
                x: normalized.minX + CGFloat(index) * step + pad,
                y: normalized.minY,
                width: step - 2 * pad,
                height: normalized.height
            )
            return Pick.column(clip(column))
        }
    }

    private static func normalizedArea(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    /// Uses **pixel** width/height. Normalized `width/height` is wrong on wide photos (e.g. ~0.29) even for real cards (~0.57).
    private static func aspectInCardRange(_ rect: CGRect, imageWidth: CGFloat, imageHeight: CGFloat) -> Bool {
        let pw = rect.width * imageWidth
        let ph = rect.height * imageHeight
        guard pw > 2, ph > 2 else { return false }
        let shortOverLong = min(pw, ph) / max(pw, ph)
        /// Standard card short/long ≈ 2.5/3.5 ≈ 0.71. Vision boxes can skew almost square (~0.95) on panorama crops.
        return shortOverLong >= 0.30 && shortOverLong <= 0.993
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
