#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Hosts the live `AVCaptureVideoPreviewLayer`.
struct IOSCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        syncPreviewLayer(uiView: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.backgroundColor = .black
        syncPreviewLayer(uiView: uiView)
    }

    private func syncPreviewLayer(uiView: PreviewView) {
        let previewLayer = uiView.previewLayer
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        guard let conn = previewLayer.connection, conn.isVideoOrientationSupported else {
            return
        }

        /// Prefer window-scene orientation (stable when lying flat vs `UIDevice.current.orientation`).
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            switch scene.interfaceOrientation {
            case .portrait:
                conn.videoOrientation = .portrait
            case .portraitUpsideDown:
                conn.videoOrientation = .portraitUpsideDown
            case .landscapeLeft:
                conn.videoOrientation = .landscapeRight
            case .landscapeRight:
                conn.videoOrientation = .landscapeLeft
            @unknown default:
                conn.videoOrientation = .portrait
            }
        } else {
            conn.videoOrientation = .portrait
        }

        if conn.isVideoMirroringSupported, let videoInput = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) {
            conn.isVideoMirrored = videoInput.device.position == .front
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }
}
#endif
