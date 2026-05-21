import CoreGraphics

/// Console debugging for Vision + OCR (`⌘⇧Y` in Xcode → filter **`SlotRecognition`**).
enum SlotRecognitionDiagnostics: Sendable {
    /// Set `false` to silence all `[SlotRecognition]` lines (e.g. before shipping).
    nonisolated(unsafe) static var isLoggingEnabled = true
    /// Per-ROI OCR lines (`physical_index`, `mlkit_slot`, combined_pool, …). Keep `false` unless debugging OCR.
    nonisolated(unsafe) static var verboseOCRLogging = false

    static func log(_ message: @autoclosure () -> String) {
        guard isLoggingEnabled else { return }
        print("[SlotRecognition] \(message())")
    }

    static func logOCR(_ message: @autoclosure () -> String) {
        guard isLoggingEnabled, verboseOCRLogging else { return }
        print("[SlotRecognition] \(message())")
    }

    static func logRectNorm(_ prefix: String, _ rect: CGRect) {
        log("\(prefix) origin=(\(fmt(rect.minX)),\(fmt(rect.minY))) size=\(fmt(rect.width))×\(fmt(rect.height))")
    }

    static func ellipsis(_ text: String, limit: Int = 160) -> String {
        guard text.count > limit else {
            return text.isEmpty ? "∅" : text
        }
        return String(text.prefix(limit)) + " …(\(text.count) chars)"
    }

    private static func fmt(_ v: CGFloat) -> String {
        String(format: "%.4f", v)
    }
}
