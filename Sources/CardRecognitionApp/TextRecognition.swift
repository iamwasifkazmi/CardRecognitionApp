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
        var fullCardText: String
        var averageConfidence: Float
    }

    /// Reads indexing corners, a suit-pip strip, mirrored corner, and full-card pass.
    /// Pass `slotIndex` (1…5) to include this crop in Xcode console diagnostics when `SlotRecognitionDiagnostics.isLoggingEnabled`.
    static func extract(cardCrop: CGImage, slotIndex: Int? = nil) -> OCRSnapshot {
        let narrowColumn = normalizedCardCropWidth(cardCrop) < 0.52

        let strip = VNRecognizeTextRequest()
        strip.recognitionLevel = .accurate
        strip.usesLanguageCorrection = false
        strip.applyEnglishCardOCRHints()
        /// Vision origin is bottom-left; skinny reel columns need a wider/top-heavy ROI so the index isn’t clipped.
        strip.regionOfInterest = narrowColumn
            ? CGRect(x: 0.02, y: 0.52, width: 0.90, height: 0.46)
            : CGRect(x: 0.03, y: 0.62, width: 0.52, height: 0.37)

        let suitStrip = VNRecognizeTextRequest()
        suitStrip.recognitionLevel = .accurate
        suitStrip.usesLanguageCorrection = false
        suitStrip.applyEnglishCardOCRHints()
        /// Pip + small suit glyph under the rank in the top-left stack.
        suitStrip.regionOfInterest = narrowColumn
            ? CGRect(x: 0.02, y: 0.26, width: 0.55, height: 0.36)
            : CGRect(x: 0.02, y: 0.34, width: 0.30, height: 0.30)

        let bottomStrip = VNRecognizeTextRequest()
        bottomStrip.recognitionLevel = .accurate
        bottomStrip.usesLanguageCorrection = false
        bottomStrip.applyEnglishCardOCRHints()
        /// Upside-down index on the bottom-right of the card (low y, high x in Vision coords).
        bottomStrip.regionOfInterest = narrowColumn
            ? CGRect(x: 0.22, y: 0.02, width: 0.76, height: 0.50)
            : CGRect(x: 0.40, y: 0.02, width: 0.58, height: 0.44)

        let full = VNRecognizeTextRequest()
        full.recognitionLevel = .accurate
        full.usesLanguageCorrection = false
        full.applyEnglishCardOCRHints()
        full.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

        /// Full-height left edge: on thin column crops the index stack sometimes sits between fixed corner ROIs.
        let leftBand = VNRecognizeTextRequest()
        leftBand.recognitionLevel = .accurate
        leftBand.usesLanguageCorrection = false
        leftBand.applyEnglishCardOCRHints()
        leftBand.regionOfInterest = narrowColumn
            ? CGRect(x: 0.02, y: 0.06, width: 0.52, height: 0.92)
            : CGRect(x: 0.02, y: 0.12, width: 0.44, height: 0.82)

        /// Large ♠ ♥ ♦ ♣ pips typically sit mid-card — corner strips often miss black suits entirely.
        let pipField = VNRecognizeTextRequest()
        pipField.recognitionLevel = .accurate
        pipField.usesLanguageCorrection = false
        pipField.applyEnglishCardOCRHints()
        pipField.regionOfInterest = CGRect(x: 0.14, y: 0.20, width: 0.74, height: 0.52)

        let handler = VNImageRequestHandler(cgImage: cardCrop, orientation: .up, options: [:])
        try? handler.perform([strip, suitStrip, bottomStrip, pipField, full, leftBand])

        let top = summarize(strip.results)
        let suitC = summarize(suitStrip.results)
        let bottom = summarize(bottomStrip.results)
        let pipCentral = summarize(pipField.results)
        var whole = summarize(full.results)
        let leftText = summarize(leftBand.results)

        var combined = [top.text, suitC.text, bottom.text, pipCentral.text, whole.text, leftText.text]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        var confs = [top.avg, suitC.avg, bottom.avg, pipCentral.avg, whole.avg, leftText.avg].filter { $0 > 0 }
        var averageConfidence = confs.isEmpty ? 0 : confs.reduce(0, +) / Float(confs.count)

        var usedFastFullFrameSupplement = false
        if shouldSupplementOCR(
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

private extension VNRecognizeTextRequest {
    /// Reduce accidental non-Latin “phantom text” when reading simple slot artwork.
    func applyEnglishCardOCRHints() {
        recognitionLanguages = ["en-US"]
    }
}
