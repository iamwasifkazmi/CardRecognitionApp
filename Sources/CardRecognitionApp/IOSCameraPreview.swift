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
        /// Must stay **aspect fill** — `CapturePreviewFraming` crops the analyzed frame to this same visible region (no top/bottom letterbox in Vision).
        previewLayer.videoGravity = .resizeAspectFill

        /// Prefer window-scene orientation (stable when lying flat vs `UIDevice.current.orientation`).
        let interface = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .interfaceOrientation ?? .portrait
        CaptureVideoOrientation.apply(to: previewLayer.connection, interfaceOrientation: interface)

        if let conn = previewLayer.connection,
           conn.isVideoMirroringSupported,
           let videoInput = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) })
        {
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
