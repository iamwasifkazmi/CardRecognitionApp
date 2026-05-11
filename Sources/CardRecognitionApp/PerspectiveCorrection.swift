import CoreGraphics
import CoreImage
import CoreVideo
import Vision

enum PerspectiveCorrection: Sendable {
    private static let context = CIContext(options: [
        CIContextOption.useSoftwareRenderer: false,
    ])

    /// Warps a rectangle observation into an upright, fixed-aspect card image (resolution-normalized canonical size).
    static func warpedCardCGImage(
        pixelBuffer: CVPixelBuffer,
        observation: VNRectangleObservation,
        targetSize: CGSize = CGSize(width: 360, height: 504)
    ) -> CGImage? {
        let base = CIImage(cvPixelBuffer: pixelBuffer)
        return warpedCardCGImage(base: base, observation: observation, targetSize: targetSize)
    }

    /// Warps a rectangle observation derived from full-frame imagery already represented by `ciImage`.
    static func warpedCardCGImage(
        base: CIImage,
        observation: VNRectangleObservation,
        targetSize: CGSize = CGSize(width: 360, height: 504)
    ) -> CGImage? {
        let extent = base.extent
        let w = extent.width
        let h = extent.height
        guard w > 1, h > 1 else { return nil }

        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * w, y: p.y * h)
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
        let sx = targetSize.width / corrected.extent.width
        let sy = targetSize.height / corrected.extent.height
        let scaled = corrected.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let rect = CGRect(origin: .zero, size: targetSize)
        return context.createCGImage(scaled, from: rect)
    }

    static func croppedCardCGImage(
        pixelBuffer: CVPixelBuffer,
        normalizedRect: CGRect,
        targetSize: CGSize = CGSize(width: 360, height: 504)
    ) -> CGImage? {
        let base = CIImage(cvPixelBuffer: pixelBuffer)
        return croppedCardCGImage(base: base, normalizedRect: normalizedRect, targetSize: targetSize)
    }

    /// Axis-aligned crop + scale used when five equal slots are synthesized.
    static func croppedCardCGImage(
        base: CIImage,
        normalizedRect: CGRect,
        targetSize: CGSize = CGSize(width: 360, height: 504)
    ) -> CGImage? {
        let w = base.extent.width
        let h = base.extent.height
        let pixelRect = CGRect(
            x: normalizedRect.minX * w,
            y: normalizedRect.minY * h,
            width: normalizedRect.width * w,
            height: normalizedRect.height * h
        ).integral

        guard pixelRect.width > 8, pixelRect.height > 8 else { return nil }

        let cropped = base.cropped(to: pixelRect)
        let sx = targetSize.width / cropped.extent.width
        let sy = targetSize.height / cropped.extent.height
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let rect = CGRect(origin: .zero, size: targetSize)
        return context.createCGImage(scaled, from: rect)
    }
}
