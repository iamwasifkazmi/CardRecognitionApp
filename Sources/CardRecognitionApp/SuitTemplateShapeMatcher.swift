import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Correlates the warped **court** ROI with SF Symbol suits using **edge + fill** (fill alone biased toward ♦).
/// When `SuitColorHeuristic.courtShowsRedPipPigment` is false, callers should use **only ♠ ♣** so black art is not mislabeled ♦.
enum SuitTemplateShapeMatcher: Sendable {
    private static let grid = 72
    private static let wEdge: Float = 0.58
    private static let wFill: Float = 0.42

    /// Monochrome/black cards: ♠ ♣ only.
    private static let cosineAcceptBW: Float = 0.38
    private static let marginMinBW: Float = 0.045

    private static let suitSymbolNames: [Suit: String] = [
        .spades: "suit.spade.fill",
        .hearts: "suit.heart.fill",
        .diamonds: "suit.diamond.fill",
        .clubs: "suit.club.fill",
    ]

    nonisolated(unsafe) private static var cachedFill: [Suit: [Float]]?
    nonisolated(unsafe) private static var cachedEdge: [Suit: [Float]]?

    static func inferBlackSuitsOnly(for image: CGImage) -> Suit? {
        inferMatching(for: image, allowed: Set([.spades, .clubs]), cosineAccept: cosineAcceptBW, marginMin: marginMinBW)
    }

    /// When the ROI is dominated by ♥♦ pigments but OCR lost the glyphs.
    static func inferRedSuitsOnly(for image: CGImage) -> Suit? {
        inferMatching(for: image, allowed: Set([.hearts, .diamonds]), cosineAccept: 0.36, marginMin: 0.052)
    }

    /// Diagnostic / uncommon layouts only.
    static func infer(for image: CGImage) -> Suit? {
        inferMatching(for: image, allowed: nil, cosineAccept: 0.32, marginMin: 0.04)
    }

    private static func inferMatching(
        for image: CGImage,
        allowed: Set<Suit>?,
        cosineAccept: Float,
        marginMin: Float
    ) -> Suit? {
        guard cachedFill != nil || buildTemplateCaches(),
              let fillT = cachedFill,
              let edgeT = cachedEdge else { return nil }

        let courtRect = CardCourtSampling.centerCourtIntegralRect(for: image)
        guard let court = image.cropping(to: courtRect),
              let resized = court.resizedToSquare(side: grid),
              let fillRaw = rasterInkRaw(resized),
              let fillNorm = l2Normalize(fillRaw),
              let edgeNorm = normalizedSobelMagnitude(fillRaw, side: grid) else { return nil }

        let suitsScore: [Suit]
        if let allowed {
            suitsScore = allowed.sorted { $0.rawValue < $1.rawValue }
        } else {
            suitsScore = Suit.allCases.sorted { $0.rawValue < $1.rawValue }
        }
        guard suitsScore.isEmpty == false else { return nil }

        var bestSuit: Suit?
        var bestScore = Float(-999)
        var second = Float(-999)

        func scorePair(for suit: Suit) -> Float? {
            guard let fT = fillT[suit],
                  let eT = edgeT[suit],
                  fT.count == fillNorm.count,
                  eT.count == edgeNorm.count else { return nil }
            let cF = dot(fillNorm, fT)
            let cE = dot(edgeNorm, eT)
            return wFill * cF + wEdge * cE
        }

        for suit in suitsScore {
            guard let score = scorePair(for: suit) else { continue }
            if score > bestScore {
                second = bestScore
                bestScore = score
                bestSuit = suit
            } else if score > second {
                second = score
            }
        }

        guard let pick = bestSuit else { return nil }
        guard bestScore >= cosineAccept else { return nil }
        if second >= 0, bestScore - second < marginMin {
            /// Spade ♠ vs ♣ stalk / trefoil are often nearly tied — use bottom-center ink distribution.
            if allowed == Set([.spades, .clubs]) {
                return inferSpadeVsClubStemHeuristic(fillRaw: fillRaw, side: grid)
            }
            return nil
        }

        return pick
    }

    /// When scores tie, ♠ concentrates more ink directly under the centroid in the bottom wedge.
    private static func inferSpadeVsClubStemHeuristic(fillRaw: [Float], side: Int) -> Suit? {
        guard side > 17, fillRaw.count == side * side else { return nil }
        let cx = Float(side / 2)
        var bottomCone: Float = 0
        var bottomWings: Float = 0
        let ySplit = Int(Float(side) * 0.62)
        for y in ySplit ..< side {
            for x in 0 ..< side {
                let v = fillRaw[y * side + x]
                let fx = Float(x)
                let dist = abs(fx - cx)
                let narrow = Float(side) * 0.20
                if dist < narrow { bottomCone += v }
                else { bottomWings += v }
            }
        }
        let ratio = bottomCone / max(bottomCone + bottomWings, 1e-6)
        return ratio >= 0.42 ? .spades : .clubs
    }

    private static func buildTemplateCaches() -> Bool {
        var fOut: [Suit: [Float]] = [:]
        var eOut: [Suit: [Float]] = [:]
        for suit in Suit.allCases {
            guard let name = suitSymbolNames[suit],
                  let cg = rasterSystemSuit(systemName: name, side: grid),
                  let raw = rasterInkRaw(cg),
                  let normF = l2Normalize(raw),
                  let normE = normalizedSobelMagnitude(raw, side: grid) else {
                cachedFill = nil
                cachedEdge = nil
                return false
            }
            fOut[suit] = normF
            eOut[suit] = normE
        }
        cachedFill = fOut
        cachedEdge = eOut
        return true
    }

    // MARK: - Raster

    private static func rasterSystemSuit(systemName: String, side: Int) -> CGImage? {
        #if canImport(UIKit)
        return rasterSuitUIImage(systemName: systemName, side: side)
        #elseif canImport(AppKit)
        return rasterSuitNSImage(systemName: systemName, side: side)
        #else
        return nil
        #endif
    }

#if canImport(UIKit)
    private static func rasterSuitUIImage(systemName: String, side: Int) -> CGImage? {
        let px = CGSize(width: side, height: side)
        let cfg = UIImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.62, weight: .medium)
        guard let raw = UIImage(systemName: systemName, withConfiguration: cfg) else { return nil }
        let tinted = raw.withTintColor(.white, renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let r = UIGraphicsImageRenderer(size: px, format: format)
        let img = r.image { _ in
            UIColor.black.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: px)).fill()
            let inset = CGFloat(side) * 0.06
            tinted.draw(in: CGRect(x: inset, y: inset, width: px.width - 2 * inset, height: px.height - 2 * inset))
        }
        return img.cgImage
    }
#endif

#if canImport(AppKit)
    private static func rasterSuitNSImage(systemName: String, side: Int) -> CGImage? {
        let px = CGSize(width: side, height: side)
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.62, weight: .medium)
        guard let img = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4,
            bitsPerPixel: 32
        )
        guard let rep else { return nil }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = ctx
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: px)).fill()
        let inset = CGFloat(side) * 0.06
        img.draw(in: NSRect(x: inset, y: inset, width: px.width - 2 * inset, height: px.height - 2 * inset))
        return rep.cgImage
    }
#endif

    /// Raw ink prominence 0…1 (not L2-normalized).
    private static func rasterInkRaw(_ image: CGImage) -> [Float]? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
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
        else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [Float](repeating: 0, count: w * h)
        var i = 0
        for y in 0 ..< h {
            let row = y * rowBytes
            for x in 0 ..< w {
                let o = row + x * bpp
                let r = Float(data[o])
                let g = Float(data[o &+ 1])
                let b = Float(data[o &+ 2])
                let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
                out[i] = max(0, min(1, 1 - lum))
                i += 1
            }
        }
        return out
    }

    private static func l2Normalize(_ v: [Float]) -> [Float]? {
        var s: Float = 0
        for x in v { s += x * x }
        let n = sqrt(max(s, 1e-8))
        return v.map { $0 / n }
    }

    private static func normalizedSobelMagnitude(_ ink: [Float], side: Int) -> [Float]? {
        guard ink.count == side * side, side >= 5 else { return nil }
        var mag = [Float](repeating: 0, count: ink.count)
        for y in 1 ..< side - 1 {
            for x in 1 ..< side - 1 {
                let i = y * side + x
                let gx = ink[i + 1] - ink[i - 1]
                let gy = ink[i + side] - ink[i - side]
                mag[i] = sqrt(gx * gx + gy * gy + 1e-8)
            }
        }
        return l2Normalize(mag)
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in a.indices where i < b.count { s += a[i] * b[i] }
        return s
    }
}

private extension CGImage {
    func resizedToSquare(side: Int) -> CGImage? {
        guard side > 1 else { return nil }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}
