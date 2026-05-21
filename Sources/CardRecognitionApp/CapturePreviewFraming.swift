import CoreGraphics

/// Aligns **live capture** pixels with the on-screen 16:9 preview (`IOSCameraPreview` + `resizeAspectFill`).
enum CapturePreviewFraming: Sendable {
    /// Wide monitor-style strip in the app UI (must match preview chrome).
    static let aspectRatio: CGFloat = 16 / 9

    /// Normalized **top-left** rect (0…1) for the five-card row guide drawn on the 16:9 preview.
    static let fiveCardRowGuideRectNormalizedTL = CGRect(x: 0.03, y: 0.26, width: 0.94, height: 0.46)

    /// Same band as the yellow guide, in **Vision / CI bottom-left** normalized coords (used for column crops).
    static var fiveCardRowGuideRectNormalizedBL: CGRect {
        normalizedBottomLeft(fromTopLeft: fiveCardRowGuideRectNormalizedTL)
    }

    /// Converts a normalized top-left rect to Vision’s bottom-left normalized space.
    static func normalizedBottomLeft(fromTopLeft rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: 1 - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Pixel rect (top-left origin, `.up` image) visible inside an aspect-fill preview of `viewAspect`.
    static func aspectFillPixelRect(
        imageWidth: Int,
        imageHeight: Int,
        viewAspect: CGFloat = aspectRatio
    ) -> CGRect {
        let w = CGFloat(max(imageWidth, 1))
        let h = CGFloat(max(imageHeight, 1))
        let imageAspect = w / h

        let crop: CGRect
        if imageAspect > viewAspect {
            let visibleW = h * viewAspect
            let x = (w - visibleW) / 2
            crop = CGRect(x: x, y: 0, width: visibleW, height: h)
        } else {
            let visibleH = w / viewAspect
            let y = (h - visibleH) / 2
            crop = CGRect(x: 0, y: y, width: w, height: visibleH)
        }
        return crop.integral
    }

    /// Drops letterbox / off-preview bands so Vision only sees what the user framed in the preview card.
    static func cropToVisiblePreview(_ image: CGImage, viewAspect: CGFloat = aspectRatio) -> CGImage {
        let rect = aspectFillPixelRect(
            imageWidth: image.width,
            imageHeight: image.height,
            viewAspect: viewAspect
        )
        guard rect.width >= 8, rect.height >= 8,
              let cropped = image.cropping(to: rect)
        else {
            return image
        }
        return cropped
    }
}
