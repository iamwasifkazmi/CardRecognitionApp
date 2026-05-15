import CoreGraphics
import CoreImage
import CoreVideo
import Vision

enum PerspectiveCorrection: Sendable {
    private static let context = CIContext(options: [
        CIContextOption.useSoftwareRenderer: false,
    ])

    /// Rasterize `ci` scaled toward `targetSize`, flattening non-zero `extent.origin` (plain `createCGImage(..., from: .zero)` often returns nil).
    private static func rasterizeScaled(_ ci: CIImage, targetSize: CGSize) -> CGImage? {
        guard ci.extent.width > 1, ci.extent.height > 1, ci.extent.isInfinite == false else { return nil }
        let sx = targetSize.width / ci.extent.width
        let sy = targetSize.height / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let flattened = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        let rect = flattened.extent.integral
        guard rect.width > 1, rect.height > 1 else { return nil }
        return context.createCGImage(flattened, from: rect)
    }

    /// Warps a rectangle observation into an upright, fixed-aspect card image (resolution-normalized canonical size).
    static func warpedCardCGImage(
        pixelBuffer: CVPixelBuffer,
        observation: VNRectangleObservation,
        targetSize: CGSize = CGSize(width: 480, height: 672)
    ) -> CGImage? {
        let base = CIImage(cvPixelBuffer: pixelBuffer)
        return warpedCardCGImage(base: base, observation: observation, targetSize: targetSize)
    }

    /// Warps a rectangle observation derived from full-frame imagery already represented by `ciImage`.
    static func warpedCardCGImage(
        base: CIImage,
        observation: VNRectangleObservation,
        targetSize: CGSize = CGSize(width: 480, height: 672)
    ) -> CGImage? {
        let extent = base.extent
        let w = extent.width
        let h = extent.height
        guard w > 1, h > 1 else { return nil }

        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * w, y: extent.minY + p.y * h)
        }

        let tl = point(observation.topLeft)
        let tr = point(observation.topRight)
        let br = point(observation.bottomRight)
        let bl = point(observation.bottomLeft)

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(base, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft")

        guard let corrected = filter.outputImage else { return nil }
        return rasterizeScaled(corrected, targetSize: targetSize)
    }

    static func croppedCardCGImage(
        pixelBuffer: CVPixelBuffer,
        normalizedRect: CGRect,
        targetSize: CGSize = CGSize(width: 480, height: 672)
    ) -> CGImage? {
        let base = CIImage(cvPixelBuffer: pixelBuffer)
        return croppedCardCGImage(base: base, normalizedRect: normalizedRect, targetSize: targetSize)
    }

    /// Axis-aligned crop + scale used when five equal slots are synthesized.
    static func croppedCardCGImage(
        base: CIImage,
        normalizedRect: CGRect,
        targetSize: CGSize = CGSize(width: 480, height: 672)
    ) -> CGImage? {
        let extent = base.extent
        let w = extent.width
        let h = extent.height
        let pixelRect = CGRect(
            x: extent.minX + normalizedRect.minX * w,
            y: extent.minY + normalizedRect.minY * h,
            width: normalizedRect.width * w,
            height: normalizedRect.height * h
        ).integral

        guard pixelRect.width > 8, pixelRect.height > 8 else { return nil }

        let cropped = base.cropped(to: pixelRect)
        return rasterizeScaled(cropped, targetSize: targetSize)
    }
}
