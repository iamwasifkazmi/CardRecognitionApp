import CoreGraphics

/// Counts plausible **ink** in the card “court” (large centered pip region), skipping near-white cardstock.
private struct CourtInkSummary {
    var nonWhiteCandidates: Int = 0
    var brightCardRedInk: Int = 0
    /// Dark glyphs + UI neutrals roughly where ♠♣ inks sit — **not** used to distinguish ♠ vs ♣.
    var darkNeutralInk: Int = 0
    /// Truly blue ♦ skins (distinct from ♥♦ reds).
    var blueInk: Int = 0

    var sumRedR: Float = 0
    var sumRedG: Float = 0
    var sumRedB: Float = 0

    mutating func recordNonNearWhitePixel(
        _ rF: Float, _ gF: Float, _ bF: Float,
        lum: Float
    ) -> Bool {
        /// Skip bright cardstock highlights.
        if lum > 248.8 { return false }
        if rF + gF + bF > 758 { return false }
        nonWhiteCandidates += 1

        if isBlueInk(rF: rF, gF: gF, bF: bF, lum: lum) {
            blueInk += 1
            return true
        }
        /// Order matters: real red ♥♦ beats dark neutrals before maroon bleed.
        if isBrightCasinoCardRed(rF: rF, gF: gF, bF: bF, lum: lum) {
            brightCardRedInk += 1
            sumRedR += rF
            sumRedG += gF
            sumRedB += bF
            return true
        }
        if isDarkNeutralGlyph(rF: rF, gF: gF, bF: bF, lum: lum) {
            darkNeutralInk += 1
            return true
        }
        return true
    }
}

/// OCR never sees monochrome ♠♣ pips reliably; this heuristic only guesses **bright red ♥♦**.
/// Older corner crops mistook **maroon/dealer felt bleed** outside the cardstock for card-red.
enum SuitColorHeuristic: Sendable {
    static func infer(for image: CGImage) -> Suit? {
        guard image.width > 28, image.height > 28 else { return nil }
        guard let center = summarizeCenterCourtInk(image: image) else { return nil }

        guard center.nonWhiteCandidates > 96 else { return nil }

        let n = Float(max(center.nonWhiteCandidates, 1))
        let redShare = Float(center.brightCardRedInk) / n
        let darkShare = Float(center.darkNeutralInk) / n
        let blueShare = Float(center.blueInk) / n

        /// UI-style blue ♦ (no OCR symbol).
        if center.brightCardRedInk < center.blueInk * 2 + 8,
           blueShare > 0.05,
           redShare < 0.065 {
            return .diamonds
        }

        /// Large black ♠ / ♣: many dark ink pixels, almost no chromatic red.
        if darkShare >= 0.092, redShare < 0.034 {
            return nil
        }
        if darkShare >= 0.078, redShare < 0.03, center.brightCardRedInk < 110 {
            return nil
        }

        /// Red fill can share the court with thick black outlines — use share + vote totals, not raw count alone.
        guard center.brightCardRedInk >= 72 else { return nil }
        guard redShare >= 0.026 else { return nil }

        let redVotes = Float(center.brightCardRedInk)
        let darkVotes = Float(max(center.darkNeutralInk, 1))
        guard redVotes > darkVotes * 0.88 || redShare > darkShare * 1.06 else {
            return nil
        }

        guard let hue = hueFromBrightRed(summary: center) else { return nil }
        if hue.avgB + 3 < hue.avgG * 1.02 {
            return .hearts
        }
        if hue.avgB > hue.avgG * 1.14, hue.avgB > hue.avgG + 6 {
            return .diamonds
        }
        return .hearts
    }

    /// Used by the silhouette stage so **black ♠ ♣ artwork never gets mis-read as ♦ simply from fill correlation**.
    static func courtShowsRedPipPigment(_ image: CGImage) -> Bool {
        guard let center = summarizeCenterCourtInk(image: image) else { return false }
        let n = Float(max(center.nonWhiteCandidates, 1))
        let redShare = Float(center.brightCardRedInk) / n
        let darkShare = Float(center.darkNeutralInk) / n
        /// Require real chromatic ink, not a tiny OCR speck nor all-dark clubs.
        return center.brightCardRedInk >= 52 &&
            redShare >= 0.020 &&
            (redShare >= darkShare * 0.45 || Float(center.brightCardRedInk) >= Float(center.darkNeutralInk) * 0.22)
    }

    /// Center court is mostly black ink (♠ / ♣) — use before monochrome shape guessing.
    static func courtShowsBlackPips(_ image: CGImage) -> Bool {
        guard let center = summarizeCenterCourtInk(image: image) else { return false }
        let n = Float(max(center.nonWhiteCandidates, 1))
        let darkShare = Float(center.darkNeutralInk) / n
        let redShare = Float(center.brightCardRedInk) / n
        return center.darkNeutralInk >= 64 &&
            darkShare >= 0.07 &&
            redShare < 0.045 &&
            Float(center.darkNeutralInk) > Float(center.brightCardRedInk) * 1.6
    }

    /// Softer than `courtShowsRedPipPigment` — enough to run ♥/♦ **templates** on standard Bicycle reds that miss strict chroma gates.
    static func courtSuggestsRedPipsWeak(_ image: CGImage) -> Bool {
        guard let center = summarizeCenterCourtInk(image: image) else { return false }
        let n = Float(max(center.nonWhiteCandidates, 1))
        let redShare = Float(center.brightCardRedInk) / n
        let darkShare = Float(center.darkNeutralInk) / n
        return center.brightCardRedInk >= 22 &&
            redShare >= 0.009 &&
            (redShare >= darkShare * 0.28 || Float(center.brightCardRedInk) >= Float(max(center.darkNeutralInk, 1)) * 0.14)
    }

    private static func summarizeCenterCourtInk(image: CGImage) -> CourtInkSummary? {
        let rect = CardCourtSampling.centerCourtIntegralRect(for: image, framing: .standard)
        return rasterizeInkSummary(cropping: image, toPixels: rect)
    }

    private static func rasterizeInkSummary(cropping image: CGImage, toPixels rect: CGRect) -> CourtInkSummary? {
        guard let crop = image.cropping(to: rect) else { return nil }

        let cw = crop.width
        let ch = crop.height
        let bpp = 4
        let rowBytes = cw * bpp
        var data = [UInt8](repeating: 0, count: Int(max(ch * rowBytes, 1)))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &data,
                  width: cw,
                  height: ch,
                  bitsPerComponent: 8,
                  bytesPerRow: rowBytes,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))

        var summary = CourtInkSummary()
        for y in 0 ..< Int(ch) {
            for x in 0 ..< Int(cw) {
                let i = y * Int(rowBytes) + x * bpp
                let rF = Float(data[i])
                let gF = Float(data[i &+ 1])
                let bF = Float(data[i &+ 2])
                let lum = 0.299 * rF + 0.587 * gF + 0.114 * bF
                guard summary.recordNonNearWhitePixel(rF, gF, bF, lum: lum) else { continue }
            }
        }
        return summary
    }
}

// MARK: - Pixel tests

private func isBrightCasinoCardRed(rF: Float, gF: Float, bF: Float, lum _: Float) -> Bool {
    let sum = rF + gF + bF
    let mg = max(gF, bF)
    let chroma = rF - mg

    /// Deep saturated UI reds (and JPEG-crushed card ink) are often **dark in luminance** because G/B are low;
    /// an earlier `lum >= 132` gate incorrectly rejected every real ♥/♦ pixel on some crops.
    if rF >= 136, chroma >= 36, sum >= 268, rF > mg * 1.20 {
        /// Block muddy maroon that still has a red channel lead but very low saturation + energy.
        if rF < 158, sum < 292, chroma < 42 {
            return false
        }
        return true
    }

    /// Brighter reds (glossier skins / glare).
    if rF >= 156, chroma >= 44, sum >= 302 {
        return true
    }
    return false
}

private func isDarkNeutralGlyph(rF: Float, gF: Float, bF: Float, lum: Float) -> Bool {
    let mx = max(rF, max(gF, bF))
    let mn = min(rF, min(gF, bF))
    if mx <= 146, lum <= 160, mn <= mx * 1.06 {
        return true
    }
    if lum < 146, mx < 154, mx - mn < 86 {
        return true
    }
    return false
}

private func isBlueInk(rF: Float, gF: Float, bF: Float, lum _: Float) -> Bool {
    bF > max(rF, gF) * 1.14 && bF > 92 && bF > rF + 30 && bF > gF + 18
}

private struct RedHueMeans {
    let avgR: Float
    let avgG: Float
    let avgB: Float
}

private func hueFromBrightRed(summary: CourtInkSummary) -> RedHueMeans? {
    guard summary.brightCardRedInk >= 48 else { return nil }
    let n = Float(summary.brightCardRedInk)
    return RedHueMeans(
        avgR: summary.sumRedR / n,
        avgG: summary.sumRedG / n,
        avgB: summary.sumRedB / n
    )
}
