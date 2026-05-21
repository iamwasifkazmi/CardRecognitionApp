import CoreGraphics

/// Reads the **large center pip** on slot/LCD cards (where corner `suitROI` is often empty).
enum CenterPipSuitInferencer: Sendable {
    private static let grid = 72

    static func infer(for image: CGImage) -> Suit? {
        let rect = centerPipRect(for: image)
        guard let crop = image.cropping(to: rect),
              let resized = crop.resizedToSquare(side: grid),
              let raster = rasterInk(resized) else { return nil }
        let fill = raster.fill

        let inkMass = fill.reduce(0, +)
        guard inkMass > 4.5 else { return nil }

        var redCount = 0
        var darkCount = 0
        for y in 0 ..< grid {
            for x in 0 ..< grid {
                guard fill[y * grid + x] > 0.055 else { continue }
                let i = (y * grid + x) * 4
                if isRedInk(raster, i) { redCount += 1 }
                else if isDarkInk(raster, i) { darkCount += 1 }
            }
        }

        let n = max(redCount + darkCount, 1)
        if Float(redCount) / Float(n) >= 0.22 {
            let redOnly = redMask(raster: raster, side: grid)
            return inferRedSuit(redMask: redOnly, side: grid, redPixelCount: redCount)
        }
        if Float(darkCount) / Float(n) >= 0.35 {
            return inferBlackSuit(fill: fill)
        }
        return nil
    }

    private static func redMask(raster: RasterPack, side: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: side * side)
        for y in 0 ..< side {
            for x in 0 ..< side {
                let i = (y * side + x) * 4
                if isRedInk(raster, i) {
                    mask[y * side + x] = true
                }
            }
        }
        return mask
    }

    fileprivate struct RasterPack {
        var fill: [Float]
        var rgba: [UInt8]
    }

    private static func centerPipRect(for image: CGImage) -> CGRect {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        return CGRect(x: w * 0.14, y: h * 0.22, width: w * 0.72, height: h * 0.58).integral
    }

    private static func inferRedSuit(redMask: [Bool], side: Int, redPixelCount: Int) -> Suit? {
        guard redPixelCount >= 18 else { return nil }
        var minX = side, maxX = 0, minY = side, maxY = 0
        for y in 0 ..< side {
            for x in 0 ..< side where redMask[y * side + x] {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let bw = Float(maxX - minX + 1)
        let bh = Float(maxY - minY + 1)
        /// VP ♥ pips are often squarish — prefer hearts unless clearly tall (♦).
        if bh / bw > 1.22 { return .diamonds }
        if bw / bh > 1.08 { return .hearts }
        return .hearts
    }

    private static func inferBlackSuit(fill: [Float]) -> Suit? {
        let stem = spadeStemRatio(fill: fill, side: grid) ?? 0
        let upperHeavy = upperMassShare(fill: fill, side: grid)
        let topLobe = topLobeSeparation(fill: fill, side: grid, threshold: 0.07)
        if topLobe >= 0.12, upperHeavy >= 0.38, stem < 0.42 { return .clubs }
        if stem >= 0.44, upperHeavy < 0.42 { return .spades }
        if upperHeavy >= 0.44, stem < 0.36 { return .clubs }
        return nil
    }

    private static func topLobeSeparation(fill: [Float], side: Int, threshold: Float) -> Float {
        var mask = [Bool](repeating: false, count: side * side)
        for i in 0 ..< side * side where fill[i] >= threshold {
            mask[i] = true
        }
        var left = 0
        var right = 0
        let yEnd = side / 4
        for y in 0 ..< yEnd {
            for x in 0 ..< side where mask[y * side + x] {
                if x < side / 2 { left += 1 } else { right += 1 }
            }
        }
        let t = Float(left + right)
        guard t > 4 else { return 0 }
        return abs(Float(left) - Float(right)) / t
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
        let ySplit = Int(Float(side) * 0.62)
        for y in ySplit ..< side {
            for x in 0 ..< side {
                let v = fill[y * side + x]
                let dist = abs(Float(x) - cx)
                if dist < Float(side) * 0.20 { bottomCone += v }
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
                guard v > 0.055 else { continue }
                total += v
                if y < mid { upper += v }
            }
        }
        return upper / max(total, 1e-6)
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
                if isRedInk(pack, i) || isDarkInk(pack, i) {
                    pack.fill[y * side + x] = 1
                }
            }
        }
        return pack
    }
}

private func isRedInk(_ raster: CenterPipSuitInferencer.RasterPack, _ i: Int) -> Bool {
    isRedInk(Float(raster.rgba[i]), Float(raster.rgba[i + 1]), Float(raster.rgba[i + 2]))
}

private func isDarkInk(_ raster: CenterPipSuitInferencer.RasterPack, _ i: Int) -> Bool {
    isDarkInk(Float(raster.rgba[i]), Float(raster.rgba[i + 1]), Float(raster.rgba[i + 2]))
}

private func isRedInk(_ r: Float, _ g: Float, _ b: Float) -> Bool {
    let mg = max(g, b)
    let chroma = r - mg
    return r >= 136 && chroma >= 36 && r > mg * 1.18
}

private func isDarkInk(_ r: Float, _ g: Float, _ b: Float) -> Bool {
    let lum = 0.299 * r + 0.587 * g + 0.114 * b
    let mx = max(r, max(g, b))
    return lum < 158 && mx < 154
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
