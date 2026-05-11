import CoreGraphics

/// Red vs black hint for corner pips (♥/♦ vs ♠/♣). Cannot resolve ♥ vs ♦ or ♠ vs ♣ by color alone — OCR symbols take priority in the pipeline.
enum SuitColorHeuristic: Sendable {
    static func infer(for image: CGImage) -> Suit? {
        let w = image.width
        let h = image.height
        guard w > 16, h > 16 else { return nil }

        let rw = max(8, Int(Double(w) * 0.42))
        let rh = max(8, Int(Double(h) * 0.42))
        let rect = CGRect(x: 0, y: 0, width: CGFloat(rw), height: CGFloat(rh)).integral
        guard let corner = image.cropping(to: rect) else { return nil }

        let cw = corner.width
        let ch = corner.height
        let bpp = 4
        let rowBytes = cw * bpp
        var data = [UInt8](repeating: 0, count: Int(ch * rowBytes))
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
        ctx.draw(corner, in: CGRect(x: 0, y: 0, width: cw, height: ch))

        var redish = 0
        var blueish = 0
        var sumBlue: Float = 0
        var sumGreen: Float = 0
        var totalSampled = 0

        for y in 0 ..< Int(ch) {
            for x in 0 ..< Int(cw) {
                let i = y * Int(rowBytes) + x * bpp
                let r = Float(data[i])
                let g = Float(data[i &+ 1])
                let b = Float(data[i &+ 2])
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                if lum > 248 { continue }
                totalSampled += 1
                if r > max(g, b) * 1.18, r > 72 {
                    redish += 1
                    sumBlue += b
                    sumGreen += g
                }
                if b > max(r, g) * 1.12, b > 52 {
                    blueish += 1
                }
            }
        }

        guard totalSampled > 24 else { return nil }
        let redRatio = Float(redish) / Float(totalSampled)
        let blueRatio = Float(blueish) / Float(totalSampled)

        /// Many slot UIs draw ♦ in bright blue; red pips stay on the existing branch.
        if redRatio < 0.028, blueRatio > 0.032 {
            return .diamonds
        }

        guard redRatio > 0.045 else { return nil }

        guard redish > 0 else { return .hearts }
        let avgB = sumBlue / Float(redish)
        let avgG = sumGreen / Float(redish)
        if avgB < avgG * 0.9 {
            return .hearts
        }
        return .diamonds
    }
}
