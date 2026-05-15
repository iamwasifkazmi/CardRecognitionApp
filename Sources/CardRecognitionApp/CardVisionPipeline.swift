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
        /// One path for **library + camera**: cap extreme resolution, then moiré-aware prep (same as pre–camera-tuning gallery behavior).
        let canonical = FrameNormalizer.canonicalScanCGImage(cgImage: cgImage)
        let visionImage = FrameNormalizer.preparedForCardVision(cgImage: canonical)
        SlotRecognitionDiagnostics.log("━━━━━━━━ scan start ━━━━━━━━ \(visionImage.width)×\(visionImage.height) px")
        let observations = try mergedRectangleObservations(visionImage: visionImage, original: canonical)
        SlotRecognitionDiagnostics.log("VNDetectRectangles merged raw count=\(observations.count)")
        let picks = CardRectangleSelector.select(
            observations: observations,
            imageWidth: CGFloat(visionImage.width),
            imageHeight: CGFloat(visionImage.height),
            stripProbe: visionImage
        )
        SlotRecognitionDiagnostics.log("Geometry picks(count=\(picks.count)): left→right slot order")

        /// Minimal slot strips (e.g. 1222×314) are very wide; ♠/♣ templates on **Queen** are more reliable than on standard 2∶1 photos where court art dominates.
        let canvasAspect = CGFloat(visionImage.width) / CGFloat(max(visionImage.height, 1))
        /// Photos of a monitor row are often a bit shorter than ultra-wide slot thumbnails — keep the “wide strip” path for more real-world aspect ratios.
        let wideHorizontalStripLayout = canvasAspect >= 2.48

        /// Geometry + band detection use moiré-filtered `visionImage`; **OCR crops** sample `canonical` so phone/camera scans get gallery-like glyph resolution (same normalized boxes — aspect ratio preserved end-to-end).
        let ciOCRSource = CIImage(cgImage: canonical)

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
                warped = PerspectiveCorrection.warpedCardCGImage(base: ciOCRSource, observation: obs)
                    ?? PerspectiveCorrection.croppedCardCGImage(base: ciOCRSource, normalizedRect: obs.boundingBox)
            case .column(let rect):
                SlotRecognitionDiagnostics.log("  mode=fiveColumnSlice")
                SlotRecognitionDiagnostics.logRectNorm("  column rect(norm)", rect)
                warped = PerspectiveCorrection.croppedCardCGImage(base: ciOCRSource, normalizedRect: rect)
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

            let ocrLooksLikeDesktopChrome = CardTextParser.looksLikeUIScreenshotText(ocr.combinedText)
                || CardTextParser.looksLikeDeveloperIDEChrome(ocr.combinedText)
                || CardTextParser.looksLikeOCRNoiseLayout(ocr.combinedText)
                || CardTextParser.looksLikeSymbolicNoise(ocr.combinedText)

            let rankSources = [
                ocr.topStripText,
                ocr.suitCornerText,
                ocr.bottomStripText,
                ocr.fullCardText,
                ocr.combinedText,
            ]

            let rank = mlBest.flatMap { CardTextParser.parseRank(from: $0.identifier) }
                ?? (ocrLooksLikeDesktopChrome ? nil : CardTextParser.firstRank(in: rankSources))

            let narrowCrop = CGFloat(cardImage.width) / CGFloat(cardImage.height) < 0.52
            let rankSevenCornerSuit = rank == .seven && ocrLooksLikeDesktopChrome == false
                ? TextRecognition.cornerIndexSuitForRankSeven(
                    cardCrop: cardImage,
                    narrowColumn: narrowCrop,
                    slotIndex: idx + 1
                )
                : ""
            let faceCornerSuit = rank?.isCourtRank == true && ocrLooksLikeDesktopChrome == false
                ? TextRecognition.cornerIndexSuitForFaceRank(
                    cardCrop: cardImage,
                    narrowColumn: narrowCrop,
                    slotIndex: idx + 1
                )
                : ""

            let suitSources = [
                rankSevenCornerSuit,
                faceCornerSuit,
                ocr.topStripText,
                ocr.suitCornerText,
                ocr.bottomStripText,
                ocr.fullCardText,
                ocr.combinedText,
            ]

            var suit = mlBest.flatMap { CardTextParser.parseSuit(from: $0.identifier) }
                ?? (ocrLooksLikeDesktopChrome ? nil : CardTextParser.firstSuit(in: suitSources))

            var suitFromColor = false
            var suitFromShape = false
            let pigment = rank != nil && SuitColorHeuristic.courtShowsRedPipPigment(cardImage)
            let weakRed = rank != nil && SuitColorHeuristic.courtSuggestsRedPipsWeak(cardImage)
            let redHint = pigment || weakRed

            /// **Rank 7**: only ML or explicit text (incl. `rank7_index_suit`). No silhouette guess if the glyph isn’t read.
            /// Pooled OCR that looks like macOS window chrome must **not** drive pip color / template fallbacks.
            let allowSilhouetteAndColorFallback = rank != .seven && ocrLooksLikeDesktopChrome == false
            /// **Black Queen** on portrait photo rows: court illustration often makes ♣ “win” over ♠; skip ♠/♣ template unless the image looks like a wide minimal strip (where OCR + templates still work for slot Q).
            /// **Column slices** (five synthetic columns) behave like slot strips — allow ♠/♣ silhouette there even when the full canvas is not ultra-wide.
            let allowBlackSilhouetteFallback: Bool = {
                guard rank != .seven else { return false }
                if rank == .queen, redHint == false, wideHorizontalStripLayout == false, narrowCrop == false { return false }
                return true
            }()

            if allowSilhouetteAndColorFallback {
                /// Never guess ♥/♦ from pip color when we could not read a rank — moiré on LCDs often fakes “red” in the court ROI.
                if suit == nil, redHint, rank != nil {
                    suit = SuitColorHeuristic.infer(for: cardImage)
                    suitFromColor = suit != nil
                }
                if suit == nil, redHint, rank != nil {
                    suit = SuitTemplateShapeMatcher.inferRedSuitsOnly(for: cardImage)
                    suitFromShape = suit != nil
                }
                if suit == nil, rank != nil, redHint == false, allowBlackSilhouetteFallback {
                    suit = SuitTemplateShapeMatcher.inferBlackSuitsOnly(for: cardImage)
                    suitFromShape = suit != nil
                }
            }
            if rank == .seven, suit == nil {
                SlotRecognitionDiagnostics.log(
                    "  suit: rank 7 — no suit in OCR/ML (see rank7_index_suit); leaving unknown (no template/color fallback)"
                )
            }
            if rank == .queen, redHint == false, suit == nil, wideHorizontalStripLayout == false, narrowCrop == false {
                SlotRecognitionDiagnostics.log(
                    "  suit: Queen — no black suit in OCR/ML (see face_index_suit); unknown on portrait layout (♠/♣ template skipped)"
                )
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
            if rank == .seven, suit == nil {
                let note = "Suit ▸ unknown — rank 7 index glyph not read (guessing disabled)"
                diagnosis = diagnosis.isEmpty ? note : "\(diagnosis)\n\(note)"
            }
            if rank == .queen, suit == nil, redHint == false, wideHorizontalStripLayout == false, narrowCrop == false {
                let note = "Suit ▸ unknown — Queen index suit not read (♠/♣ guess off on this layout)"
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

    private static func mergedRectangleObservations(visionImage: CGImage, original: CGImage) throws -> [VNRectangleObservation] {
        var acc = try detectCardRectangles(cgImage: visionImage, relaxed: false)
        if acc.isEmpty {
            acc = try detectCardRectangles(cgImage: original, relaxed: false)
        }
        if acc.isEmpty {
            acc = try detectCardRectangles(cgImage: visionImage, relaxed: true)
            acc.append(contentsOf: try detectCardRectangles(cgImage: original, relaxed: true))
            acc = dedupeRectangleObservations(acc, iouThreshold: 0.22)
        }
        return acc
    }

    /// Drop near-duplicate boxes from multi-pass rectangle detection (same physical edge, different passes).
    private static func dedupeRectangleObservations(_ observations: [VNRectangleObservation], iouThreshold: CGFloat) -> [VNRectangleObservation] {
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

    private static func normalizedArea(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func detectCardRectangles(cgImage: CGImage, relaxed: Bool) throws -> [VNRectangleObservation] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = relaxed ? 32 : 20
        if relaxed {
            request.minimumConfidence = 0.30
            request.minimumAspectRatio = 0.10
            request.maximumAspectRatio = 0.99
            request.quadratureTolerance = 56
        } else {
            request.minimumConfidence = 0.42
            request.minimumAspectRatio = 0.42
            request.maximumAspectRatio = 0.95
            request.quadratureTolerance = 40
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])
        let raw = request.results ?? []
        if SlotRecognitionDiagnostics.isLoggingEnabled, raw.count <= 25 {
            for (i, o) in raw.enumerated() {
                SlotRecognitionDiagnostics.logRectNorm(
                    "  cand[\(i)] conf=\(String(format: "%.3f", o.confidence)) relaxed=\(relaxed)",
                    o.boundingBox
                )
            }
        }
        return raw
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard intersection.isNull == false else { return 0 }
        let interArea = intersection.width * intersection.height
        let unionArea = normalizedArea(a) + normalizedArea(b) - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
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
        imageHeight: CGFloat,
        stripProbe: CGImage
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
            if let bright = BrightCardRowLocator.visionNormalizedBrightRowStrip(cgImage: stripProbe) {
                SlotRecognitionDiagnostics.log("strategy=SYNTHETIC_fallback_bright_row_scan")
                SlotRecognitionDiagnostics.logRectNorm("bright_band(norm)", bright)
                return fiveColumns(in: clip(bright))
            }
            SlotRecognitionDiagnostics.log("strategy=SYNTHETIC_fallback_strip (no Vision rectangles passed filters)")
            /// Slot reels are usually centered — this synthetic strip keeps the workflow alive for manual tuning.
            return fiveColumns(in: CGRect(x: 0.03, y: 0.18, width: 0.94, height: 0.64))
        }

        /// Vision often finds only 2–4 rectangles (see partial yellow boxes on some photos). Using those crops alone
        /// leaves empty slots and shuffles which column maps to which reel. Prefer an even 5-way split of the row hull.
        if kept.count == 1 {
            let box = clip(kept[0].boundingBox)
            let rowAspect = box.width / max(box.height, 0.015)
            /// One wide, not-too-tall hull ≈ five cards in a row.
            let isHorizontalCardRowHull =
                box.width >= 0.28 &&
                box.height <= 0.58 &&
                rowAspect >= 1.14
            if isHorizontalCardRowHull {
                SlotRecognitionDiagnostics.log("strategy=SPLIT_one_wide_rectangle_into_5_columns")
                SlotRecognitionDiagnostics.logRectNorm("strip", box)
                return fiveColumns(in: box)
            }
            /// A **tall narrow** box (common false positive on slot / window UIs) must never be warped as “one card”.
            let isTallSliverHallucination =
                box.height >= 0.44 &&
                box.width <= 0.42 &&
                rowAspect < 0.92
            if isTallSliverHallucination {
                if canvasAR >= 1.42 && canvasAR <= 2.35 {
                    let strip = clip(defaultLandscapeFiveCardRowStrip(canvasAspect: canvasAR))
                    SlotRecognitionDiagnostics.log(
                        "strategy=SPLIT_single_tall_sliver_landscape_row_strip (skip bright-row — tall Vision box is usually UI chrome)"
                    )
                    SlotRecognitionDiagnostics.logRectNorm("landscape_row_strip(norm)", strip)
                    return fiveColumns(in: strip)
                }
                if let picks = syntheticFiveColumnsFromBrightOrDefault(
                    stripProbe: stripProbe,
                    logTag: "SPLIT_single_tall_vision_rect_fallback_bright_row"
                ) {
                    return picks
                }
            }
            if singleBoxLooksLikeOnePlayingCard(box, imageWidth: imageWidth, imageHeight: imageHeight) {
                SlotRecognitionDiagnostics.log("strategy=single_tight_rectangle_perspective_only (one plausible card-sized box)")
                return [.perspective(kept[0])]
            }
            if let picks = syntheticFiveColumnsFromBrightOrDefault(
                stripProbe: stripProbe,
                logTag: "SPLIT_single_odd_rect_fallback_bright_row"
            ) {
                return picks
            }
            if canvasAR >= 1.42 && canvasAR <= 2.35 {
                let strip = clip(defaultLandscapeFiveCardRowStrip(canvasAspect: canvasAR))
                SlotRecognitionDiagnostics.log("strategy=SPLIT_single_odd_rect_landscape_row_strip_fallback")
                SlotRecognitionDiagnostics.logRectNorm("landscape_row_strip(norm)", strip)
                return fiveColumns(in: strip)
            }
            SlotRecognitionDiagnostics.log("strategy=SYNTHETIC_fallback_strip_after_single_odd_rect")
            return fiveColumns(in: CGRect(x: 0.03, y: 0.18, width: 0.94, height: 0.64))
        }

        let unionBox = clip(boundingUnion(of: kept))
        /// Require the union to look like a **horizontal** strip (wide vs tall). Stacked UI boxes (similar `minX`, different `y`) stay narrow-tall and must **not** take the 5-column split.
        let rowAspect = unionBox.width / max(unionBox.height, 0.02)
        /// Reject “tower” unions that swallow most of the phone screen (in-app UI + cards) — split would OCR labels, not indices.
        let rowLike =
            unionBox.width >= 0.22 &&
            unionBox.height >= 0.04 &&
            unionBox.height <= 0.62 &&
            rowAspect >= 1.12
        if rowLike {
            SlotRecognitionDiagnostics.log("strategy=SPLIT_union_of_partial_rectangles_into_5_columns")
            SlotRecognitionDiagnostics.logRectNorm("union", unionBox)
            return fiveColumns(in: unionBox)
        }

        if kept.count >= 1 && kept.count < 5 {
            /// `VNDetectRectangles` often locks onto a **vertical stack** of UI tiles (same `midX`, different `y`) while the real five cards sit in one horizontal band — union is then tall/narrow and **not** `rowLike`. Bright-row luminance can still include menu + dock; prefer a tight landscape strip for typical 16∶9 monitor photos.
            if visionKeepsLookLikeVerticalUISpurious(kept) {
                let strip = clip(defaultLandscapeFiveCardRowStrip(canvasAspect: canvasAR))
                SlotRecognitionDiagnostics.log(
                    "strategy=SYNTHETIC_vertical_ui_false_positives_landscape_row_strip (Vision kept=\(kept.count), union not row-like)"
                )
                SlotRecognitionDiagnostics.logRectNorm("landscape_row_strip(norm)", strip)
                return fiveColumns(in: strip)
            }
            if let picks = syntheticFiveColumnsFromBrightOrDefault(
                stripProbe: stripProbe,
                logTag: "SYNTHETIC_partial_vision_fallback_bright_row (Vision kept=\(kept.count), union not row-like)"
            ) {
                return picks
            }
        }

        SlotRecognitionDiagnostics.log("strategy=FALLBACK_individual_perspective_only count=\(kept.count) (union not row-like)")
        SlotRecognitionDiagnostics.logRectNorm("union_was", unionBox)
        return kept.map { .perspective($0) }
    }

    private static func clip(_ rect: CGRect) -> CGRect {
        rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// True when a single normalized box is roughly **one** physical playing card (not a column of the whole window).
    private static func singleBoxLooksLikeOnePlayingCard(_ box: CGRect, imageWidth: CGFloat, imageHeight: CGFloat) -> Bool {
        let pw = box.width * imageWidth
        let ph = box.height * imageHeight
        guard pw > 24, ph > 24 else { return false }
        let shortOverLong = min(pw, ph) / max(pw, ph)
        return shortOverLong >= 0.58 &&
            shortOverLong <= 0.86 &&
            box.width < 0.26 &&
            box.height < 0.48
    }

    /// Vision boxes share one column (list / dock tiles) instead of five cards in a row.
    private static func visionKeepsLookLikeVerticalUISpurious(_ kept: [VNRectangleObservation]) -> Bool {
        guard kept.count >= 2, kept.count <= 4 else { return false }
        let midsX = kept.map { $0.boundingBox.midX }
        let spanX = (midsX.max() ?? 0) - (midsX.min() ?? 0)
        let midsY = kept.map { $0.boundingBox.midY }
        let spanY = (midsY.max() ?? 0) - (midsY.min() ?? 0)
        let avgW = kept.map { $0.boundingBox.width }.reduce(0, +) / CGFloat(max(kept.count, 1))
        return spanX < max(avgW * 0.55, 0.06) && spanY > max(avgW * 0.85, 0.11)
    }

    /// When bright-row / Vision fail, a **short, wide** strip centered for 16∶9-ish photos of a laptop/monitor row (white cards on dark chrome).
    private static func defaultLandscapeFiveCardRowStrip(canvasAspect: CGFloat) -> CGRect {
        if canvasAspect >= 1.42 && canvasAspect <= 2.35 {
            /// One horizontal row of cards — keep height **small** so Xcode sidebars, simulator chrome, and dock stay out of crops.
            return CGRect(x: 0.09, y: 0.40, width: 0.82, height: 0.16)
        }
        return CGRect(x: 0.03, y: 0.18, width: 0.94, height: 0.64)
    }

    private static func syntheticFiveColumnsFromBrightOrDefault(stripProbe: CGImage, logTag: String) -> [Pick]? {
        if let rawBright = BrightCardRowLocator.visionNormalizedBrightRowStrip(cgImage: stripProbe) {
            let bright = BrightCardRowLocator.clampStripForFiveCardRow(rawBright)
            if bright.width >= 0.30 && bright.height >= 0.055 && bright.height <= 0.56 {
                SlotRecognitionDiagnostics.log("strategy=\(logTag)")
                SlotRecognitionDiagnostics.logRectNorm("bright_band(norm)", bright)
                return fiveColumns(in: clip(bright))
            }
        }
        return nil
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
        /// A **single** hull around five cards in one row is very wide → `shortOverLong` is small; allow that so we split instead of falling back blindly.
        let wideStripHull = pw >= ph * 2.15 && pw >= imageWidth * 0.42
        if wideStripHull {
            return shortOverLong >= 0.07 && shortOverLong <= 0.993
        }
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
