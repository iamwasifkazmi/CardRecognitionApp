import CoreGraphics
import CoreImage
import CoreVideo

enum FrameNormalizer: Sendable {
    private static let context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])

    /// Attenuates high-frequency **LCD moiré / refresh beat** before `VNDetectRectangles` + OCR.
    /// Down-then-up with a high-quality scaler kills narrow beat frequencies while keeping index glyphs legible.
    static func preparedForCardVision(cgImage: CGImage) -> CGImage {
        let ci = CIImage(cgImage: cgImage)
        let extent = ci.extent.integral
        guard extent.width > 8, extent.height > 8 else { return cgImage }
        let longEdge = max(extent.width, extent.height)
        /// Stronger reduction on very large frames (phone 12MP+ pointed at a monitor picks up harsh beat patterns).
        let scaleDown: CGFloat = {
            if longEdge >= 2000 { return 0.72 }
            if longEdge >= 1500 { return 0.76 }
            if longEdge >= 1100 { return 0.80 }
            return 0.86
        }()
        guard scaleDown < 0.995 else { return cgImage }

        guard let down = CIFilter(name: "CILanczosScaleTransform") else { return cgImage }
        down.setValue(ci, forKey: kCIInputImageKey)
        down.setValue(scaleDown, forKey: kCIInputScaleKey)
        down.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let small = down.outputImage else { return cgImage }

        let scaleUp = 1.0 / scaleDown
        guard let up = CIFilter(name: "CILanczosScaleTransform") else { return cgImage }
        up.setValue(small, forKey: kCIInputImageKey)
        up.setValue(scaleUp, forKey: kCIInputScaleKey)
        up.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let restored = up.outputImage else { return cgImage }

        let crop = restored.extent.intersection(ci.extent)
        guard crop.width > 4, crop.height > 4 else { return cgImage }
        return context.createCGImage(restored, from: crop.integral) ?? cgImage
    }

    /// Camera stills and library photos can differ by **10+ MP vs 2 MP**; cap long edge so rectangle + OCR paths match what Photo Library imports usually hit after decode + moiré prep.
    static func canonicalScanCGImage(cgImage: CGImage, maxLongEdge: Int = 2560) -> CGImage {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return cgImage }
        let long = max(w, h)
        guard long > maxLongEdge else { return cgImage }
        let scale = CGFloat(maxLongEdge) / CGFloat(long)
        let ci = CIImage(cgImage: cgImage)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaled.extent.integral
        guard extent.width > 8, extent.height > 8 else { return cgImage }
        return context.createCGImage(scaled, from: extent) ?? cgImage
    }

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
