#if os(iOS)
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import UIKit

/// Carries a `CGImage` across `Sendable` boundaries (AVFoundation callbacks → `async` continuations / `Task.detached`).
private final class SendableCGImageBox: @unchecked Sendable {
    let cgImage: CGImage
    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

private final class PhotoCaptureBridge: NSObject, AVCapturePhotoCaptureDelegate {
    private let orientation: CGImagePropertyOrientation
    private let onFinish: @Sendable (Result<SendableCGImageBox?, Error>) -> Void

    init(orientation: CGImagePropertyOrientation, onFinish: @escaping @Sendable (Result<SendableCGImageBox?, Error>) -> Void) {
        self.orientation = orientation
        self.onFinish = onFinish
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            onFinish(.failure(error))
            return
        }
        if let pb = photo.pixelBuffer {
            let cg = FrameNormalizer.uprightCGImage(pixelBuffer: pb, orientation: orientation)
            onFinish(.success(cg.map { SendableCGImageBox($0) }))
            return
        }
        if let data = photo.fileDataRepresentation(),
           let ui = UIImage(data: data),
           let cg = ui.cgImage {
            let upright = FrameNormalizer.uprightCGImage(cgImage: cg, exifOrientation: .up) ?? cg
            onFinish(.success(SendableCGImageBox(upright)))
            return
        }
        onFinish(.failure(CameraDiagnosticsError.photoHasNoImageData))
    }
}

final class IOSCameraService: @unchecked Sendable {
    private final class OutputBridge: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        weak var owner: IOSCameraService?

        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            owner?.mailbox.deliver(pb)
        }
    }

    private(set) var authorizationDenied = false

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "cardrecognition.capture.session")
    /// Must be separate from the session queue — using the same queue can prevent delivery of sample buffers reliably.
    private let videoDataQueue = DispatchQueue(label: "cardrecognition.video.frames", qos: .userInitiated)
    private let outputBridge = OutputBridge()

    final class FrameMailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: CVPixelBuffer?

        func deliver(_ pixelBuffer: CVPixelBuffer) {
            lock.lock()
            latest = pixelBuffer
            lock.unlock()
        }

        func withLatest<Result>(_ closure: (CVPixelBuffer?) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return closure(latest)
        }
    }

    private let mailbox = FrameMailbox()
    private let photoOutput = AVCapturePhotoOutput()
    /// `true` when `photoOutput` was attached to the session (full-resolution stills).
    private(set) var photoOutputEnabled = false
    /// Exact sizes allowed by `capturePhoto(with:settings:)` — from the active camera format’s `supportedMaxPhotoDimensions`.
    private var supportedPhotoDimensions: [CMVideoDimensions] = []
    private weak var captureDevice: AVCaptureDevice?
    private var pendingPhotoBridge: PhotoCaptureBridge?

    init() {
        outputBridge.owner = self
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
    }

    func activate() async -> String? {
        authorizationDenied = false

#if targetEnvironment(simulator)
        /// No AVCapture hardware in Simulator — skip session setup without surfacing Simulator-specific UI copy.
        return nil
#else
        let granted = await Self.requestAuthorization()
        guard granted else {
            authorizationDenied = true
            return "Camera access denied — enable Camera in Settings to capture the display."
        }

        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                let error = self.configureLockedSession()
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

    /// **Capture then read:** grabs **one** full-resolution still (photo output) when available, otherwise the latest video frame, then runs Vision **once**.
    /// Avoids multi-frame majority voting that can scramble slot order when geometry shifts frame-to-frame.
    func performScan(
        interfaceOrientation cgOrientation: CGImagePropertyOrientation,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> Result<CardVisionPipeline.ScanResult, Error> {
#if targetEnvironment(simulator)
        await Task.yield()
        return .failure(CameraDiagnosticsError.simulatorNoCameraHardware)
#else
        /// Session may still be spinning up the first buffers right after `startRunning()`; give it a short window.
        let maxWaitNs: UInt64 = 2_500_000_000
        let pollNs: UInt64 = 50_000_000
        var waited: UInt64 = 0
        while waited < maxWaitNs {
            let hasFrame = await hasPixelBufferInMailbox()
            if hasFrame { break }
            try? await Task.sleep(nanoseconds: pollNs)
            waited += pollNs
        }

        let ready = await hasPixelBufferInMailbox()
        guard ready else {
            return .failure(CameraDiagnosticsError.cameraWarmingUp)
        }

        progress?("Hold steady — capturing a frozen frame…")
        try? await Task.sleep(nanoseconds: 280_000_000)

        let cgImage: CGImage?
        if photoOutputEnabled {
            progress?("Capturing high-resolution still…")
            let photoResult = await capturePhotoStillWithRetries(orientation: cgOrientation, maxAttempts: 3)
            switch photoResult {
            case .success(let box):
                if let box {
                    cgImage = box.cgImage
                } else {
                    progress?("Could not normalize photo — using preview frame…")
                    cgImage = await copyLatestUprightSnapshot(orientation: cgOrientation)
                }
            case .failure:
                progress?("Photo capture failed — using preview frame…")
                cgImage = await copyLatestUprightSnapshot(orientation: cgOrientation)
            }
        } else {
            progress?("Capturing preview frame…")
            cgImage = await copyLatestUprightSnapshot(orientation: cgOrientation)
        }

        guard let cgImage else {
            return .failure(CameraDiagnosticsError.cameraWarmingUp)
        }

        /// Brief settle after shutter / buffer handoff before Vision runs on the still.
        try? await Task.sleep(nanoseconds: 120_000_000)
        progress?("Frozen frame ready — reading cards…")
        let boxed = SendableCGImageBox(cgImage)
        do {
            let result = try await Task.detached(priority: .userInitiated) { [boxed] in
                try CardVisionPipeline.analyze(cgImage: boxed.cgImage)
            }.value
            return .success(result)
        } catch {
            return .failure(error)
        }
#endif
    }

    private func capturePhotoStillWithRetries(
        orientation: CGImagePropertyOrientation,
        maxAttempts: Int
    ) async -> Result<SendableCGImageBox?, Error> {
        let supported = await supportedPhotoDimensionsOnSessionQueue()
        var attemptSizes: [CMVideoDimensions?] = Self.photoDimensionsByDescendingArea(supported).map { Optional($0) }
        /// Last resort: omit `maxPhotoDimensions` on settings (never pass arbitrary width/height — that crashes).
        attemptSizes.append(nil)
        let limit = min(maxAttempts, attemptSizes.count)

        var lastError: Error?
        for attempt in 0 ..< limit {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 280_000_000)
            }
            let one = await captureOnePhotoStill(
                orientation: orientation,
                maxPhotoDimensions: attemptSizes[attempt]
            )
            switch one {
            case .success(let box):
                if let box {
                    return .success(box)
                }
                lastError = CameraDiagnosticsError.photoHasNoImageData
            case .failure(let err):
                lastError = err
            }
        }
        return .failure(lastError ?? CameraDiagnosticsError.photoHasNoImageData)
    }

    private func supportedPhotoDimensionsOnSessionQueue() async -> [CMVideoDimensions] {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: self.supportedPhotoDimensions)
            }
        }
    }

    private static func photoDimensionsByDescendingArea(_ dimensions: [CMVideoDimensions]) -> [CMVideoDimensions] {
        dimensions.sorted { lhs, rhs in
            Int64(lhs.width) * Int64(lhs.height) > Int64(rhs.width) * Int64(rhs.height)
        }
    }

    private static func supportedPhotoDimensions(for device: AVCaptureDevice) -> [CMVideoDimensions] {
        if #available(iOS 16.0, *) {
            return device.activeFormat.supportedMaxPhotoDimensions
        }
        return []
    }

    private func captureOnePhotoStill(
        orientation: CGImagePropertyOrientation,
        maxPhotoDimensions: CMVideoDimensions? = nil
    ) async -> Result<SendableCGImageBox?, Error> {
        await withCheckedContinuation { continuation in
            let bridge = PhotoCaptureBridge(orientation: orientation) { [weak self] result in
                self?.pendingPhotoBridge = nil
                continuation.resume(returning: result)
            }
            pendingPhotoBridge = bridge
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(CameraDiagnosticsError.cameraWarmingUp))
                    return
                }
                guard self.captureSession.isRunning else {
                    self.pendingPhotoBridge = nil
                    continuation.resume(returning: .failure(CameraDiagnosticsError.cameraWarmingUp))
                    return
                }
                let settings = AVCapturePhotoSettings()
                if let cap = maxPhotoDimensions {
                    /// Must be an **exact** entry from `supportedMaxPhotoDimensions` — not min() with device max.
                    let allowed = self.supportedPhotoDimensions.contains {
                        $0.width == cap.width && $0.height == cap.height
                    }
                    if allowed {
                        settings.maxPhotoDimensions = cap
                    }
                }
                self.photoOutput.capturePhoto(with: settings, delegate: bridge)
            }
        }
    }

    private func copyLatestUprightSnapshot(orientation: CGImagePropertyOrientation) async -> CGImage? {
        await withCheckedContinuation { continuation in
            videoDataQueue.async {
                let image: CGImage? = self.mailbox.withLatest { buffer in
                    guard let buffer else { return nil }
                    return FrameNormalizer.uprightCGImage(pixelBuffer: buffer, orientation: orientation)
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func hasPixelBufferInMailbox() async -> Bool {
        await withCheckedContinuation { continuation in
            videoDataQueue.async {
                let filled = self.mailbox.withLatest { $0 != nil }
                continuation.resume(returning: filled)
            }
        }
    }

    private func configureLockedSession() -> String? {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if captureSession.canSetSessionPreset(.hd4K3840x2160) {
            captureSession.sessionPreset = .hd4K3840x2160
        } else {
            captureSession.sessionPreset = .hd1920x1080
        }
        photoOutputEnabled = false

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
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
        } catch {
            /// Autofocus is best-effort; continue without failing session setup.
        }
        captureSession.addInput(input)
        captureDevice = camera
        supportedPhotoDimensions = Self.supportedPhotoDimensions(for: camera)

        guard captureSession.canAddOutput(videoOutput) else {
            return "Unable to attach a video analyzer output."
        }

        captureSession.addOutput(videoOutput)
        /// Let the device/runtime pick dimensions/format when possible — strict BGRA can block delivery on some pipelines.
        videoOutput.videoSettings = [:]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(outputBridge, queue: videoDataQueue)

        if let conn = videoOutput.connection(with: .video) {
            conn.preferredVideoStabilizationMode = .off
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }

        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
            photoOutputEnabled = true
            /// Re-read after photo output is attached — active format’s supported sizes can change.
            if let captureDevice {
                supportedPhotoDimensions = Self.supportedPhotoDimensions(for: captureDevice)
            }
            if let pConn = photoOutput.connection(with: .video) {
                pConn.preferredVideoStabilizationMode = .off
                if pConn.isVideoOrientationSupported {
                    pConn.videoOrientation = .portrait
                }
            }
        }

        return nil
    }

    private static func requestAuthorization() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        default:
            return false
        }
    }
}

enum CameraDiagnosticsError: LocalizedError, Sendable {
    case cameraWarmingUp
    case simulatorNoCameraHardware
    case photoHasNoImageData

    var errorDescription: String? {
        switch self {
        case .cameraWarmingUp:
            return "Live preview hasn’t delivered a frame yet. Wait a moment and try again, or open Settings ▸ Privacy ▸ Camera and allow access for this app."
        case .simulatorNoCameraHardware:
            return "Live camera capture isn’t available. Use Photo Library or Browse Files to choose an image."
        case .photoHasNoImageData:
            return "The camera captured a photo but no image buffer was returned. Try again or use Photo Library import."
        }
    }
}
#endif
