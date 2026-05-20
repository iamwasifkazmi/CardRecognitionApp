import CoreGraphics

/// Detects suit **icons** (♠ ♥ ♦ ♣) via template match — OCR cannot read slot-machine glyphs as text.
enum SuitIconDetector: Sendable {
    enum Method: String, Sendable {
        case indexGlyph
        case centerCourt
    }

    static func detect(
        cardCrop: CGImage,
        rowSliceColumn: Bool,
        slotIndex: Int?
    ) -> (suit: Suit, method: Method)? {
        if let hit = detectIndexGlyph(cardCrop: cardCrop, rowSliceColumn: rowSliceColumn, slotIndex: slotIndex) {
            return hit
        }
        if let hit = detectCenterCourt(cardCrop: cardCrop) {
            return hit
        }
        return nil
    }

    private static func detectIndexGlyph(
        cardCrop: CGImage,
        rowSliceColumn: Bool,
        slotIndex: Int?
    ) -> (suit: Suit, method: Method)? {
        let regions = suitGlyphRegions(rowSliceColumn: rowSliceColumn)
        var best: (Suit, Float)?
        for (index, region) in regions.enumerated() {
            let pixel = pixelRect(region, in: cardCrop)
            guard pixel.width >= 12, pixel.height >= 12,
                  let crop = cardCrop.cropping(to: pixel) else { continue }

            let allowed = chromaAllowedSuits(in: crop)
            guard let suit = SuitTemplateShapeMatcher.inferFromIconCrop(crop, allowed: allowed) else { continue }

            let score: Float = 1
            if best == nil || score > best!.1 {
                best = (suit, score)
            }
            if SlotRecognitionDiagnostics.isLoggingEnabled, let tag = slotIndex {
                SlotRecognitionDiagnostics.log("OCR[slot \(tag)] suit_icon[\(index)] → \(suit.rawValue)")
            }
        }
        guard let pick = best?.0 else { return nil }
        return (pick, .indexGlyph)
    }

    private static func detectCenterCourt(cardCrop: CGImage) -> (suit: Suit, method: Method)? {
        if SuitColorHeuristic.courtShowsRedPipPigment(cardCrop) {
            if let suit = SuitTemplateShapeMatcher.inferRedSuitsStrict(for: cardCrop) {
                return (suit, .centerCourt)
            }
            if let suit = SuitColorHeuristic.infer(for: cardCrop) {
                return (suit, .centerCourt)
            }
        }
        if SuitColorHeuristic.courtShowsBlackPips(cardCrop),
           let suit = SuitTemplateShapeMatcher.inferBlackSuitsStrict(for: cardCrop) {
            return (suit, .centerCourt)
        }
        return nil
    }

    private static func suitGlyphRegions(rowSliceColumn: Bool) -> [CGRect] {
        if rowSliceColumn {
            return [
                CGRect(x: 0.03, y: 0.20, width: 0.42, height: 0.22),
                CGRect(x: 0.03, y: 0.26, width: 0.38, height: 0.18),
                CGRect(x: 0.02, y: 0.04, width: 0.48, height: 0.34),
            ]
        }
        return [
            CGRect(x: 0.04, y: 0.12, width: 0.34, height: 0.16),
            CGRect(x: 0.04, y: 0.16, width: 0.30, height: 0.14),
            CGRect(x: 0.03, y: 0.02, width: 0.44, height: 0.28),
        ]
    }

    private static func chromaAllowedSuits(in crop: CGImage) -> Set<Suit>? {
        guard let summary = chromaSummary(crop) else { return nil }
        if summary.redShare >= 0.18 { return Set([.hearts, .diamonds]) }
        if summary.darkShare >= 0.28 { return Set([.spades, .clubs]) }
        return nil
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
                if r >= 132, r - mg >= 32, r > mg * 1.16 { red += 1 }
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
