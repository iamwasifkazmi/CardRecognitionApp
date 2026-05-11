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
}
