import CoreGraphics
import CoreImage
import CoreVideo
import Vision

enum FrameNormalizer: Sendable {
    private static let context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])

    /// Produces a `.up` CGImage so Vision coordinates, Core Image crops, and rectangle corners all share one space.
    static func uprightCGImage(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(forExifOrientation: Int32(orientation.rawValue))
        let extent = ci.extent.integral
        guard extent.width > 1, extent.height > 1 else { return nil }
        return context.createCGImage(ci, from: extent)
    }

    /// Bakes EXIF orientation into upright pixels (needed for gallery imports where `CGImage` bytes may not match `.up`).
    static func uprightCGImage(cgImage: CGImage, exifOrientation: CGImagePropertyOrientation) -> CGImage? {
        guard exifOrientation != .up else { return cgImage }
        let ci = CIImage(cgImage: cgImage).oriented(forExifOrientation: Int32(exifOrientation.rawValue))
        let extent = ci.extent.integral
        guard extent.width > 1, extent.height > 1 else { return nil }
        return context.createCGImage(ci, from: extent)
    }
}

enum CardScanError: Error {
    case couldNotNormalizeFrame
}
