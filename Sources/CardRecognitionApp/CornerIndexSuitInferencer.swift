import CoreGraphics

/// Infers suit from the **top-left index glyph** (rank stack), not the large center pip.
enum CornerIndexSuitInferencer: Sendable {
    private static let grid = 48

    static func infer(for image: CGImage, narrowColumn: Bool) -> Suit? {
        let rect = indexStackRect(for: image, narrowColumn: narrowColumn)
        guard let crop = image.cropping(to: rect),
              let scaled = crop.resizedToSquare(side: grid),
              let raster = rasterInk(scaled) else { return nil }

        let fill = raster.fill
        let inkMass = fill.reduce(0, +)
        guard inkMass > 2.8 else { return nil }

        var redCount = 0
        var darkCount = 0
        for y in 0 ..< grid {
            for x in 0 ..< grid {
                guard fill[y * grid + x] > 0.06 else { continue }
                let i = (y * grid + x) * 4
                if isRedInk(raster.rgba, i) { redCount += 1 }
                else if isDarkInk(raster.rgba, i) { darkCount += 1 }
            }
        }

        let chroma = max(redCount + darkCount, 1)
        if Float(redCount) / Float(chroma) >= 0.20 {
            return inferRedSuit(fill: fill, raster: raster, side: grid, redCount: redCount)
        }
        if Float(darkCount) / Float(chroma) >= 0.32 {
            return inferBlackSuit(fill: fill, side: grid)
        }
        return nil
    }

    private static func indexStackRect(for image: CGImage, narrowColumn: Bool) -> CGRect {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        if narrowColumn {
            return CGRect(x: w * 0.02, y: h * 0.02, width: w * 0.46, height: h * 0.36).integral
        }
        return CGRect(x: w * 0.03, y: h * 0.03, width: w * 0.40, height: h * 0.34).integral
    }

    private static func inferRedSuit(
        fill: [Float],
        raster: RasterPack,
        side: Int,
        redCount: Int
    ) -> Suit? {
        guard redCount >= 10 else { return nil }
        var mask = [Bool](repeating: false, count: side * side)
        for y in 0 ..< side {
            for x in 0 ..< side {
                let i = (y * side + x) * 4
                if fill[y * side + x] > 0.06, isRedInk(raster.rgba, i) {
                    mask[y * side + x] = true
                }
            }
        }
        var minX = side, maxX = 0, minY = side, maxY = 0
        for y in 0 ..< side {
            for x in 0 ..< side where mask[y * side + x] {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let bw = Float(maxX - minX + 1)
        let bh = Float(maxY - minY + 1)
        let topLobe = topLobeSeparation(mask: mask, side: side, splitY: minY + (maxY - minY) / 3)
        if topLobe >= 0.14, bw / bh > 1.06 { return .hearts }
        if bh / bw > 1.12 { return .diamonds }
        if bw / bh > 1.20 { return .hearts }
        return .hearts
    }

    private static func inferBlackSuit(fill: [Float], side: Int) -> Suit? {
        let stem = spadeStemRatio(fill: fill, side: side) ?? 0
        let upperHeavy = upperMassShare(fill: fill, side: side)
        let topLobe = topLobeSeparation(fill: fill, side: side, threshold: 0.08)

        if topLobe >= 0.12, upperHeavy >= 0.38 { return .clubs }
        if upperHeavy >= 0.44, stem < 0.38 { return .clubs }
        if stem >= 0.52, upperHeavy < 0.38 { return .spades }
        return .clubs
    }

    private static func topLobeSeparation(mask: [Bool], side: Int, splitY: Int) -> Float {
        var left = 0
        var right = 0
        let yEnd = min(splitY + side / 6, side)
        for y in 0 ..< yEnd {
            for x in 0 ..< side where mask[y * side + x] {
                if x < side / 2 { left += 1 } else { right += 1 }
            }
        }
        let t = Float(left + right)
        guard t > 4 else { return 0 }
        return abs(Float(left) - Float(right)) / t
    }

    private static func topLobeSeparation(fill: [Float], side: Int, threshold: Float) -> Float {
        var mask = [Bool](repeating: false, count: side * side)
        for i in 0 ..< side * side where fill[i] >= threshold {
            mask[i] = true
        }
        return topLobeSeparation(mask: mask, side: side, splitY: side / 5)
    }

    private static func blobCount(fill: [Float], side: Int, threshold: Float) -> Int {
        var visited = [Bool](repeating: false, count: side * side)
        var count = 0
        for y in 0 ..< side {
            for x in 0 ..< side {
                let idx = y * side + x
                guard visited[idx] == false, fill[idx] >= threshold else { continue }
                count += 1
                flood(fill: fill, side: side, threshold: threshold, x: x, y: y, visited: &visited)
            }
        }
        return count
    }

    private static func flood(
        fill: [Float],
        side: Int,
        threshold: Float,
        x: Int,
        y: Int,
        visited: inout [Bool]
    ) {
        var stack: [(Int, Int)] = [(x, y)]
        while let (cx, cy) = stack.popLast() {
            let idx = cy * side + cx
            guard cx >= 0, cy >= 0, cx < side, cy < side,
                  visited[idx] == false, fill[idx] >= threshold else { continue }
            visited[idx] = true
            stack.append((cx + 1, cy))
            stack.append((cx - 1, cy))
            stack.append((cx, cy + 1))
            stack.append((cx, cy - 1))
        }
    }

    private static func spadeStemRatio(fill: [Float], side: Int) -> Float? {
        let cx = Float(side / 2)
        var bottomCone: Float = 0
        var bottomWings: Float = 0
        let ySplit = Int(Float(side) * 0.58)
        for y in ySplit ..< side {
            for x in 0 ..< side {
                let v = fill[y * side + x]
                guard v > 0.06 else { continue }
                let dist = abs(Float(x) - cx)
                if dist < Float(side) * 0.22 { bottomCone += v }
                else { bottomWings += v }
            }
        }
        let t = bottomCone + bottomWings
        guard t > 1e-4 else { return nil }
        return bottomCone / t
    }

    private static func upperMassShare(fill: [Float], side: Int) -> Float {
        let mid = side * 11 / 20
        var upper: Float = 0
        var total: Float = 0
        for y in 0 ..< side {
            for x in 0 ..< side {
                let v = fill[y * side + x]
                guard v > 0.06 else { continue }
                total += v
                if y < mid { upper += v }
            }
        }
        return upper / max(total, 1e-6)
    }

    fileprivate struct RasterPack {
        var fill: [Float]
        var rgba: [UInt8]
    }

    private static func rasterInk(_ image: CGImage) -> RasterPack? {
        let side = grid
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &rgba,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var pack = RasterPack(fill: [Float](repeating: 0, count: side * side), rgba: rgba)
        for y in 0 ..< side {
            for x in 0 ..< side {
                let i = (y * side + x) * 4
                let lum = 0.299 * Float(rgba[i]) + 0.587 * Float(rgba[i + 1]) + 0.114 * Float(rgba[i + 2])
                if lum > 248 { continue }
                if isRedInk(rgba, i) || isDarkInk(rgba, i) {
                    pack.fill[y * side + x] = 1
                }
            }
        }
        return pack
    }
}

private func isRedInk(_ rgba: [UInt8], _ i: Int) -> Bool {
    let r = Float(rgba[i])
    let g = Float(rgba[i + 1])
    let b = Float(rgba[i + 2])
    let mg = max(g, b)
    let chroma = r - mg
    return r >= 132 && chroma >= 32 && r > mg * 1.16
}

private func isDarkInk(_ rgba: [UInt8], _ i: Int) -> Bool {
    let r = Float(rgba[i])
    let g = Float(rgba[i + 1])
    let b = Float(rgba[i + 2])
    let lum = 0.299 * r + 0.587 * g + 0.114 * b
    let mx = max(r, max(g, b))
    return lum < 162 && mx < 158
}

private extension CGImage {
    func resizedToSquare(side: Int) -> CGImage? {
        guard side > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}
