import Foundation
import ImageIO

enum BitmapImportError: Error {
    case cannotReadContents
}

enum BitmapImport: Sendable {
    static func cgImage(contentsOf url: URL) throws -> CGImage {
        let data = try Data(contentsOf: url)
        return try cgImage(bytes: data)
    }

    static func cgImage(bytes: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw BitmapImportError.cannotReadContents
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BitmapImportError.cannotReadContents
        }
        return image
    }

    /// Decodes image bytes and applies EXIF orientation so Vision + Core Image agree on pixel layout (Photos / Files imports).
    static func cgImageVisionReady(bytes: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw BitmapImportError.cannotReadContents
        }
        guard let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BitmapImportError.cannotReadContents
        }

        let orientation: CGImagePropertyOrientation
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let tag = props[kCGImagePropertyOrientation] as? UInt32,
           let value = CGImagePropertyOrientation(rawValue: tag) {
            orientation = value
        } else {
            orientation = .up
        }

        if orientation == .up { return raw }
        return FrameNormalizer.uprightCGImage(cgImage: raw, exifOrientation: orientation) ?? raw
    }

    static func cgImageVisionReady(contentsOf url: URL) throws -> CGImage {
        let data = try Data(contentsOf: url)
        return try cgImageVisionReady(bytes: data)
    }
}
