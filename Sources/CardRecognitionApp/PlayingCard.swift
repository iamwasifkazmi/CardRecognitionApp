import Foundation

enum Rank: String, CaseIterable, Sendable, Identifiable {
    case ace = "A"
    case two = "2"
    case three = "3"
    case four = "4"
    case five = "5"
    case six = "6"
    case seven = "7"
    case eight = "8"
    case nine = "9"
    case ten = "10"
    case jack = "J"
    case queen = "Q"
    case king = "K"

    var id: String { rawValue }

    var displayName: String {
        rawValue
    }
}

enum Suit: String, CaseIterable, Sendable, Identifiable {
    case spades
    case hearts
    case diamonds
    case clubs

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .spades: "\u{2660}"
        case .hearts: "\u{2665}"
        case .diamonds: "\u{2666}"
        case .clubs: "\u{2663}"
        }
    }

    static func from(character: Character) -> Suit? {
        switch character {
        case "\u{2660}", "S", "s": .spades
        case "\u{2665}", "H", "h": .hearts
        case "\u{2666}", "D", "d": .diamonds
        case "\u{2663}", "C", "c": .clubs
        default: nil
        }
    }

    /// Filled SF Symbol name — tints reliably in SwiftUI unlike some Unicode pip glyphs alone.
    var sfFilledSymbolName: String {
        switch self {
        case .hearts: "suit.heart.fill"
        case .diamonds: "suit.diamond.fill"
        case .spades: "suit.spade.fill"
        case .clubs: "suit.club.fill"
        }
    }

    /// Short English title for tables when symbols are unavailable or as a caption beside the icon.
    var displayTitle: String {
        switch self {
        case .spades: "Spades"
        case .hearts: "Hearts"
        case .diamonds: "Diamonds"
        case .clubs: "Clubs"
        }
    }
}

struct RecognizedPlayingCard: Identifiable, Sendable, Equatable {
    let id: UUID
    var rank: Rank?
    var suit: Suit?
    /// Quality score in 0–1 synthesized from OCR confidences where available.
    var confidence: Float
    var diagnosis: String

    init(
        id: UUID = UUID(),
        rank: Rank? = nil,
        suit: Suit? = nil,
        confidence: Float = 0,
        diagnosis: String = ""
    ) {
        self.id = id
        self.rank = rank
        self.suit = suit
        self.confidence = confidence
        self.diagnosis = diagnosis
    }

    var shortLabel: String {
        let rankText = rank?.displayName ?? "?"
        let suitText = suit?.symbol ?? "?"
        return "\(rankText)\(suitText)"
    }

    /// Table “Rank” column (unknown → `?`).
    var rankTableLabel: String {
        rank?.displayName ?? "?"
    }

    /// Table “Suit” column glyph (unknown → `?`); prefer `suitColumnTitle` for UI strings.
    var suitTableLabel: String {
        suit?.symbol ?? "?"
    }

    /// Human-readable suit for the table (`Unknown` when not inferred).
    var suitColumnTitle: String {
        suit?.displayTitle ?? "Unknown"
    }
}
