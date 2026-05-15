import Observation
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
import AVFoundation
#endif

private struct RasterHandle: @unchecked Sendable {
    let cgImage: CGImage
}

@Observable @MainActor
final class ScannerViewModel {
    var statusBanner: String?
    var latestScan: CardVisionPipeline.ScanResult?
    var isAnalyzing = false
    /// True while the live camera is settling / bursting frames (longer than a file import).
    var isAnalyzingLiveCapture = false
    var isImporterPresented = false

#if os(iOS)
    private let iosCamera = IOSCameraService()

    var captureSessionForPreview: AVCaptureSession {
        iosCamera.captureSession
    }

    func bootstrapIOSCamera() async {
        if let failure = await iosCamera.activate() {
            statusBanner = failure
        } else {
            statusBanner = nil
        }
    }

    func teardownIOSCamera() {
        iosCamera.deactivate()
    }

    func analyzeLiveScene() async {
        guard isAnalyzing == false else { return }
        isAnalyzing = true
        isAnalyzingLiveCapture = true
        defer {
            isAnalyzing = false
            isAnalyzingLiveCapture = false
        }

        statusBanner = "Hold steady — capturing the card row…"
        let orientation = OrientationReader.preferredVideoOrientationHint()
        let outcome = await iosCamera.performScan(interfaceOrientation: orientation)
        switch outcome {
        case .success(let snapshot):
            latestScan = snapshot
            statusBanner = "Analyzed five cards in one snapshot."
        case .failure(let error):
            latestScan = nil
            statusBanner = error.localizedDescription
        }
    }
#endif

    func analyzeImportedFile(url: URL) async {
        let startedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if startedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let cg = try BitmapImport.cgImageVisionReady(contentsOf: url)
            await analyzeStandalone(cgImage: cg)
        } catch {
            statusBanner = error.localizedDescription
        }
    }

    /// Image bytes from PhotosPicker / pasteboard pipelines (JPEG, PNG, HEIC, etc.).
    func analyzeImportedImageData(_ data: Data) async {
        do {
            let cg = try BitmapImport.cgImageVisionReady(bytes: data)
            await analyzeStandalone(cgImage: cg)
        } catch {
            latestScan = nil
            statusBanner = error.localizedDescription
        }
    }

    func analyzeStandalone(cgImage: CGImage) async {
        guard isAnalyzing == false else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let handle = RasterHandle(cgImage: cgImage)

        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try CardVisionPipeline.analyze(cgImage: handle.cgImage)
            }.value

            latestScan = snapshot
            statusBanner = "Analyzed five cards from imported image."
        } catch {
            latestScan = nil
            statusBanner = error.localizedDescription
        }
    }
}
