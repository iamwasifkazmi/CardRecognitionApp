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
                warped = PerspectiveCorrection.croppedColumnCGImage(base: ciBase, normalizedRect: rect)
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

            let rowSlice: Bool
            if case .column = pick { rowSlice = true } else { rowSlice = false }

            let index = CardIndexReader.read(
                cardCrop: cardImage,
                slotIndex: idx + 1,
                rowSliceColumn: rowSlice
            )
            let rank = index.rank
            let suit = index.suit

            SlotRecognitionDiagnostics.log(
                """
                  parse → rank=\(rank.map(\.rawValue) ?? "?") suit=\(suit.map(\.rawValue) ?? "?") \
                suit_via=\(index.suitSource?.rawValue ?? "none")
                """
            )

            let decodedAnything = rank != nil || suit != nil
            var confidence: Float = 0
            if rank != nil, suit != nil {
                switch index.suitSource {
                case .ocr: confidence = 0.88
                case .indexIcon: confidence = 0.80
                case .centerIcon: confidence = 0.76
                case nil: confidence = 0.65
                }
            } else if decodedAnything {
                confidence = 0.50
            }

            var diagnosis = "Detected ▸ \(index.cornerText)"
            if let src = index.suitSource, src != .ocr, suit != nil {
                diagnosis += "\nSuit icon ▸ \(src.rawValue)"
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
                SlotRecognitionDiagnostics.log("  ⚠️ rank/suit not read from index corner")
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

        let portraitPhoto = canvasAR < 0.95

        /// Full-machine **portrait** photos: Vision often returns dozens of paytable / chrome boxes. The five **leftmost**
        /// filtered rects are usually not the five cards — fall back to the normalized “card row” strip.
        if kept.count >= 5 {
            let unionKept = clip(boundingUnion(of: kept))
            if portraitPhoto, portraitRectClusterUnlikelyCardRow(unionKept) {
                SlotRecognitionDiagnostics.log(
                    "strategy=portrait_many_rects_reject_wide_union → synthetic five-column strip (not leftmost five boxes)"
                )
                let synthetic = syntheticFallbackStrip(canvasAspect: canvasAR)
                logCardRowBandIfTrimmed(original: synthetic)
                return fiveColumns(in: cardRowBand(in: synthetic))
            }
            SlotRecognitionDiagnostics.log("strategy=take_first5_perspective_rectangles")
            return Array(kept.prefix(5).map { .perspective($0) })
        }

        if kept.isEmpty {
            SlotRecognitionDiagnostics.log("strategy=SYNTHETIC_fallback_strip (no Vision rectangles passed filters)")
            let synthetic = syntheticFallbackStrip(canvasAspect: canvasAR)
            logCardRowBandIfTrimmed(original: synthetic)
            return fiveColumns(in: cardRowBand(in: synthetic))
        }

        /// Vision often finds only 2–4 rectangles (see partial yellow boxes on some photos). Using those crops alone
        /// leaves empty slots and shuffles which column maps to which reel. Prefer an even 5-way split of the row hull.
        if kept.count == 1 {
            let box = clip(kept[0].boundingBox)
            if box.width >= 0.36 {
                SlotRecognitionDiagnostics.log("strategy=SPLIT_one_wide_rectangle_into_5_columns")
                SlotRecognitionDiagnostics.logRectNorm("strip", box)
                logCardRowBandIfTrimmed(original: box)
                return fiveColumns(in: cardRowBand(in: box))
            }
            if canvasAR < 0.95 {
                SlotRecognitionDiagnostics.log(
                    "strategy=single_card_bbox_on_portrait → synthetic five-column strip (not one-card perspective)"
                )
                let synthetic = syntheticFallbackStrip(canvasAspect: canvasAR)
                logCardRowBandIfTrimmed(original: synthetic)
                return fiveColumns(in: cardRowBand(in: synthetic))
            }
            SlotRecognitionDiagnostics.log("strategy=single_tight_rectangle_perspective_only (no split)")
            return [.perspective(kept[0])]
        }

        if kept.count >= 4 {
            let unionBox = clip(boundingUnion(of: kept))
            if unionBox.width >= 0.52 {
                /// Portrait: prefer an even 5-way split of the **row hull** so we always get five slots; avoid four perspective
                /// crops + one empty column when the fourth box isn’t a card.
                if portraitPhoto, portraitUnionLooksLikeCardRowBand(unionBox) {
                    SlotRecognitionDiagnostics.log(
                        "strategy=SPLIT_union_\(kept.count)_rects_portrait_card_row (stable five columns)"
                    )
                    logCardRowBandIfTrimmed(original: unionBox)
                    return fiveColumns(in: cardRowBand(in: unionBox))
                }
                if portraitPhoto, portraitRectClusterUnlikelyCardRow(unionBox) {
                    SlotRecognitionDiagnostics.log(
                        "strategy=portrait_\(kept.count)_rects_loose_union → synthetic five-column strip"
                    )
                    let synthetic = syntheticFallbackStrip(canvasAspect: canvasAR)
                    logCardRowBandIfTrimmed(original: synthetic)
                    return fiveColumns(in: cardRowBand(in: synthetic))
                }
                SlotRecognitionDiagnostics.log(
                    "strategy=take_\(kept.count)_perspective_rectangles (stable slots, skip union column split)"
                )
                return Array(kept.prefix(5).map { .perspective($0) })
            }
        }

        let unionBox = clip(boundingUnion(of: kept))
        /// Panorama hulls like two partial hits can dip just under 0.28 wide (see 0.235 logs).
        let rowLike = unionBox.width >= 0.195 && unionBox.height >= 0.05
        if rowLike {
            SlotRecognitionDiagnostics.log("strategy=SPLIT_union_of_partial_rectangles_into_5_columns")
            SlotRecognitionDiagnostics.logRectNorm("union", unionBox)
            logCardRowBandIfTrimmed(original: unionBox)
            return fiveColumns(in: cardRowBand(in: unionBox))
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

    /// Heuristic vertical band for the five cards on **portrait** full-screen VP/cabinet shots (Vision uses bottom-left origin).
    private static func portraitUnionLooksLikeCardRowBand(_ union: CGRect) -> Bool {
        let midY = union.midY
        return midY >= 0.36 && midY <= 0.76 && union.height <= 0.52 && union.height >= 0.04
    }

    /// `true` when the hull is too tall or off-center — typical of paytable + buttons, not five cards alone.
    private static func portraitRectClusterUnlikelyCardRow(_ union: CGRect) -> Bool {
        if union.height > 0.50 { return true }
        if union.midY > 0.82 || union.midY < 0.28 { return true }
        if union.width < 0.40 { return true }
        return false
    }

    /// Portrait phone photos of a horizontal reel: sit the strip on the **middle** blue band (between paytable and BET/WIN).
    private static func syntheticFallbackStrip(canvasAspect: CGFloat) -> CGRect {
        if canvasAspect < 0.95 {
            return CGRect(x: 0.025, y: 0.405, width: 0.95, height: 0.265)
        }
        if canvasAspect >= 2.35 {
            return CGRect(x: 0.02, y: 0.20, width: 0.96, height: 0.44)
        }
        return CGRect(x: 0.03, y: 0.18, width: 0.94, height: 0.36)
    }

    /// Vision often returns one wide box around **cards + status bar**. Trim the lower band (Vision `y` is bottom-origin).
    private static func cardRowBand(in strip: CGRect) -> CGRect {
        let rowAspect = strip.width / max(strip.height, 0.001)
        guard rowAspect >= 2.0 else { return strip }
        let keep: CGFloat
        if rowAspect >= 3.5 {
            keep = 0.72
        } else if strip.height > 0.38 {
            keep = 0.58
        } else {
            keep = 0.70
        }
        guard keep < 0.99 else { return strip }
        var band = strip
        let trimmedFromBottom = strip.height * (1 - keep)
        band.origin.y += trimmedFromBottom
        band.size.height *= keep
        return clip(band)
    }

    private static func logCardRowBandIfTrimmed(original: CGRect) {
        let band = cardRowBand(in: original)
        guard band != original else { return }
        SlotRecognitionDiagnostics.log("cardRowBand: trimmed status chrome below five-card row")
        SlotRecognitionDiagnostics.logRectNorm("cardRowBand", band)
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
