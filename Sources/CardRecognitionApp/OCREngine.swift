import CoreGraphics
import Foundation

/// OCR backends: **Google ML Kit** (iOS + CocoaPods) first, then Apple Vision.
enum OCREngine: Sendable {
    enum Backend: String, Sendable {
        case mlKit = "MLKit"
        case vision = "Vision"
    }

    struct Options: Sendable {
        var accurate: Bool = true
        var minimumTextHeight: Float = 0.02
        var suitGlyphLexicon: Bool = false

        static let accurate = Options(accurate: true)
        static let fast = Options(accurate: false, minimumTextHeight: 0.015)
    }

    struct Result: Sendable {
        var text: String
        var averageConfidence: Float
        var backend: Backend
    }

    static var preferredBackend: Backend {
        #if canImport(MLKitTextRecognition)
        return .mlKit
        #else
        return .vision
        #endif
    }

    static var thirdPartyAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif canImport(MLKitTextRecognition)
        return GoogleMLKitOCR.isAvailable
        #else
        return false
        #endif
    }

    static func recognize(cgImage: CGImage, options: Options = .accurate) -> Result {
        #if canImport(MLKitTextRecognition)
        let ml = GoogleMLKitOCR.recognize(cgImage: cgImage)
        if ml.text.isEmpty == false {
            return Result(text: ml.text, averageConfidence: ml.averageConfidence, backend: .mlKit)
        }
        #endif
        let vision = VisionOCRBackend.recognize(cgImage: cgImage, options: options)
        return Result(text: vision.text, averageConfidence: vision.averageConfidence, backend: .vision)
    }
}
