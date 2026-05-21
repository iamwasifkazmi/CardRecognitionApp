#if os(iOS)
@preconcurrency import AVFoundation
import CoreVideo
import UIKit

final class IOSCameraService: @unchecked Sendable {

    private(set) var authorizationDenied = false

    let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "cardrecognition.capture.session")

    /// Holds `AVCapturePhotoCaptureDelegate` alive for the duration of one shot.
    private final class PhotoCaptureSink: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        let onFinish: @Sendable (AVCapturePhoto, Error?) -> Void

        init(onFinish: @escaping @Sendable (AVCapturePhoto, Error?) -> Void) {
            self.onFinish = onFinish
        }

        func photoOutput(
            _ output: AVCapturePhotoOutput,
            didFinishProcessingPhoto photo: AVCapturePhoto,
            error: Error?
        ) {
            onFinish(photo, error)
        }
    }

    /// Single still capture: settle focus/exposure, take **one photo**, then run Vision on that image (not streaming video).
    private enum StillCaptureTiming {
        static let warmupMaxNs: UInt64 = 3_500_000_000
        static let warmupPollNs: UInt64 = 50_000_000
        /// User aligns the row in the on-screen guide; give AF/AE time before the shutter.
        static let settleBeforeShutterNs: UInt64 = 650_000_000
    }

    private var inflightPhotoSink: PhotoCaptureSink?

    /// `CGImage` is not `Sendable`; wrapping satisfies Swift 6 `CheckedContinuation` when returning a still from the photo pipeline.
    private struct SendableCGImageBox: @unchecked Sendable {
        let cgImage: CGImage
    }

    func activate() async -> String? {
        authorizationDenied = false

#if targetEnvironment(simulator)
        return nil
#else
        let granted = await Self.requestAuthorization()
        guard granted else {
            authorizationDenied = true
            return "Camera access denied — enable Camera in Settings to capture the display."
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            sessionQueue.async { @Sendable in
                let error = Self.configureLockedSession(
                    captureSession: self.captureSession,
                    photoOutput: self.photoOutput
                )
                if error == nil {
                    self.captureSession.startRunning()
                }
                continuation.resume(returning: error)
            }
        }
#endif
    }

    func deactivate() {
        sessionQueue.async {
            guard self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }

    /// One full-resolution still (same crop as the 16:9 preview). Call Vision separately so the UI can show “photo” vs “read” phases.
    func captureStillImage(interfaceOrientation: UIInterfaceOrientation) async -> Result<CGImage, Error> {
#if targetEnvironment(simulator)
        await Task.yield()
        return .failure(CameraDiagnosticsError.simulatorNoCameraHardware)
#else
        var waited: UInt64 = 0
        while waited < StillCaptureTiming.warmupMaxNs {
            if captureSession.isRunning { break }
            try? await Task.sleep(nanoseconds: StillCaptureTiming.warmupPollNs)
            waited += StillCaptureTiming.warmupPollNs
        }

        guard captureSession.isRunning else {
            return .failure(CameraDiagnosticsError.cameraWarmingUp)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { @Sendable in
                if let conn = self.photoOutput.connection(with: .video) {
                    CaptureVideoOrientation.apply(
                        to: conn,
                        interfaceOrientation: interfaceOrientation
                    )
                }
                continuation.resume()
            }
        }

        try? await Task.sleep(nanoseconds: StillCaptureTiming.settleBeforeShutterNs)
        return await captureOnePhoto(interfaceOrientation: interfaceOrientation)
#endif
    }

#if !targetEnvironment(simulator)
    private func captureOnePhoto(interfaceOrientation: UIInterfaceOrientation) async -> Result<CGImage, Error> {
        let boxed = await withCheckedContinuation { (continuation: CheckedContinuation<Result<SendableCGImageBox, Error>, Never>) in
            let orientationCapture = interfaceOrientation
            sessionQueue.async { @Sendable in
                guard self.inflightPhotoSink == nil else {
                    continuation.resume(returning: .failure(CameraDiagnosticsError.captureAlreadyInProgress))
                    return
                }

                let settings = AVCapturePhotoSettings()
                settings.flashMode = .off
                /// Do **not** set `isHighResolutionPhotoEnabled` unless `photoOutput.highResolutionCaptureEnabled` is YES — otherwise AVFoundation raises `NSInvalidArgumentException` and the app exits.

                let sink = PhotoCaptureSink { [weak self] photo, error in
                    guard let self else {
                        continuation.resume(returning: .failure(CameraDiagnosticsError.cameraWarmingUp))
                        return
                    }
                    /// Finish on the session queue so the continuation is not crossed with `Task.detached` + non-`Sendable` photo types.
                    self.sessionQueue.async { @Sendable in
                        self.inflightPhotoSink = nil

                        if let error {
                            continuation.resume(returning: .failure(error))
                            return
                        }
                        guard let cg = Self.makeStillCGImage(
                            from: photo,
                            interfaceOrientation: orientationCapture
                        ) else {
                            continuation.resume(returning: .failure(CameraDiagnosticsError.cameraWarmingUp))
                            return
                        }
                        continuation.resume(returning: .success(SendableCGImageBox(cgImage: cg)))
                    }
                }
                self.inflightPhotoSink = sink
                self.photoOutput.capturePhoto(with: settings, delegate: sink)
            }
        }
        switch boxed {
        case .success(let box):
            return .success(box.cgImage)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Matches `freezeFrameForAnalysis`: upright orientation + same **aspect-fill** crop as the on-screen 16:9 preview.
    private static func makeStillCGImage(
        from photo: AVCapturePhoto,
        interfaceOrientation: UIInterfaceOrientation
    ) -> CGImage? {
        if let pb = photo.pixelBuffer {
            let exif = CaptureVideoOrientation.exifForAnalysis(
                pixelBuffer: pb,
                interfaceOrientation: interfaceOrientation
            )
            guard let upright = FrameNormalizer.uprightCGImage(pixelBuffer: pb, orientation: exif) else {
                return nil
            }
            return CapturePreviewFraming.cropToVisiblePreview(upright)
        }
        guard let data = photo.fileDataRepresentation() else { return nil }
        guard let decoded = try? BitmapImport.cgImageVisionReady(bytes: data) else { return nil }
        return CapturePreviewFraming.cropToVisiblePreview(decoded)
    }
#endif

    private static func configureLockedSession(
        captureSession: AVCaptureSession,
        photoOutput: AVCapturePhotoOutput
    ) -> String? {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .photo

        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }

        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input)
        else {
            return "No compatible rear camera detected."
        }
        captureSession.addInput(input)

        guard captureSession.canAddOutput(photoOutput) else {
            return "Unable to attach photo output."
        }
        captureSession.addOutput(photoOutput)
        if #available(iOS 15.0, *) {
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        if let conn = photoOutput.connection(with: .video) {
            conn.preferredVideoStabilizationMode = .off
            CaptureVideoOrientation.apply(to: conn, interfaceOrientation: .portrait)
        }

        return nil
    }

    private static func requestAuthorization() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .video) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        default:
            return false
        }
    }
}

enum CameraDiagnosticsError: LocalizedError {
    case cameraWarmingUp
    case captureAlreadyInProgress
    case simulatorNoCameraHardware

    var errorDescription: String? {
        switch self {
        case .cameraWarmingUp:
            return "Could not capture a photo. Hold steady, ensure the card row is in the yellow frame, and try again."
        case .captureAlreadyInProgress:
            return "A photo capture is already in progress. Wait for it to finish."
        case .simulatorNoCameraHardware:
            return "Live camera capture isn’t available. Use Photo Library or Browse Files to choose an image."
        }
    }
}
#endif
