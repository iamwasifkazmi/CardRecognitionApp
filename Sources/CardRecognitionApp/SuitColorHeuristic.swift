import CoreGraphics

/// Reserved for finer color cues (red vs black). Screen captures already carry strong typography; OCR + optional Core ML cover most UX.
enum SuitColorHeuristic: Sendable {
    static func infer(for _: CGImage) -> Suit? {
        nil
    }
}
