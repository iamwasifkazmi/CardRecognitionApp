import CoreGraphics

/// Suit from the **center court pip** via strict template match only — no hue-only ♥/♦ guess (`Unknown` if ambiguous).
enum CardCourtSuitReader: Sendable {
    enum Method: String, Sendable {
        case templateRed
        case templateBlack
    }

    static func inferSuit(for image: CGImage) -> (suit: Suit, method: Method)? {
        if SuitColorHeuristic.courtShowsRedPipPigment(image),
           let suit = SuitTemplateShapeMatcher.inferRedSuitsStrict(for: image) {
            return (suit, .templateRed)
        }
        if SuitColorHeuristic.courtShowsBlackPips(image),
           let suit = SuitTemplateShapeMatcher.inferBlackSuitsStrict(for: image) {
            return (suit, .templateBlack)
        }
        return nil
    }
}
