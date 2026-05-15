#if os(iOS)
import AVFoundation
import UIKit

extension UIInterfaceOrientation {
    /// EXIF orientation for **landscape-sized** rear-camera buffers (sensor long edge horizontal).
    var cgImageOrientationForPortraitCamera: CGImagePropertyOrientation {
        switch self {
        case .portraitUpsideDown: .left
        case .landscapeRight: .up
        case .landscapeLeft: .down
        case .portrait, .unknown: .right
        @unknown default: .right
        }
    }

    /// Matches `IOSCameraPreview` / `AVCaptureConnection.videoOrientation` (landscape left/right are swapped vs UI).
    var avCaptureVideoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        case .unknown: .portrait
        @unknown default: .portrait
        }
    }
}

/// Keeps preview, `AVCaptureVideoDataOutput`, and Vision normalization aligned.
enum CaptureVideoOrientation: Sendable {
    static func apply(to connection: AVCaptureConnection?, interfaceOrientation: UIInterfaceOrientation) {
        guard let connection else { return }
        if #available(iOS 17.0, *) {
            let angle = videoRotationAngle(for: interfaceOrientation)
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                return
            }
        }
        /// Fallback (and pre‑iOS 17): `videoRotationAngle` is not always supported on every connection tuple; skipping left the stream mis‑oriented and broke Vision + OCR.
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = interfaceOrientation.avCaptureVideoOrientation
        }
    }

    @available(iOS 17.0, *)
    private static func videoRotationAngle(for interfaceOrientation: UIInterfaceOrientation) -> CGFloat {
        /// Matches the historical `AVCaptureVideoOrientation` mapping used by `IOSCameraPreview`.
        switch interfaceOrientation {
        case .portrait: 90
        case .portraitUpsideDown: 270
        case .landscapeLeft: 0
        case .landscapeRight: 180
        case .unknown: 90
        @unknown default: 90
        }
    }

    /// When `videoOrientation` is already applied on the capture connection, buffers arrive portrait-sized (`height ≥ width`) and must **not** be rotated again (double-rotation breaks rectangle detection and OCR).
    static func exifForAnalysis(
        pixelWidth: Int,
        pixelHeight: Int,
        interfaceOrientation: UIInterfaceOrientation
    ) -> CGImagePropertyOrientation {
        guard pixelWidth > pixelHeight else { return .up }
        return interfaceOrientation.cgImageOrientationForPortraitCamera
    }

    static func exifForAnalysis(
        pixelBuffer: CVPixelBuffer,
        interfaceOrientation: UIInterfaceOrientation
    ) -> CGImagePropertyOrientation {
        exifForAnalysis(
            pixelWidth: CVPixelBufferGetWidth(pixelBuffer),
            pixelHeight: CVPixelBufferGetHeight(pixelBuffer),
            interfaceOrientation: interfaceOrientation
        )
    }
}

@MainActor
enum OrientationReader {
    static func preferredVideoOrientationHint() -> UIInterfaceOrientation {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            return .portrait
        }
        return scene.interfaceOrientation
    }
}
#endif
