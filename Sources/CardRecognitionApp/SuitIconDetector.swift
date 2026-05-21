import CoreGraphics

/// Detects suit **icons** (♠ ♥ ♦ ♣) via OCR, corner/center shape heuristics, and template match.
enum SuitIconDetector: Sendable {
    enum Method: String, Sendable {
        case ocr
        case indexShape
        case centerShape
        case indexIcon
        case centerIcon
        case pipColor
    }

    static func detect(
        cardCrop: CGImage,
        rowSliceColumn: Bool,
        slotIndex: Int?,
        rankKnown: Bool
    ) -> (suit: Suit, method: Method)? {
        guard rankKnown else { return nil }
        let allowed = chromaAllowedSuitsFromIndex(cardCrop: cardCrop, rowSliceColumn: rowSliceColumn)

        if let hit = detectIndexGlyphTemplate(
            cardCrop: cardCrop,
            rowSliceColumn: rowSliceColumn,
            slotIndex: slotIndex,
            allowed: allowed
        ) {
            return hit
        }
        if let hit = detectIndexCornerShape(
            cardCrop: cardCrop,
            rowSliceColumn: rowSliceColumn,
            slotIndex: slotIndex,
            allowed: allowed
        ) {
            return hit
        }
        if let hit = detectSuitFromCenterCourtRed(cardCrop: cardCrop, slotIndex: slotIndex, allowed: allowed) {
            return hit
        }
        if let hit = detectCenterPipShape(cardCrop: cardCrop, slotIndex: slotIndex, allowed: allowed) {
            return hit
        }
        if let hit = detectSuitFromCenterCourtBlack(cardCrop: cardCrop, slotIndex: slotIndex, allowed: allowed) {
            return hit
        }
        return nil
    }

    /// Red pips: color + center templates (before corner silhouettes).
    private static func detectSuitFromCenterCourtRed(
        cardCrop: CGImage,
        slotIndex: Int?,
        allowed: Set<Suit>?
    ) -> (suit: Suit, method: Method)? {
        guard let center = centerCourtCrop(cardCrop) else { return nil }
        guard SuitColorHeuristic.courtShowsRedPipPigment(cardCrop)
            || SuitColorHeuristic.courtSuggestsRedPipsWeak(cardCrop) else { return nil }

        if var suit = SuitColorHeuristic.infer(for: cardCrop) {
            suit = preferPartnerSuitWhenAmbiguous(suit, margin: 0.05)
            guard accepts(suit, allowed: allowed) else { return nil }
            log(slotIndex, "pip_color → \(suit.rawValue)")
            return (suit, .pipColor)
        }
        if let suit = SuitTemplateShapeMatcher.inferRedSuitsOnly(for: center),
           accepts(suit, allowed: allowed) {
            log(slotIndex, "center_template_red → \(suit.rawValue)")
            return (suit, .centerIcon)
        }
        return nil
    }

    /// Black center templates only after corner shapes — reduces ♣→♠ when the index glyph was readable.
    private static func detectSuitFromCenterCourtBlack(
        cardCrop: CGImage,
        slotIndex: Int?,
        allowed: Set<Suit>?
    ) -> (suit: Suit, method: Method)? {
        guard let center = centerCourtCrop(cardCrop) else { return nil }
        guard SuitColorHeuristic.courtShowsBlackPips(cardCrop) else { return nil }
        if let suit = SuitTemplateShapeMatcher.inferBlackSuitsStrict(for: center),
           accepts(suit, allowed: allowed) {
            log(slotIndex, "center_template_black_strict → \(suit.rawValue)")
            return (suit, .centerIcon)
        }
        if let suit = SuitTemplateShapeMatcher.inferBlackSuitsOnly(for: center),
           accepts(suit, allowed: allowed) {
            log(slotIndex, "center_template_black → \(suit.rawValue)")
            return (suit, .centerIcon)
        }
        return nil
    }

    private static func centerCourtCrop(_ cardCrop: CGImage) -> CGImage? {
        let w = CGFloat(cardCrop.width)
        let h = CGFloat(cardCrop.height)
        guard w > 24, h > 24 else { return nil }
        let roi = CGRect(x: w * 0.18, y: h * 0.22, width: w * 0.64, height: h * 0.56).integral
        return cardCrop.cropping(to: roi)
    }

    private static func accepts(_ suit: Suit, allowed: Set<Suit>?) -> Bool {
        guard let allowed else { return true }
        return allowed.contains(suit)
    }

    // MARK: - Index corner

    private static func detectIndexCornerShape(
        cardCrop: CGImage,
        rowSliceColumn: Bool,
        slotIndex: Int?,
        allowed: Set<Suit>?
    ) -> (suit: Suit, method: Method)? {
        let regions = indexStackRegions(rowSliceColumn: rowSliceColumn)
        for (index, region) in regions.enumerated() {
            let pixel = pixelRect(region, in: cardCrop)
            guard pixel.width >= 10, pixel.height >= 10,
                  let crop = cardCrop.cropping(to: pixel) else { continue }
            if var suit = CornerIndexSuitInferencer.infer(for: crop, narrowColumn: rowSliceColumn) {
                suit = preferPartnerSuitWhenAmbiguous(suit, margin: 0.05)
                guard accepts(suit, allowed: allowed) else { continue }
                log(slotIndex, "index_shape[\(index)] → \(suit.rawValue)")
                return (suit, .indexShape)
            }
        }
        return nil
    }

    private static func detectIndexGlyphTemplate(
        cardCrop: CGImage,
        rowSliceColumn: Bool,
        slotIndex: Int?,
        allowed: Set<Suit>?
    ) -> (suit: Suit, method: Method)? {
        let regions = suitGlyphRegions(rowSliceColumn: rowSliceColumn)
        var best: (Suit, Float, Float)?
        for (index, region) in regions.enumerated() {
            let pixel = pixelRect(region, in: cardCrop)
            guard pixel.width >= 12, pixel.height >= 12,
                  let crop = cardCrop.cropping(to: pixel) else { continue }

            guard let allowed = chromaAllowedSuits(in: crop) else { continue }
            guard let scored = SuitTemplateShapeMatcher.bestIconCropMatch(crop, allowed: allowed) else { continue }

            if best == nil || scored.score > best!.1 {
                best = (scored.suit, scored.score, scored.margin)
            }
                log(slotIndex, "suit_icon[\(index)] → \(scored.suit.rawValue) score=\(String(format: "%.3f", scored.score)) margin=\(String(format: "%.3f", scored.margin))")
        }
        guard let pick = best else { return nil }
        /// Same gates as `inferFromIconCrop` — avoids ♣ on empty row slices (score≈1, margin≈0).
        guard pick.1 >= 0.236, pick.2 >= 0.038 else { return nil }
        if pick.1 >= 0.90, pick.2 < 0.03 { return nil }
        guard accepts(pick.0, allowed: allowed) else { return nil }
        let suit = preferPartnerSuitWhenAmbiguous(pick.0, margin: pick.2)
        return (suit, .indexIcon)
    }

    /// Index-corner ink color — avoids center-court red/black bleed confusing allowed suits.
    private static func chromaAllowedSuitsFromIndex(
        cardCrop: CGImage,
        rowSliceColumn: Bool
    ) -> Set<Suit>? {
        var redVotes = 0
        var darkVotes = 0
        for region in indexStackRegions(rowSliceColumn: rowSliceColumn).prefix(2) {
            let pixel = pixelRect(region, in: cardCrop)
            guard pixel.width >= 8, pixel.height >= 8,
                  let crop = cardCrop.cropping(to: pixel),
                  let summary = chromaSummary(crop) else { continue }
            if summary.redShare >= 0.09 { redVotes += 1 }
            if summary.darkShare >= 0.14 { darkVotes += 1 }
        }
        if redVotes > darkVotes { return Set([.hearts, .diamonds]) }
        if darkVotes > redVotes { return Set([.spades, .clubs]) }
        if let center = centerCourtCrop(cardCrop) {
            return chromaAllowedSuits(in: center)
        }
        return nil
    }

    /// Template/shape ties on slot art often flip ♥↔♦ and ♣↔♠ — prefer the paired suit when margin is thin.
    private static func preferPartnerSuitWhenAmbiguous(_ suit: Suit, margin: Float) -> Suit {
        guard margin < 0.062 else { return suit }
        switch suit {
        case .diamonds: return .hearts
        case .spades: return .clubs
        default: return suit
        }
    }

    // MARK: - Center pip

    private static func detectCenterPipShape(
        cardCrop: CGImage,
        slotIndex: Int?,
        allowed: Set<Suit>?
    ) -> (suit: Suit, method: Method)? {
        if let suit = CenterPipSuitInferencer.infer(for: cardCrop), accepts(suit, allowed: allowed) {
            log(slotIndex, "center_shape → \(suit.rawValue)")
            return (suit, .centerShape)
        }
        return nil
    }

    private static func indexStackRegions(rowSliceColumn: Bool) -> [CGRect] {
        if rowSliceColumn {
            return [
                CGRect(x: 0.02, y: 0.02, width: 0.52, height: 0.40),
                CGRect(x: 0.02, y: 0.08, width: 0.48, height: 0.34),
            ]
        }
        return [
            CGRect(x: 0.03, y: 0.02, width: 0.46, height: 0.34),
            CGRect(x: 0.03, y: 0.06, width: 0.42, height: 0.28),
        ]
    }

    private static func suitGlyphRegions(rowSliceColumn: Bool) -> [CGRect] {
        if rowSliceColumn {
            return [
                CGRect(x: 0.02, y: 0.14, width: 0.44, height: 0.22),
                CGRect(x: 0.02, y: 0.20, width: 0.40, height: 0.20),
                CGRect(x: 0.02, y: 0.02, width: 0.50, height: 0.38),
                CGRect(x: 0.10, y: 0.28, width: 0.72, height: 0.48),
            ]
        }
        return [
            CGRect(x: 0.03, y: 0.10, width: 0.36, height: 0.18),
            CGRect(x: 0.03, y: 0.14, width: 0.32, height: 0.16),
            CGRect(x: 0.02, y: 0.02, width: 0.46, height: 0.30),
        ]
    }

    private static func chromaAllowedSuits(in crop: CGImage) -> Set<Suit>? {
        guard let summary = chromaSummary(crop) else { return nil }
        if summary.redShare >= 0.10 { return Set([.hearts, .diamonds]) }
        if summary.darkShare >= 0.18 { return Set([.spades, .clubs]) }
        return nil
    }

    private static func log(_ slotIndex: Int?, _ message: String) {
        guard let tag = slotIndex else { return }
        SlotRecognitionDiagnostics.logOCR("OCR[slot \(tag)] \(message)")
    }

    private static func centerCourtChromaSupportsPipGuess(_ image: CGImage) -> Bool {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        guard w > 24, h > 24 else { return false }
        let roi = CGRect(x: w * 0.18, y: h * 0.22, width: w * 0.64, height: h * 0.56).integral
        guard let crop = image.cropping(to: roi) else { return false }
        return conspicuousPipInkFraction(crop) >= 0.022
    }

    private static func conspicuousPipInkFraction(_ image: CGImage) -> Float {
        let w = image.width
        let h = image.height
        guard w > 2, h > 2 else { return 0 }
        let bpp = 4
        let rowBytes = w * bpp
        var data = [UInt8](repeating: 0, count: h * rowBytes)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &data,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: rowBytes,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var ink = 0
        var samples = 0
        for y in 0 ..< h {
            let row = y * rowBytes
            for x in 0 ..< w {
                let o = row + x * bpp
                let r = Float(data[o])
                let g = Float(data[o &+ 1])
                let b = Float(data[o &+ 2])
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                if lum > 252 { continue }
                samples += 1
                let mx = max(r, max(g, b))
                let mn = min(r, min(g, b))
                let mg = max(g, b)
                if r >= 128, r - mg >= 28, r > mg * 1.12 { ink += 1; continue }
                if mx - mn >= 22 { ink += 1; continue }
                if lum < 92, mx < 125 { ink += 1; continue }
            }
        }
        guard samples > 0 else { return 0 }
        return Float(ink) / Float(samples)
    }

    private struct ChromaSummary {
        var redShare: Float
        var darkShare: Float
    }

    private static func chromaSummary(_ image: CGImage) -> ChromaSummary? {
        let w = image.width
        let h = image.height
        guard w > 4, h > 4 else { return nil }
        let bpp = 4
        let rowBytes = w * bpp
        var data = [UInt8](repeating: 0, count: h * rowBytes)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &data,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: rowBytes,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var red = 0
        var dark = 0
        var samples = 0
        for y in 0 ..< h {
            let row = y * rowBytes
            for x in 0 ..< w {
                let o = row + x * bpp
                let r = Float(data[o])
                let g = Float(data[o &+ 1])
                let b = Float(data[o &+ 2])
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                if lum > 248 { continue }
                samples += 1
                let mg = max(g, b)
                if r >= 128, r - mg >= 28, r > mg * 1.12 { red += 1 }
                else if lum < 162, max(r, max(g, b)) < 158 { dark += 1 }
            }
        }
        guard samples > 0 else { return nil }
        let n = Float(samples)
        return ChromaSummary(redShare: Float(red) / n, darkShare: Float(dark) / n)
    }

    private static func pixelRect(_ normalized: CGRect, in image: CGImage) -> CGRect {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        return CGRect(
            x: normalized.origin.x * w,
            y: normalized.origin.y * h,
            width: normalized.width * w,
            height: normalized.height * h
        ).integral
    }
}
