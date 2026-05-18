import CoreGraphics

/// Shared pixel rect for sampling the oversized **court pip** inside a warped card crop (used by `SuitColorHeuristic` + `SuitTemplateShapeMatcher`).
enum CardCourtSampling: Sendable {
    /// Framing variants so template match survives slightly different pip scale / crop.
    enum CourtFraming: CaseIterable {
        case standard
        /// More context (helps busy court cards).
        case zoomOut
        /// Tighter on the large pip (helps minimal slot art).
        case zoomIn

        fileprivate var insetFactors: (CGFloat, CGFloat) {
            switch self {
            case .standard: (0.168, 0.092)
            case .zoomOut: (0.124, 0.068)
            case .zoomIn: (0.198, 0.108)
            }
        }
    }

    static func centerCourtIntegralRect(
        imageWidth w: Int,
        imageHeight h: Int,
        framing: CourtFraming = .standard
    ) -> CGRect {
        let (fx, fy) = framing.insetFactors
        let rx = CGFloat(w) * fx
        let ry = CGFloat(h) * fy
        let rw = CGFloat(w) - 2 * rx
        let rh = CGFloat(h) - 2 * ry
        return CGRect(x: rx, y: ry, width: max(16, rw), height: max(16, rh)).integral
    }

    static func centerCourtIntegralRect(for image: CGImage, framing: CourtFraming = .standard) -> CGRect {
        centerCourtIntegralRect(imageWidth: image.width, imageHeight: image.height, framing: framing)
    }
}
