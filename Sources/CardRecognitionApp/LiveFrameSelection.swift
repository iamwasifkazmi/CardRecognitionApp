#if os(iOS)
import CoreVideo

/// Picks the sharpest live frame from a short burst (focus / motion settle).
enum LiveFrameSelection: Sendable {
    /// Higher = sharper (mean horizontal luma contrast on a coarse grid).
    static func sharpnessScore(_ buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let step = 10
        guard width > step * 2, height > step * 2 else { return 0 }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total: Float = 0
        var samples = 0

        var y = step
        while y < height - step {
            let row = y * bytesPerRow
            var x = step
            while x < width - step {
                let left = luminanceBGRA(bytes, row + x * 4)
                let right = luminanceBGRA(bytes, row + (x + step) * 4)
                total += abs(left - right)
                samples += 1
                x += step
            }
            y += step
        }

        return samples > 0 ? total / Float(samples) : 0
    }

    private static func luminanceBGRA(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> Float {
        let b = Float(bytes[offset])
        let g = Float(bytes[offset + 1])
        let r = Float(bytes[offset + 2])
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
#endif
