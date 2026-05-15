#if os(iOS)
import AVFoundation
import CoreVideo
import UIKit

final class IOSCameraService: @unchecked Sendable {
    /// `CGImage` is not `Sendable`; mirrors `ScannerViewModel`’s detached-analysis pattern.
    private struct FrozenFrame: @unchecked Sendable {
        let cgImage: CGImage
    }

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

        /// Copies the newest buffer reference for analysis (caller must finish before next deliver).
        func copyLatest() -> CVPixelBuffer? {
            lock.lock()
            defer { lock.unlock() }
            return latest
        }
    }

    /// Live capture timing — lets autofocus settle, then freezes one upright frame for Vision (same stability as photo import).
    private enum LiveCaptureTiming {
        static let warmupMaxNs: UInt64 = 3_500_000_000
        static let warmupPollNs: UInt64 = 50_000_000
        /// Hold steady after orientation so preview matches analyzed pixels.
        static let settleNs: UInt64 = 550_000_000
        /// Extra polls so `mailbox` isn’t stuck on an earlier stale buffer right after reconnect/orientation.
        static let freezePollAttempts = 12
        static let freezePollSpacingNs: UInt64 = 45_000_000
    }

    private let mailbox = FrameMailbox()

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
                let error = Self.configureLockedSession(
                    captureSession: self.captureSession,
                    videoOutput: self.videoOutput,
                    delegate: self.outputBridge,
                    delegateQueue: self.videoDataQueue
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

    func performScan(interfaceOrientation: UIInterfaceOrientation) async -> Result<CardVisionPipeline.ScanResult, Error> {
#if targetEnvironment(simulator)
        await Task.yield()
        return .failure(CameraDiagnosticsError.simulatorNoCameraHardware)
#else
        var waited: UInt64 = 0
        while waited < LiveCaptureTiming.warmupMaxNs {
            let hasFrame = await hasPixelBufferInMailbox()
            if hasFrame { break }
            try? await Task.sleep(nanoseconds: LiveCaptureTiming.warmupPollNs)
            waited += LiveCaptureTiming.warmupPollNs
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                CaptureVideoOrientation.apply(
                    to: self.videoOutput.connection(with: .video),
                    interfaceOrientation: interfaceOrientation
                )
                continuation.resume()
            }
        }

        /// Let autofocus / exposure catch up and give the user time to hold the row in frame.
        try? await Task.sleep(nanoseconds: LiveCaptureTiming.settleNs)

        let frozen = await freezeFrameForAnalysis(interfaceOrientation: interfaceOrientation)
        guard let frozen else {
            return .failure(CameraDiagnosticsError.cameraWarmingUp)
        }

        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try CardVisionPipeline.analyze(cgImage: frozen.cgImage)
            }.value
            return .success(snapshot)
        } catch {
            return .failure(error)
        }
#endif
    }

    /// Locks pixels into a `CGImage` on the video queue immediately (pool-safe), same path Vision uses for imports.
    private func freezeFrameForAnalysis(interfaceOrientation: UIInterfaceOrientation) async -> FrozenFrame? {
        for _ in 0 ..< LiveCaptureTiming.freezePollAttempts {
            let frozen = await withCheckedContinuation { (continuation: CheckedContinuation<FrozenFrame?, Never>) in
                videoDataQueue.async {
                    guard let pb = self.mailbox.copyLatest() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let exif = CaptureVideoOrientation.exifForAnalysis(
                        pixelBuffer: pb,
                        interfaceOrientation: interfaceOrientation
                    )
                    guard let cg = FrameNormalizer.uprightCGImage(pixelBuffer: pb, orientation: exif) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: FrozenFrame(cgImage: cg))
                }
            }
            if let frozen {
                return frozen
            }
            try? await Task.sleep(nanoseconds: LiveCaptureTiming.freezePollSpacingNs)
        }
        return nil
    }

    private func hasPixelBufferInMailbox() async -> Bool {
        await withCheckedContinuation { continuation in
            videoDataQueue.async {
                let filled = self.mailbox.withLatest { $0 != nil }
                continuation.resume(returning: filled)
            }
        }
    }

    private static func configureLockedSession(
        captureSession: AVCaptureSession,
        videoOutput: AVCaptureVideoDataOutput,
        delegate: AVCaptureVideoDataOutputSampleBufferDelegate?,
        delegateQueue: DispatchQueue
    ) -> String? {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .hd1920x1080

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

        guard captureSession.canAddOutput(videoOutput) else {
            return "Unable to attach a video analyzer output."
        }

        captureSession.addOutput(videoOutput)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(delegate, queue: delegateQueue)

        if let conn = videoOutput.connection(with: .video) {
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

enum CameraDiagnosticsError: LocalizedError {
    case cameraWarmingUp
    case simulatorNoCameraHardware

    var errorDescription: String? {
        switch self {
        case .cameraWarmingUp:
            return "Live preview hasn’t delivered a frame yet. Wait a moment and try again, or open Settings ▸ Privacy ▸ Camera and allow access for this app."
        case .simulatorNoCameraHardware:
            return "Live camera capture isn’t available. Use Photo Library or Browse Files to choose an image."
        }
    }
}
#endif
