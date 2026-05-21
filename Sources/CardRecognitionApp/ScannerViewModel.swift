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
    /// Camera-only phases shown under the progress view (`Taking photo…`, `Reading five cards…`).
    var cameraScanPhase: String?
    var isImporterPresented = false

#if os(iOS)
    private let iosCamera = IOSCameraService()

    var captureSessionForPreview: AVCaptureSession {
        iosCamera.captureSession
    }

    func bootstrapIOSCamera() async {
        if let failure = await iosCamera.activate() {
            statusBanner = failure
        } else if OCREngine.thirdPartyAvailable == false {
            #if targetEnvironment(simulator)
            statusBanner = "Simulator uses Vision OCR only. Plug in your iPhone and select it as the run destination for ML Kit."
            #else
            statusBanner = "Vision OCR only. Open CardRecognitionApp.xcworkspace (after pod install), not .xcodeproj."
            #endif
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
        cameraScanPhase = nil
        defer {
            isAnalyzing = false
            cameraScanPhase = nil
        }

        statusBanner = "Place all five cards in the yellow frame, then tap Photo & read."
        let orientation = OrientationReader.preferredVideoOrientationHint()

        cameraScanPhase = "Taking photo…"
        let imageResult = await iosCamera.captureStillImage(interfaceOrientation: orientation)
        switch imageResult {
        case .failure(let error):
            latestScan = nil
            statusBanner = error.localizedDescription
            return
        case .success(let cgImage):
            cameraScanPhase = "Reading five cards…"
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try CardVisionPipeline.analyze(cgImage: cgImage)
                }.value
                latestScan = snapshot
                statusBanner = "Captured one photo and read the row (not live video)."
            } catch {
                latestScan = nil
                statusBanner = error.localizedDescription
            }
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
