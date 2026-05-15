import CoreGraphics

/// When `VNDetectRectangles` finds nothing, locates a **bright horizontal band** (white cards on near-black UI / wallpaper)
/// so synthetic five-column crops land on the row instead of a fixed rectangle that often slices menu bars and window chrome.
enum BrightCardRowLocator: Sendable {
    /// Vision-style normalized rect: origin **bottom-left**, y increasing **upward**, width/height in 0…1.
    static func visionNormalizedBrightRowStrip(cgImage: CGImage) -> CGRect? {
        let w = cgImage.width
        let h = cgImage.height
        guard w >= 48, h >= 48 else { return nil }

        guard let rowMeans = rowMeanLuminance(cgImage: cgImage, width: w, height: h) else { return nil }
        let smoothed = boxBlur1D(rowMeans, radius: max(1, h / 120))

        guard let m = minMax(smoothed), m.max - m.min > 12 else { return nil }
        let threshold = m.min + (m.max - m.min) * 0.38

        let minRun = max(h / 14, 18)
        guard let band = bestContiguousBand(means: smoothed, threshold: threshold, minLength: minRun) else {
            return nil
        }

        let gmax = smoothed[band.start ... band.end].max() ?? m.max
        let tightened = tightenBandRows(
            means: smoothed,
            rTop: band.start,
            rBottom: band.end,
            peakFloor: max(gmax * 0.66, threshold + 4),
            maxSpanPx: max(Int(Double(h) * 0.36), 44),
            minSpanPx: max(h / 12, 24)
        )
        let rTop = tightened.start
        let rBottom = tightened.end
        guard rBottom > rTop, let colSpan = horizontalBrightSpan(
            cgImage: cgImage,
            width: w,
            height: h,
            row0: rTop,
            row1: rBottom
        ) else { return nil }

        let marginX = CGFloat(w) * 0.012
        let marginY = CGFloat(h) * 0.028
        var x0 = CGFloat(colSpan.left) - marginX
        var x1 = CGFloat(colSpan.right) + marginX
        var yTop = CGFloat(rTop) - marginY
        var yBot = CGFloat(rBottom) + marginY
        x0 = max(0, min(x0, CGFloat(w - 1)))
        x1 = max(x0 + 8, min(x1, CGFloat(w)))
        yTop = max(0, min(yTop, CGFloat(h - 1)))
        yBot = max(yTop + 8, min(yBot, CGFloat(h)))

        let vw = (x1 - x0) / CGFloat(w)
        let vh = (yBot - yTop) / CGFloat(h)
        let vx = x0 / CGFloat(w)
        let vyBottomVision = 1.0 - yBot / CGFloat(h)
        var rect = CGRect(x: vx, y: vyBottomVision, width: vw, height: vh)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return Self.clampStripForFiveCardRow(rect)
    }

    /// Caps an overly tall bright strip (menu + content + dock) to a band suitable for a **single horizontal card row**.
    static func clampStripForFiveCardRow(_ visionNorm: CGRect, maxHeight: CGFloat = 0.40, minHeight: CGFloat = 0.085) -> CGRect {
        var r = visionNorm
        guard r.height > 1e-4 else { return r }
        if r.height > maxHeight {
            let mid = r.minY + r.height * 0.5
            var nh = min(r.height, maxHeight)
            var ny = mid - nh * 0.5
            if ny < 0 {
                ny = 0
            }
            if ny + nh > 1 {
                nh = max(minHeight, 1 - ny)
            }
            r = CGRect(x: r.minX, y: ny, width: r.width, height: max(minHeight, min(nh, maxHeight)))
        }
        if r.height < minHeight {
            let mid = r.minY + r.height * 0.5
            r = CGRect(x: r.minX, y: max(0, mid - minHeight * 0.5), width: r.width, height: minHeight)
            if r.maxY > 1 {
                r.origin.y = max(0, 1 - r.height)
            }
        }
        return r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func tightenBandRows(
        means: [Float],
        rTop: Int,
        rBottom: Int,
        peakFloor: Float,
        maxSpanPx: Int,
        minSpanPx: Int
    ) -> (start: Int, end: Int) {
        var s = rTop
        var e = rBottom
        while s < e && means[s] < peakFloor { s += 1 }
        while e > s && means[e] < peakFloor { e -= 1 }
        if s > e { return (rTop, rBottom) }
        let len = e - s + 1
        if len <= maxSpanPx && len >= minSpanPx { return (s, e) }
        if len < minSpanPx { return (rTop, rBottom) }

        /// Long band: keep the **densest** vertical window of at most `maxSpanPx` rows (card row vs. full window chrome).
        let window = min(max(len, minSpanPx), maxSpanPx)
        var bestStart = s
        var bestScore: Float = -1
        let hi = e - window + 1
        if hi >= s {
            for start in s ... hi {
                let end = start + window - 1
                var sum: Float = 0
                for i in start ... end { sum += means[i] }
                if sum > bestScore {
                    bestScore = sum
                    bestStart = start
                }
            }
            return (bestStart, bestStart + window - 1)
        }
        return (s, e)
    }

    private struct Band {
        var start: Int
        var end: Int
        var score: Float
    }

    private struct ColSpan {
        var left: Int
        var right: Int
    }

    private static func rowMeanLuminance(cgImage: CGImage, width: Int, height: Int) -> [Float]? {
        let bpp = 4
        let rowBytes = width * bpp
        var data = [UInt8](repeating: 0, count: height * rowBytes)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &data,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: rowBytes,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rows = [Float](repeating: 0, count: height)
        for y in 0 ..< height {
            var sum: Float = 0
            let row = y * rowBytes
            for x in 0 ..< width {
                let o = row + x * bpp
                let r = Float(data[o])
                let g = Float(data[o &+ 1])
                let b = Float(data[o &+ 2])
                sum += 0.299 * r + 0.587 * g + 0.114 * b
            }
            rows[y] = sum / Float(width)
        }
        return rows
    }

    private static func boxBlur1D(_ values: [Float], radius: Int) -> [Float] {
        guard radius > 0, values.count > 1 else { return values }
        let n = values.count
        var out = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let a = max(0, i - radius)
            let b = min(n - 1, i + radius)
            var s: Float = 0
            for j in a ... b { s += values[j] }
            out[i] = s / Float(b - a + 1)
        }
        return out
    }

    private static func minMax(_ values: [Float]) -> (min: Float, max: Float)? {
        guard let f = values.first else { return nil }
        var lo = f
        var hi = f
        for v in values.dropFirst() {
            lo = min(lo, v)
            hi = max(hi, v)
        }
        return (lo, hi)
    }

    private static func bestContiguousBand(means: [Float], threshold: Float, minLength: Int) -> Band? {
        let n = means.count
        var best: Band?
        var runStart: Int?
        var runSum: Float = 0
        func closeRun(end: Int) {
            guard let s = runStart else { return }
            let len = end - s + 1
            if len >= minLength {
                let density = runSum / sqrt(Float(len))
                let b = Band(start: s, end: end, score: density)
                if best == nil || b.score > best!.score {
                    best = b
                }
            }
            runStart = nil
            runSum = 0
        }
        for i in 0 ..< n {
            if means[i] >= threshold {
                if runStart == nil { runStart = i }
                runSum += means[i] - threshold
            } else if runStart != nil {
                closeRun(end: i - 1)
            }
        }
        if runStart != nil {
            closeRun(end: n - 1)
        }
        return best
    }

    private static func horizontalBrightSpan(
        cgImage: CGImage,
        width: Int,
        height: Int,
        row0: Int,
        row1: Int
    ) -> ColSpan? {
        let bpp = 4
        let rowBytes = width * bpp
        var data = [UInt8](repeating: 0, count: height * rowBytes)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &data,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: rowBytes,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var colMean = [Float](repeating: 0, count: width)
        let rA = max(0, row0)
        let rB = min(height - 1, row1)
        let denom = Float(rB - rA + 1)
        guard denom > 0 else { return nil }
        for x in 0 ..< width {
            var s: Float = 0
            for y in rA ... rB {
                let o = y * rowBytes + x * bpp
                let r = Float(data[o])
                let g = Float(data[o &+ 1])
                let b = Float(data[o &+ 2])
                s += 0.299 * r + 0.587 * g + 0.114 * b
            }
            colMean[x] = s / denom
        }

        guard let mm = minMax(colMean) else { return nil }
        let tc = mm.min + (mm.max - mm.min) * 0.32
        var left = 0
        var right = width - 1
        for x in 0 ..< width where colMean[x] > tc {
            left = x
            break
        }
        for x in stride(from: width - 1, through: 0, by: -1) where colMean[x] > tc {
            right = x
            break
        }
        guard right > left, right - left >= width / 12 else {
            return ColSpan(left: 0, right: width - 1)
        }

        var l = left
        var r = right
        /// Wide landscape frames (monitor / desktop screenshots) benefit from trimming window chrome; **portrait** library photos of a card row must keep full width.
        let aspect = Float(width) / Float(height)
        let tightHorizontalForScreenshotChrome = aspect >= 1.52

        if tightHorizontalForScreenshotChrome {
            let gMax = colMean.max() ?? 1
            let edgeT = max(gMax * 0.42, mm.min + (mm.max - mm.min) * 0.22)
            let maxEdgeTrim = max(Int(Double(width) * 0.10), 20)
            var trimL = 0
            while l < r && colMean[l] < edgeT && trimL < maxEdgeTrim {
                l += 1
                trimL += 1
            }
            var trimR = 0
            while r > l && colMean[r] < edgeT && trimR < maxEdgeTrim {
                r -= 1
                trimR += 1
            }
            if r - l < max(width / 5, 48) {
                l = left
                r = right
            }

            let span = r - l + 1
            if span > Int(Double(width) * 0.80) {
                let gutter = max(width / 28, 8)
                func bandMean(_ x0: Int, _ x1: Int) -> Float {
                    guard x1 >= x0 else { return 0 }
                    var s: Float = 0
                    for x in x0 ... x1 { s += colMean[x] }
                    return s / Float(x1 - x0 + 1)
                }
                let leftGutter = bandMean(l, min(l + gutter, r))
                let rightGutter = bandMean(max(r - gutter, l), r)
                let mid0 = l + (r - l) / 2 - gutter * 2
                let mid1 = l + (r - l) / 2 + gutter * 2
                let centerCore = bandMean(max(l, mid0), min(r, mid1))
                let edgeAvg = (leftGutter + rightGutter) * 0.5
                if centerCore > edgeAvg * 1.20 {
                    let targetW = max(Int(Double(width) * 0.70), width / 4)
                    let mid = (l + r) / 2
                    var nl = max(l, mid - targetW / 2)
                    let nr = min(r, nl + targetW - 1)
                    if nr - nl + 1 < targetW {
                        nl = max(l, nr - targetW + 1)
                    }
                    if nr - nl + 1 >= width / 5 {
                        l = nl
                        r = nr
                    }
                }
            }
        }

        return ColSpan(left: l, right: r)
    }
}
