#if os(iOS)
import AVFoundation
import CoreVideo

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

    func performScan(interfaceOrientation cgOrientation: CGImagePropertyOrientation) async -> Result<CardVisionPipeline.ScanResult, Error> {
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

        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                let outcome: Result<CardVisionPipeline.ScanResult, Error> = self.mailbox.withLatest { buffer in
                    guard let buffer else {
                        return .failure(CameraDiagnosticsError.cameraWarmingUp)
                    }
                    do {
                        let result = try CardVisionPipeline.analyze(pixelBuffer: buffer, orientation: cgOrientation)
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
                continuation.resume(returning: outcome)
            }
        }
#endif
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
        /// Let the device/runtime pick dimensions/format when possible — strict BGRA can block delivery on some pipelines.
        videoOutput.videoSettings = [:]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(delegate, queue: delegateQueue)

        if let conn = videoOutput.connection(with: .video) {
            conn.preferredVideoStabilizationMode = .off
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
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
