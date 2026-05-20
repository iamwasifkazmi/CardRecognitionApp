import CoreGraphics

/// Suit from the **center court pip** via `SuitTemplateShapeMatcher` + `SuitColorHeuristic` (not blind shape defaults).
enum CardCourtSuitReader: Sendable {
    enum Method: String, Sendable {
        case templateRed
        case templateBlack
        case colorRed
    }

    static func inferSuit(for image: CGImage) -> (suit: Suit, method: Method)? {
        if SuitColorHeuristic.courtShowsRedPipPigment(image) {
            if let suit = SuitTemplateShapeMatcher.inferRedSuitsOnly(for: image) {
                return (suit, .templateRed)
            }
            if let suit = SuitColorHeuristic.infer(for: image) {
                return (suit, .colorRed)
            }
            if SuitColorHeuristic.courtSuggestsRedPipsWeak(image),
               let suit = SuitTemplateShapeMatcher.inferRedSuitsOnly(for: image) {
                return (suit, .templateRed)
            }
            return nil
        }
        if SuitColorHeuristic.courtShowsBlackPips(image),
           let suit = SuitTemplateShapeMatcher.inferBlackSuitsOnly(for: image) {
            return (suit, .templateBlack)
        }
        return nil
    }
}
