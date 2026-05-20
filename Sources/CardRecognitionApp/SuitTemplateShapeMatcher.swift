import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Correlates the warped **court** ROI with SF Symbol suits using **edge + fill**.
enum SuitTemplateShapeMatcher: Sendable {
    private static let grid = 72
    private static let wEdge: Float = 0.58
    private static let wFill: Float = 0.42

    private static let suitSymbolNames: [Suit: String] = [
        .spades: "suit.spade.fill",
        .hearts: "suit.heart.fill",
        .diamonds: "suit.diamond.fill",
        .clubs: "suit.club.fill",
    ]

    nonisolated(unsafe) private static var cachedFill: [Suit: [Float]]?
    nonisolated(unsafe) private static var cachedEdge: [Suit: [Float]]?

    /// Monochrome cards: ♠ ♣ with strict → relaxed thresholds, then **relative** pick (avoids perpetual `Unknown` when art ≠ SF Symbol geometry).
    static func inferBlackSuitsOnly(for image: CGImage) -> Suit? {
        let tiers: [(Float, Float)] = [
            (0.38, 0.045),
            (0.28, 0.025),
            (0.20, 0.012),
            (0.14, 0.006),
        ]
        for (cos, margin) in tiers {
            if let s = inferMatching(
                for: image,
                allowed: Set([.spades, .clubs]),
                cosineAccept: cos,
                marginMin: margin
            ) {
                return s
            }
        }
        return inferBlackRelativePick(for: image)
    }

    static func inferRedSuitsOnly(for image: CGImage) -> Suit? {
        let tiers: [(Float, Float)] = [
            (0.36, 0.052),
            (0.26, 0.030),
            (0.18, 0.014),
            (0.12, 0.007),
        ]
        for (cos, margin) in tiers {
            if let s = inferMatching(
                for: image,
                allowed: Set([.hearts, .diamonds]),
                cosineAccept: cos,
                marginMin: margin
            ) {
                return s
            }
        }
        return inferRedRelativePick(for: image)
    }

    static func infer(for image: CGImage) -> Suit? {
        inferMatching(for: image, allowed: nil, cosineAccept: 0.32, marginMin: 0.04)
    }

    /// Strict tiers only — no relative pick when scores tie (avoids random ♥/♦ on 0.340 vs 0.340).
    static func inferRedSuitsStrict(for image: CGImage) -> Suit? {
        let tiers: [(Float, Float)] = [
            (0.34, 0.048),
            (0.26, 0.034),
            (0.20, 0.024),
        ]
        for (cos, margin) in tiers {
            if let s = inferMatching(
                for: image,
                allowed: Set([.hearts, .diamonds]),
                cosineAccept: cos,
                marginMin: margin
            ) {
                return s
            }
        }
        return nil
    }

    static func inferBlackSuitsStrict(for image: CGImage) -> Suit? {
        let tiers: [(Float, Float)] = [
            (0.36, 0.050),
            (0.28, 0.036),
            (0.22, 0.026),
        ]
        for (cos, margin) in tiers {
            if let s = inferMatching(
                for: image,
                allowed: Set([.spades, .clubs]),
                cosineAccept: cos,
                marginMin: margin
            ) {
                return s
            }
        }
        return nil
    }

    /// The bitmap **is** the small index suit glyph (not center-court sampling).
    static func inferFromIconCrop(_ crop: CGImage, allowed: Set<Suit>?) -> Suit? {
        inferMatchingOnFullFrame(
            crop,
            allowed: allowed,
            cosineAccept: 0.20,
            marginMin: 0.028,
            logLabel: "index_glyph_icon"
        )
    }

    // MARK: - Core matching

    private struct CourtFeatures {
        let fillRaw: [Float]
        let fillNorm: [Float]
        let edgeNorm: [Float]
    }

    private static func courtFeatures(for image: CGImage, framing: CardCourtSampling.CourtFraming) -> CourtFeatures? {
        let courtRect = CardCourtSampling.centerCourtIntegralRect(for: image, framing: framing)
        guard let court = image.cropping(to: courtRect),
              let resized = court.resizedToSquare(side: grid),
              let fillRaw = rasterInkRaw(resized),
              let fillNorm = l2Normalize(fillRaw),
              let edgeNorm = normalizedSobelMagnitude(fillRaw, side: grid) else { return nil }
        return CourtFeatures(fillRaw: fillRaw, fillNorm: fillNorm, edgeNorm: edgeNorm)
    }

    private static func fillRawStandardCourt(for image: CGImage) -> [Float]? {
        let rect = CardCourtSampling.centerCourtIntegralRect(for: image, framing: .standard)
        guard let court = image.cropping(to: rect),
              let resized = court.resizedToSquare(side: grid),
              let fillRaw = rasterInkRaw(resized) else { return nil }
        return fillRaw
    }

    private static func maxSuitCombo(
        for image: CGImage,
        suit: Suit,
        fillT: [Suit: [Float]],
        edgeT: [Suit: [Float]]
    ) -> Float {
        var best: Float = -1
        for framing in CardCourtSampling.CourtFraming.allCases {
            guard let feat = courtFeatures(for: image, framing: framing),
                  let fT = fillT[suit],
                  let eT = edgeT[suit],
                  fT.count == feat.fillNorm.count,
                  eT.count == feat.edgeNorm.count else { continue }
            let s = wFill * dot(feat.fillNorm, fT) + wEdge * dot(feat.edgeNorm, eT)
            best = max(best, s)
        }
        return best
    }

    /// Bottom-center “stem + point” mass vs side lobes — high values match ♠ more than trefoil ♣.
    private static func spadeStemConeRatio(fillRaw: [Float], side: Int) -> Float? {
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
        let t = bottomCone + bottomWings
        guard t > 1e-4 else { return nil }
        return bottomCone / t
    }

    /// Share of ink in the **center third** of the **top ~48%** of the court — high for a single ♠ bulb, lower for ♣ trefoil / multi-pip art.
    private static func upperCenterMassShareTopHalf(_ fillRaw: [Float], side: Int) -> Float {
        guard fillRaw.count == side * side, side > 12 else { return 0 }
        let yTop = Int(Float(side) * 0.48)
        let xC1 = side / 3
        let xC2 = side * 2 / 3
        var center: Float = 0
        var total: Float = 0
        for y in 0 ..< yTop {
            for x in 0 ..< side {
                let v = fillRaw[y * side + x]
                total += v
                if x >= xC1 && x < xC2 { center += v }
            }
        }
        return center / max(total, 1e-6)
    }

    private static func maxEdgeSuitDot(for image: CGImage, suit: Suit, edgeT: [Suit: [Float]]) -> Float {
        var best: Float = -1
        for framing in CardCourtSampling.CourtFraming.allCases {
            guard let feat = courtFeatures(for: image, framing: framing),
                  let eT = edgeT[suit],
                  eT.count == feat.edgeNorm.count else { continue }
            best = max(best, dot(feat.edgeNorm, eT))
        }
        return best
    }

    /// When absolute cosine never clears the bar (custom slot art vs Apple glyphs), still choose ♠ vs ♣ from **relative** edge+fill score if the court has ink.
    private static func inferBlackRelativePick(for image: CGImage) -> Suit? {
        guard cachedFill != nil || buildTemplateCaches(),
              let fillT = cachedFill,
              let edgeT = cachedEdge,
              let fillRawStd = fillRawStandardCourt(for: image) else { return nil }

        let inkMass = fillRawStd.reduce(0, +)
        guard inkMass > 3.8 else { return nil }

        let sSpade = maxSuitCombo(for: image, suit: .spades, fillT: fillT, edgeT: edgeT)
        let sClub = maxSuitCombo(for: image, suit: .clubs, fillT: fillT, edgeT: edgeT)
        guard sSpade >= 0, sClub >= 0 else { return nil }

        if let refined = refineSpadeVersusClub(
            sSpade: sSpade,
            sClub: sClub,
            fillRaw: fillRawStd,
            side: grid
        ) {
            return refined
        }

        if abs(sSpade - sClub) < 0.018 {
            let h = inferSpadeVsClubStemHeuristic(fillRaw: fillRawStd, side: grid)
            SlotRecognitionDiagnostics.log(
                "  suit template: relative ♠/♣ (tied scores) → stem heuristic → \(h.map(\.rawValue) ?? "?")"
            )
            return h
        }
        var pick: Suit = sSpade >= sClub ? .spades : .clubs
        if pick == .spades, sSpade - sClub < 0.038,
           upperMassSuggestsClub(fillRawStd, side: grid),
           (spadeStemConeRatio(fillRaw: fillRawStd, side: grid) ?? 0) < 0.43 {
            pick = .clubs
            SlotRecognitionDiagnostics.log("  suit template: ♠ margin narrow + upper trefoil mass → clubs")
        }
        if pick == .clubs, sClub - sSpade < 0.056,
           let stemR = spadeStemConeRatio(fillRaw: fillRawStd, side: grid) {
            let weakT = max(sSpade, sClub) < 0.22
            let centerShare = upperCenterMassShareTopHalf(fillRawStd, side: grid)
            let stemCut: Float = weakT ? 0.402 : 0.454
            if stemR >= stemCut, (weakT == false || centerShare >= 0.375) {
                pick = .spades
                SlotRecognitionDiagnostics.log("  suit template: ♣ lead narrow + bottom stem → spades")
            }
        }
        SlotRecognitionDiagnostics.log(
            "  suit template: relative ♠/♣ pick (scores ♠=\(String(format: "%.3f", sSpade)) ♣=\(String(format: "%.3f", sClub))) → \(pick.rawValue)"
        )
        return pick
    }

    private static func inferRedRelativePick(for image: CGImage) -> Suit? {
        guard cachedFill != nil || buildTemplateCaches(),
              let fillT = cachedFill,
              let edgeT = cachedEdge,
              let fillRawStd = fillRawStandardCourt(for: image) else { return nil }
        guard fillRawStd.reduce(0, +) > 3.2 else { return nil }

        let h = maxSuitCombo(for: image, suit: .hearts, fillT: fillT, edgeT: edgeT)
        let d = maxSuitCombo(for: image, suit: .diamonds, fillT: fillT, edgeT: edgeT)
        guard h >= 0, d >= 0 else { return nil }
        var pick: Suit = h >= d ? .hearts : .diamonds
        if abs(h - d) < 0.017 {
            let he = maxEdgeSuitDot(for: image, suit: .hearts, edgeT: edgeT)
            let de = maxEdgeSuitDot(for: image, suit: .diamonds, edgeT: edgeT)
            if abs(he - de) >= 0.006 {
                pick = he >= de ? .hearts : .diamonds
                SlotRecognitionDiagnostics.log(
                    "  suit template: ♥/♦ edge tie-break (♥e=\(String(format: "%.3f", he)) ♦e=\(String(format: "%.3f", de))) → \(pick.rawValue)"
                )
            } else if let spread = inferHeartVsDiamondByPipSpread(fillRawStd, side: grid) {
                pick = spread
                SlotRecognitionDiagnostics.log("  suit template: ♥/♦ pip-layout tie-break → \(pick.rawValue)")
            } else {
                SlotRecognitionDiagnostics.log(
                    "  suit template: relative ♥/♦ pick (scores ♥=\(String(format: "%.3f", h)) ♦=\(String(format: "%.3f", d))) → \(pick.rawValue)"
                )
            }
        } else {
            SlotRecognitionDiagnostics.log(
                "  suit template: relative ♥/♦ pick (scores ♥=\(String(format: "%.3f", h)) ♦=\(String(format: "%.3f", d))) → \(pick.rawValue)"
            )
        }
        return pick
    }

    /// Narrow ♠ wins with trefoil-like upper mass → **♣** (fixes minimal 7♣ slot art misread as ♠).
    private static func refineSpadeVersusClub(
        sSpade: Float,
        sClub: Float,
        fillRaw: [Float],
        side: Int
    ) -> Suit? {
        guard sSpade > sClub, sSpade - sClub < 0.032 else { return nil }
        if let stem = spadeStemConeRatio(fillRaw: fillRaw, side: side), stem >= 0.435 { return nil }
        guard upperMassSuggestsClub(fillRaw, side: side) else { return nil }
        SlotRecognitionDiagnostics.log(
            "  suit template: refine narrow ♠ lead + upper lobes → clubs (♠=\(String(format: "%.3f", sSpade)) ♣=\(String(format: "%.3f", sClub)))"
        )
        return .clubs
    }

    private static func upperMassSuggestsClub(_ fillRaw: [Float], side: Int) -> Bool {
        guard fillRaw.count == side * side, side > 20 else { return false }
        if let stem = spadeStemConeRatio(fillRaw: fillRaw, side: side), stem >= 0.418 { return false }
        let mid = side * 11 / 20
        var upper: Float = 0
        var lower: Float = 0
        for y in 0 ..< mid {
            for x in 0 ..< side {
                upper += fillRaw[y * side + x]
            }
        }
        for y in mid ..< side {
            for x in 0 ..< side {
                lower += fillRaw[y * side + x]
            }
        }
        return upper > lower * 1.065
    }

    /// When ♥/♦ combined scores tie, pip fields differ: ♦ layouts are often taller, ♥ slightly wider at 7-count.
    private static func inferHeartVsDiamondByPipSpread(_ fillRaw: [Float], side: Int, axisRatio: Float = 1.085) -> Suit? {
        guard fillRaw.count == side * side, side > 12 else { return nil }
        let threshold: Float = 0.055
        var minX = side, maxX = 0, minY = side, maxY = 0
        var any = false
        for y in 0 ..< side {
            for x in 0 ..< side {
                if fillRaw[y * side + x] < threshold { continue }
                any = true
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard any else { return nil }
        let w = Float(maxX - minX + 1)
        let h = Float(maxY - minY + 1)
        guard w > 2, h > 2 else { return nil }
        if h > w * axisRatio { return .diamonds }
        if w > h * axisRatio { return .hearts }
        return nil
    }

    private static func inferMatchingOnFullFrame(
        _ image: CGImage,
        allowed: Set<Suit>?,
        cosineAccept: Float,
        marginMin: Float,
        logLabel: String
    ) -> Suit? {
        guard cachedFill != nil || buildTemplateCaches(),
              let fillT = cachedFill,
              let edgeT = cachedEdge,
              let resized = image.resizedToSquare(side: grid),
              let fillRaw = rasterInkRaw(resized),
              fillRaw.reduce(0, +) > 2.0,
              let fillNorm = l2Normalize(fillRaw),
              let edgeNorm = normalizedSobelMagnitude(fillRaw, side: grid) else { return nil }

        let suitsScore: [Suit]
        if let allowed, allowed.isEmpty == false {
            suitsScore = allowed.sorted { $0.rawValue < $1.rawValue }
        } else {
            suitsScore = Suit.allCases.sorted { $0.rawValue < $1.rawValue }
        }

        var bestSuit: Suit?
        var bestScore = Float(-999)
        var second = Float(-999)

        for suit in suitsScore {
            guard let fT = fillT[suit], let eT = edgeT[suit],
                  fT.count == fillNorm.count, eT.count == edgeNorm.count else { continue }
            let score = wFill * dot(fillNorm, fT) + wEdge * dot(edgeNorm, eT)
            if score > bestScore {
                second = bestScore
                bestScore = score
                bestSuit = suit
            } else if score > second {
                second = score
            }
        }

        guard let pick = bestSuit, bestScore >= cosineAccept else { return nil }
        guard second < 0 || bestScore - second >= marginMin else {
            SlotRecognitionDiagnostics.log(
                "  \(logLabel): ambiguous (best=\(String(format: "%.3f", bestScore)) runner-up=\(String(format: "%.3f", second))) → none"
            )
            return nil
        }
        SlotRecognitionDiagnostics.log(
            "  \(logLabel): matched \(pick.rawValue) score=\(String(format: "%.3f", bestScore)) margin=\(String(format: "%.3f", bestScore - max(second, 0)))"
        )
        return pick
    }

    private static func inferMatching(
        for image: CGImage,
        allowed: Set<Suit>?,
        cosineAccept: Float,
        marginMin: Float
    ) -> Suit? {
        guard cachedFill != nil || buildTemplateCaches(),
              let fillT = cachedFill,
              let edgeT = cachedEdge,
              let fillRawStd = fillRawStandardCourt(for: image) else { return nil }

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

        for suit in suitsScore {
            let score = maxSuitCombo(for: image, suit: suit, fillT: fillT, edgeT: edgeT)
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
            if allowed == Set([.spades, .clubs]) {
                if let refined = refineSpadeVersusClub(
                    sSpade: maxSuitCombo(for: image, suit: .spades, fillT: fillT, edgeT: edgeT),
                    sClub: maxSuitCombo(for: image, suit: .clubs, fillT: fillT, edgeT: edgeT),
                    fillRaw: fillRawStd,
                    side: grid
                ) {
                    return refined
                }
                return inferSpadeVsClubStemHeuristic(fillRaw: fillRawStd, side: grid)
            }
            return nil
        }

        /// Only second-guess a ♠ win when the **runner-up** was also close (avoid flipping a decisive ♠).
        if allowed == Set([.spades, .clubs]), pick == .spades,
           second >= 0, bestScore - second < 0.042,
           let refined = refineSpadeVersusClub(
               sSpade: maxSuitCombo(for: image, suit: .spades, fillT: fillT, edgeT: edgeT),
               sClub: maxSuitCombo(for: image, suit: .clubs, fillT: fillT, edgeT: edgeT),
               fillRaw: fillRawStd,
               side: grid
           ) {
            return refined
        }

        if allowed == Set([.spades, .clubs]), pick == .clubs,
           let stemR = spadeStemConeRatio(fillRaw: fillRawStd, side: grid) {
            let sSpade = maxSuitCombo(for: image, suit: .spades, fillT: fillT, edgeT: edgeT)
            let sClub = maxSuitCombo(for: image, suit: .clubs, fillT: fillT, edgeT: edgeT)
            /// Trust a clear ♣ lead — stem heuristic often flips multi-pip ♠ art (e.g. 4♠) to ♣.
            if sClub >= sSpade + 0.012 { return pick }
            guard sClub >= sSpade, sClub - sSpade < 0.028 else { return pick }
            let weakT = max(sSpade, sClub) < 0.22
            let centerShare = upperCenterMassShareTopHalf(fillRawStd, side: grid)
            let stemCut: Float = weakT ? 0.468 : 0.512
            guard stemR >= stemCut else { return pick }
            if weakT, centerShare < 0.375 { return pick }
            SlotRecognitionDiagnostics.log(
                "  suit template: ♣ winner but stem point + narrow margin → spades (♠=\(String(format: "%.3f", sSpade)) ♣=\(String(format: "%.3f", sClub)))"
            )
            return .spades
        }

        return pick
    }

    private static func inferSpadeVsClubStemHeuristic(fillRaw: [Float], side: Int) -> Suit? {
        guard side > 17, fillRaw.count == side * side else { return nil }
        let mid = side * 11 / 20
        var upper: Float = 0
        var lower: Float = 0
        for y in 0 ..< mid {
            for x in 0 ..< side {
                upper += fillRaw[y * side + x]
            }
        }
        for y in mid ..< side {
            for x in 0 ..< side {
                lower += fillRaw[y * side + x]
            }
        }
        let stemHint = spadeStemConeRatio(fillRaw: fillRaw, side: side)
        if upper > lower * 1.12, (stemHint ?? 0) < 0.408 {
            return .clubs
        }
        if lower > upper * 1.12 {
            return .spades
        }

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
        return ratio >= 0.46 ? .spades : .clubs
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
