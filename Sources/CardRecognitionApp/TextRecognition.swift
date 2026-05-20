import CoreGraphics
import Vision

enum TextRecognition: Sendable {
    struct OCRSnapshot: Sendable {
        /// Pooled for `parseRank` / `parseSuit` (corner + mirror + full frame).
        var combinedText: String
        var topStripText: String
        var suitCornerText: String
        /// Mirrored index corner (bottom-right), often rescues face cards when top-left is clipped.
        var bottomStripText: String
        var leftBandText: String
        var pipCentralText: String
        var fullCardText: String
        var averageConfidence: Float
    }

    /// Focused OCR on the **top-left index stack** for **rank 7** — the small suit glyph under “7” is often missed by default ROIs.
    static func cornerIndexSuitForRankSeven(
        cardCrop: CGImage,
        narrowColumn: Bool,
        slotIndex: Int? = nil
    ) -> String {
        let rois: [CGRect] = narrowColumn
            ? [
                CGRect(x: 0.02, y: 0.12, width: 0.58, height: 0.55),
                CGRect(x: 0.02, y: 0.26, width: 0.50, height: 0.44),
            ]
            : [
                CGRect(x: 0.015, y: 0.18, width: 0.40, height: 0.50),
                CGRect(x: 0.015, y: 0.26, width: 0.34, height: 0.42),
                CGRect(x: 0.015, y: 0.32, width: 0.30, height: 0.36),
            ]
        return cornerIndexSuitPass(
            cardCrop: cardCrop,
            rois: rois,
            slotIndex: slotIndex,
            logKey: "rank7_index_suit"
        )
    }

    /// **J / Q / K** — same problem as 7; also tries **bottom-right** mirrored index (some warps clip the top-left stack).
    static func cornerIndexSuitForFaceRank(
        cardCrop: CGImage,
        narrowColumn: Bool,
        slotIndex: Int? = nil
    ) -> String {
        let rois: [CGRect] = narrowColumn
            ? [
                CGRect(x: 0.02, y: 0.10, width: 0.60, height: 0.58),
                CGRect(x: 0.02, y: 0.22, width: 0.55, height: 0.50),
                CGRect(x: 0.18, y: 0.02, width: 0.78, height: 0.55),
            ]
            : [
                CGRect(x: 0.012, y: 0.12, width: 0.46, height: 0.58),
                CGRect(x: 0.012, y: 0.20, width: 0.40, height: 0.50),
                CGRect(x: 0.012, y: 0.28, width: 0.36, height: 0.44),
                CGRect(x: 0.46, y: 0.04, width: 0.52, height: 0.52),
            ]
        return cornerIndexSuitPass(
            cardCrop: cardCrop,
            rois: rois,
            slotIndex: slotIndex,
            logKey: "face_index_suit"
        )
    }

    private static let suitGlyphCustomWords = [
        "♠", "♥", "♦", "♣", "♤", "♡", "♢", "♧",
        "S", "H", "D", "C", "s", "h", "d", "c",
        "spades", "hearts", "diamonds", "clubs",
    ]

    private static func cornerIndexSuitPass(
        cardCrop: CGImage,
        rois: [CGRect],
        slotIndex: Int?,
        logKey: String,
        upscale: Int = 2,
        suitGlyphLexicon: Bool = false,
        rowSliceTuning: Bool = false
    ) -> String {
        let scaled = cardCrop.upscaledForOCR(factor: upscale) ?? cardCrop
        var requests: [VNRecognizeTextRequest] = []
        requests.reserveCapacity(rois.count)
        for roi in rois {
            let r = VNRecognizeTextRequest()
            r.recognitionLevel = .accurate
            r.usesLanguageCorrection = false
            r.applyEnglishCardOCRHints()
            if suitGlyphLexicon {
                r.customWords = suitGlyphCustomWords
            }
            if rowSliceTuning {
                r.applyRowSliceOCRTuning(true)
            }
            r.regionOfInterest = roi
            requests.append(r)
        }
        let handler = VNImageRequestHandler(cgImage: scaled, orientation: .up, options: [:])
        try? handler.perform(requests)
        let merged = requests.map { summarize($0.results).text }.filter { !$0.isEmpty }.joined(separator: " ")
        if SlotRecognitionDiagnostics.isLoggingEnabled, let tag = slotIndex {
            SlotRecognitionDiagnostics.log(
                "OCR[slot \(tag)] \(logKey)='\(SlotRecognitionDiagnostics.ellipsis(merged, limit: 100))'"
            )
        }
        return merged
    }

    /// Reads indexing corners, a suit-pip strip, mirrored corner, and full-card pass.
    /// Pass `slotIndex` (1…5) to include this crop in Xcode console diagnostics when `SlotRecognitionDiagnostics.isLoggingEnabled`.
    /// Pixel-crop the **top-left index stack** (CG top-left coords) — far more reliable than Vision ROI on warped 360×504 crops.
    static func physicalIndexCornerText(
        cardCrop: CGImage,
        slotIndex: Int? = nil,
        rowSliceColumn: Bool = false
    ) -> String {
        let row = usesRowSliceLayout(rowSliceColumn: rowSliceColumn, cardCrop: cardCrop)
        let regions: [CGRect] = row
            ? [
                CGRect(x: 0.02, y: 0.02, width: 0.52, height: 0.38),
                CGRect(x: 0.02, y: 0.08, width: 0.48, height: 0.32),
            ]
            : [
                CGRect(x: 0.03, y: 0.02, width: 0.46, height: 0.26),
                CGRect(x: 0.03, y: 0.08, width: 0.40, height: 0.20),
            ]
        return physicalCropOCR(
            cardCrop: cardCrop,
            regions: regions,
            slotIndex: slotIndex,
            logKey: "physical_index",
            upscale: row ? 5 : 4,
            suitGlyphLexicon: true,
            minimumTextHeight: row ? 0.010 : 0.016
        )
    }

    /// Pixel-crop under the rank for the small suit glyph only.
    static func physicalSuitGlyphText(
        cardCrop: CGImage,
        slotIndex: Int? = nil,
        rowSliceColumn: Bool = false
    ) -> String {
        let row = usesRowSliceLayout(rowSliceColumn: rowSliceColumn, cardCrop: cardCrop)
        let regions: [CGRect] = row
            ? [
                CGRect(x: 0.03, y: 0.22, width: 0.40, height: 0.20),
                CGRect(x: 0.03, y: 0.28, width: 0.36, height: 0.18),
            ]
            : [
                CGRect(x: 0.04, y: 0.14, width: 0.32, height: 0.14),
                CGRect(x: 0.04, y: 0.18, width: 0.28, height: 0.12),
            ]
        return physicalCropOCR(
            cardCrop: cardCrop,
            regions: regions,
            slotIndex: slotIndex,
            logKey: "physical_suit",
            upscale: 6,
            suitGlyphLexicon: true,
            minimumTextHeight: 0.008
        )
    }

    /// Bottom-right mirrored index (upside-down) when the top-left stack is clipped.
    static func physicalMirrorIndexText(
        cardCrop: CGImage,
        slotIndex: Int? = nil,
        rowSliceColumn: Bool = false
    ) -> String {
        let row = usesRowSliceLayout(rowSliceColumn: rowSliceColumn, cardCrop: cardCrop)
        let regions: [CGRect] = row
            ? [
                CGRect(x: 0.46, y: 0.58, width: 0.52, height: 0.38),
            ]
            : [
                CGRect(x: 0.54, y: 0.72, width: 0.44, height: 0.26),
                CGRect(x: 0.50, y: 0.66, width: 0.48, height: 0.30),
            ]
        return physicalCropOCR(
            cardCrop: cardCrop,
            regions: regions,
            slotIndex: slotIndex,
            logKey: "physical_mirror",
            upscale: row ? 5 : 4,
            suitGlyphLexicon: true,
            minimumTextHeight: 0.010
        )
    }

    static func cornerStripTexts(cardCrop: CGImage, slotIndex: Int? = nil) -> (top: String, suit: String) {
        let narrow = normalizedCardCropWidth(cardCrop) < 0.52
        let snap = extract(cardCrop: cardCrop, slotIndex: slotIndex, rowSliceColumn: narrow)
        return (snap.topStripText, snap.suitCornerText)
    }

    /// Top-left **rank + suit glyph** only (no center pip — digits there are not suits).
    static func cornerIndexStackText(
        cardCrop: CGImage,
        slotIndex: Int? = nil,
        rowSliceColumn: Bool = false
    ) -> String {
        if usesRowSliceLayout(rowSliceColumn: rowSliceColumn, cardCrop: cardCrop) {
            return cornerIndexSuitForRowSlice(cardCrop: cardCrop, slotIndex: slotIndex)
        }
        let rois: [CGRect] = [
            CGRect(x: 0.01, y: 0.62, width: 0.44, height: 0.36),
            CGRect(x: 0.01, y: 0.50, width: 0.40, height: 0.38),
            CGRect(x: 0.02, y: 0.40, width: 0.34, height: 0.30),
        ]
        return cornerIndexSuitPass(
            cardCrop: cardCrop,
            rois: rois,
            slotIndex: slotIndex,
            logKey: "index_corner",
            upscale: 3
        )
    }

    /// Small ROI under the rank — suit symbol only (♠ ♥ ♦ ♣).
    static func cornerSuitGlyphText(
        cardCrop: CGImage,
        slotIndex: Int? = nil,
        rowSliceColumn: Bool = false
    ) -> String {
        let narrow = usesRowSliceLayout(rowSliceColumn: rowSliceColumn, cardCrop: cardCrop)
        let rois: [CGRect] = narrow
            ? [
                CGRect(x: 0.02, y: 0.54, width: 0.30, height: 0.22),
                CGRect(x: 0.02, y: 0.46, width: 0.28, height: 0.26),
            ]
            : [
                CGRect(x: 0.02, y: 0.48, width: 0.26, height: 0.22),
                CGRect(x: 0.02, y: 0.40, width: 0.24, height: 0.24),
            ]
        return cornerIndexSuitPass(
            cardCrop: cardCrop,
            rois: rois,
            slotIndex: slotIndex,
            logKey: "suit_glyph",
            upscale: 4,
            suitGlyphLexicon: true,
            rowSliceTuning: narrow
        )
    }

    /// Extra pass when the stacked index is clipped.
    static func rankOnlyCornerText(
        cardCrop: CGImage,
        rowSliceColumn: Bool = false
    ) -> String {
        let row = usesRowSliceLayout(rowSliceColumn: rowSliceColumn, cardCrop: cardCrop)
        let rois: [CGRect] = row
            ? [
                CGRect(x: 0.02, y: 0.02, width: 0.44, height: 0.28),
            ]
            : [
                CGRect(x: 0.02, y: 0.62, width: 0.38, height: 0.34),
            ]
        return cornerIndexSuitPass(
            cardCrop: cardCrop,
            rois: rois,
            slotIndex: nil,
            logKey: "rank_corner",
            upscale: row ? 4 : 3,
            rowSliceTuning: row
        )
    }

    /// Warped single-card crops: top-left index only.
    static func cornerIndexSuitForSlotCard(
        cardCrop: CGImage,
        slotIndex: Int? = nil
    ) -> String {
        cornerIndexStackText(cardCrop: cardCrop, slotIndex: slotIndex)
    }

    /// Top-left index stack on **five-column reel slices** (rank + small suit glyph).
    static func cornerIndexSuitForRowSlice(
        cardCrop: CGImage,
        slotIndex: Int? = nil
    ) -> String {
        let rois: [CGRect] = [
            CGRect(x: 0.01, y: 0.70, width: 0.44, height: 0.28),
            CGRect(x: 0.01, y: 0.58, width: 0.40, height: 0.38),
            CGRect(x: 0.02, y: 0.48, width: 0.36, height: 0.44),
        ]
        return cornerIndexSuitPass(
            cardCrop: cardCrop,
            rois: rois,
            slotIndex: slotIndex,
            logKey: "row_index_suit",
            upscale: 3
        )
    }

    static func extract(
        cardCrop: CGImage,
        slotIndex: Int? = nil,
        rowSliceColumn: Bool = false
    ) -> OCRSnapshot {
        let narrowColumn = normalizedCardCropWidth(cardCrop) < 0.52

        let strip = VNRecognizeTextRequest()
        strip.recognitionLevel = .accurate
        strip.usesLanguageCorrection = false
        strip.applyEnglishCardOCRHints()
        strip.applyRowSliceOCRTuning(rowSliceColumn)
        /// Vision origin is bottom-left; skinny reel columns need a wider/top-heavy ROI so the index isn’t clipped.
        strip.regionOfInterest = rowSliceColumn
            ? CGRect(x: 0.02, y: 0.68, width: 0.50, height: 0.30)
            : narrowColumn
                ? CGRect(x: 0.02, y: 0.52, width: 0.90, height: 0.46)
                : CGRect(x: 0.03, y: 0.62, width: 0.52, height: 0.37)

        let suitStrip = VNRecognizeTextRequest()
        suitStrip.recognitionLevel = .accurate
        suitStrip.usesLanguageCorrection = false
        suitStrip.applyEnglishCardOCRHints()
        suitStrip.applyRowSliceOCRTuning(rowSliceColumn)
        /// Pip + small suit glyph under the rank in the top-left stack.
        suitStrip.regionOfInterest = rowSliceColumn
            ? CGRect(x: 0.02, y: 0.52, width: 0.34, height: 0.34)
            : narrowColumn
                ? CGRect(x: 0.02, y: 0.26, width: 0.55, height: 0.36)
                : CGRect(x: 0.02, y: 0.48, width: 0.36, height: 0.38)

        let bottomStrip = VNRecognizeTextRequest()
        bottomStrip.recognitionLevel = .accurate
        bottomStrip.usesLanguageCorrection = false
        bottomStrip.applyEnglishCardOCRHints()
        bottomStrip.applyRowSliceOCRTuning(rowSliceColumn)
        /// Upside-down index on the bottom-right of the card (low y, high x in Vision coords).
        bottomStrip.regionOfInterest = rowSliceColumn
            ? CGRect(x: 0.38, y: 0.02, width: 0.60, height: 0.38)
            : narrowColumn
                ? CGRect(x: 0.22, y: 0.02, width: 0.76, height: 0.50)
                : CGRect(x: 0.40, y: 0.02, width: 0.58, height: 0.44)

        let full = VNRecognizeTextRequest()
        full.recognitionLevel = .accurate
        full.usesLanguageCorrection = false
        full.applyEnglishCardOCRHints()
        full.applyRowSliceOCRTuning(rowSliceColumn)
        full.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

        /// Full-height left edge: on thin column crops the index stack sometimes sits between fixed corner ROIs.
        let leftBand = VNRecognizeTextRequest()
        leftBand.recognitionLevel = .accurate
        leftBand.usesLanguageCorrection = false
        leftBand.applyEnglishCardOCRHints()
        leftBand.applyRowSliceOCRTuning(rowSliceColumn)
        leftBand.regionOfInterest = rowSliceColumn
            ? CGRect(x: 0.02, y: 0.50, width: 0.46, height: 0.48)
            : narrowColumn
                ? CGRect(x: 0.02, y: 0.06, width: 0.52, height: 0.92)
                : CGRect(x: 0.02, y: 0.12, width: 0.44, height: 0.82)

        /// Large ♠ ♥ ♦ ♣ pips typically sit mid-card — corner strips often miss black suits entirely.
        let pipField = VNRecognizeTextRequest()
        pipField.recognitionLevel = .accurate
        pipField.usesLanguageCorrection = false
        pipField.applyEnglishCardOCRHints()
        pipField.applyRowSliceOCRTuning(rowSliceColumn)
        pipField.regionOfInterest = rowSliceColumn
            ? CGRect(x: 0.12, y: 0.38, width: 0.78, height: 0.48)
            : CGRect(x: 0.14, y: 0.20, width: 0.74, height: 0.52)

        var requests: [VNRecognizeTextRequest] = [strip, suitStrip, bottomStrip, pipField, leftBand]
        if rowSliceColumn == false {
            requests.append(full)
        }
        let handler = VNImageRequestHandler(cgImage: cardCrop, orientation: .up, options: [:])
        try? handler.perform(requests)

        let top = summarize(strip.results)
        let suitC = summarize(suitStrip.results)
        let bottom = summarize(bottomStrip.results)
        let pipCentral = summarize(pipField.results)
        var whole: (text: String, avg: Float) = rowSliceColumn ? ("", 0) : summarize(full.results)
        let leftText = summarize(leftBand.results)

        var combined = [top.text, suitC.text, bottom.text, pipCentral.text, whole.text, leftText.text]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        var confs = [top.avg, suitC.avg, bottom.avg, pipCentral.avg, whole.avg, leftText.avg].filter { $0 > 0 }
        var averageConfidence = confs.isEmpty ? 0 : confs.reduce(0, +) / Float(confs.count)

        var usedFastFullFrameSupplement = false
        if rowSliceColumn == false,
           shouldSupplementOCR(
            combinedText: combined,
            top: top.text,
            suit: suitC.text,
            bottom: bottom.text,
            narrowColumn: narrowColumn
        ) {
            let fastExtra = fallbackFullCardPass(cgImage: cardCrop)
            if fastExtra.text.isEmpty == false {
                usedFastFullFrameSupplement = true
                combined = [combined, fastExtra.text].filter { !$0.isEmpty }.joined(separator: "\n")
                if whole.text.isEmpty {
                    whole = fastExtra
                } else {
                    whole = (whole.text + " " + fastExtra.text, max(whole.avg, fastExtra.avg))
                }
                confs.append(fastExtra.avg)
                averageConfidence = confs.reduce(0, +) / Float(confs.count)
            }
        }

        /// iCloud / timing glitches sometimes leave every regional pass empty; `.fast` then `.accurate` full-frame passes often recover face-card indices.
        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rescueFast = fallbackFullCardPass(cgImage: cardCrop)
            if rescueFast.text.isEmpty == false {
                combined = rescueFast.text
                whole = rescueFast
                confs = [rescueFast.avg]
                averageConfidence = rescueFast.avg
            } else {
                let rescueAccurate = fullFramePass(cgImage: cardCrop, recognitionLevel: .accurate)
                if rescueAccurate.text.isEmpty == false {
                    combined = rescueAccurate.text
                    whole = rescueAccurate
                    confs = [rescueAccurate.avg]
                    averageConfidence = rescueAccurate.avg
                } else if let scaled = cardCrop.upscaledForOCR(factor: 2) {
                    let rescueScaled = fullFramePass(cgImage: scaled, recognitionLevel: .accurate)
                    if rescueScaled.text.isEmpty == false {
                        combined = rescueScaled.text
                        whole = rescueScaled
                        confs = [rescueScaled.avg]
                        averageConfidence = rescueScaled.avg
                    }
                }
            }
        }

        if SlotRecognitionDiagnostics.isLoggingEnabled, let tag = slotIndex {
            SlotRecognitionDiagnostics.log(
                """
                OCR[slot \(tag)] skinnyColumn=\(narrowColumn) \(cardCrop.width)×\(cardCrop.height) px | \
                corner='\(SlotRecognitionDiagnostics.ellipsis(top.text, limit: 60))' | \
                suitROI='\(SlotRecognitionDiagnostics.ellipsis(suitC.text, limit: 60))' | \
                mirror='\(SlotRecognitionDiagnostics.ellipsis(bottom.text, limit: 60))' | \
                pip='\(SlotRecognitionDiagnostics.ellipsis(pipCentral.text, limit: 60))' | \
                leftBand='\(SlotRecognitionDiagnostics.ellipsis(leftText.text, limit: 60))' | \
                full='\(SlotRecognitionDiagnostics.ellipsis(whole.text, limit: 80))' | \
                fast_supp=\(usedFastFullFrameSupplement) pooled_avg=\(String(format: "%.3f", averageConfidence))
                • combined_pool=\(SlotRecognitionDiagnostics.ellipsis(combined, limit: 200))
                """
            )
        }

        return OCRSnapshot(
            combinedText: combined,
            topStripText: top.text,
            suitCornerText: suitC.text,
            bottomStripText: bottom.text,
            leftBandText: leftText.text,
            pipCentralText: pipCentral.text,
            fullCardText: whole.text,
            averageConfidence: averageConfidence
        )
    }

    /// When corner ROIs yield nothing on a skinny column crop, `.fast` on the whole card sometimes still finds the index glyphs.
    private static func fallbackFullCardPass(cgImage: CGImage) -> (text: String, avg: Float) {
        fullFramePass(cgImage: cgImage, recognitionLevel: .fast)
    }

    private static func fullFramePass(
        cgImage: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel
    ) -> (text: String, avg: Float) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = recognitionLevel
        req.usesLanguageCorrection = false
        req.applyEnglishCardOCRHints()
        req.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([req])
        return summarize(req.results)
    }

    private static func normalizedCardCropWidth(_ image: CGImage) -> CGFloat {
        guard image.height > 0 else { return 1 }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    /// Five-column reel slices are nearly square — `width/height` alone misses them without `rowSliceColumn`.
    private static func usesRowSliceLayout(rowSliceColumn: Bool, cardCrop: CGImage) -> Bool {
        rowSliceColumn || normalizedCardCropWidth(cardCrop) < 0.52
    }

    /// `regions` use **top-left** normalized coords (CGImage origin), not Vision bottom-left ROIs.
    private static func physicalCropOCR(
        cardCrop: CGImage,
        regions: [CGRect],
        slotIndex: Int?,
        logKey: String,
        upscale: Int,
        suitGlyphLexicon: Bool,
        minimumTextHeight: Float
    ) -> String {
        var parts: [String] = []
        parts.reserveCapacity(regions.count * 2)
        for region in regions {
            let pixel = topLeftPixelRect(region, image: cardCrop)
            guard pixel.width >= 10, pixel.height >= 10,
                  let cropped = cardCrop.cropping(to: pixel)
            else { continue }
            let scaled = cropped.upscaledForOCR(factor: upscale) ?? cropped
            let accurate = recognizeText(
                on: scaled,
                level: .accurate,
                minimumTextHeight: minimumTextHeight,
                suitGlyphLexicon: suitGlyphLexicon
            )
            if accurate.isEmpty == false {
                parts.append(accurate)
                continue
            }
            let fast = recognizeText(
                on: scaled,
                level: .fast,
                minimumTextHeight: minimumTextHeight * 0.85,
                suitGlyphLexicon: suitGlyphLexicon
            )
            if fast.isEmpty == false {
                parts.append(fast)
            }
        }
        let merged = parts.joined(separator: " ")
        if SlotRecognitionDiagnostics.isLoggingEnabled, let tag = slotIndex {
            SlotRecognitionDiagnostics.log(
                "OCR[slot \(tag)] \(logKey)='\(SlotRecognitionDiagnostics.ellipsis(merged, limit: 100))'"
            )
        }
        return merged
    }

    private static func recognizeText(
        on image: CGImage,
        level: VNRequestTextRecognitionLevel,
        minimumTextHeight: Float,
        suitGlyphLexicon: Bool
    ) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        req.usesLanguageCorrection = false
        req.applyEnglishCardOCRHints()
        req.minimumTextHeight = minimumTextHeight
        if suitGlyphLexicon {
            req.customWords = suitGlyphCustomWords
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try? handler.perform([req])
        return summarize(req.results).text
    }

    private static func topLeftPixelRect(_ normalized: CGRect, image: CGImage) -> CGRect {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        return CGRect(
            x: normalized.origin.x * w,
            y: normalized.origin.y * h,
            width: normalized.width * w,
            height: normalized.height * h
        ).integral
    }

    private static func shouldSupplementOCR(
        combinedText: String,
        top: String,
        suit: String,
        bottom: String,
        narrowColumn: Bool
    ) -> Bool {
        let trimmed = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 8 { return false }
        /// Typical failure: all regional passes empty after a harsh crop.
        if top.isEmpty, suit.isEmpty, bottom.isEmpty { return true }
        if trimmed.count < 2 { return true }
        /// Skinny column + only the full-frame pass hinted text — bracket ROIs likely missed glyphs.
        if narrowColumn, top.isEmpty, bottom.isEmpty, trimmed.count < 14 { return true }
        return false
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

private extension CGImage {
    /// Bilinear upscale for OCR when native resolution returns no observations (e.g. some face-card crops).
    func upscaledForOCR(factor: Int) -> CGImage? {
        guard factor > 1 else { return self }
        let nw = width * factor
        let nh = height * factor
        guard nw > 0, nh > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: nw,
                  height: nh,
                  bitsPerComponent: 8,
                  bytesPerRow: nw * 4,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}

private extension VNRecognizeTextRequest {
    /// Reduce accidental non-Latin “phantom text” when reading simple slot artwork.
    func applyEnglishCardOCRHints() {
        recognitionLanguages = ["en-US"]
    }

    /// Shallow reel columns: smaller glyphs benefit from a lower minimum text height.
    func applyRowSliceOCRTuning(_ rowSliceColumn: Bool) {
        guard rowSliceColumn else { return }
        minimumTextHeight = 0.018
    }
}
