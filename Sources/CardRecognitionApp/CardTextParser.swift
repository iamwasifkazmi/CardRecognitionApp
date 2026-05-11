import Foundation

/// Parses rank/suit hints from OCR text on cropped card imagery.
enum CardTextParser: Sendable {
    static func parseRank(from raw: String) -> Rank? {
        let folded = raw.folding(options: .diacriticInsensitive, locale: .current)
        if let r = rankRegexpMatch(folded) { return r }
        return heuristicRank(folded.uppercased())
    }

    static func parseSuit(from raw: String) -> Suit? {
        let folds = raw.folding(options: .diacriticInsensitive, locale: .current)
        let lower = folds.lowercased()

        let wordMap: [(String, Suit)] = [
            ("spade", .spades), ("spades", .spades), ("♠", .spades), ("♤", .spades),
            ("heart", .hearts), ("hearts", .hearts), ("♥", .hearts), ("♡", .hearts),
            ("diamond", .diamonds), ("diamonds", .diamonds), ("♦", .diamonds), ("♢", .diamonds),
            ("club", .clubs), ("clubs", .clubs), ("♣", .clubs), ("♧", .clubs),
        ]
        for (needle, suit) in wordMap {
            if lower.contains(needle) { return suit }
        }

        for ch in folds {
            if ch.isWhitespace { continue }
            if let suit = Suit.from(character: ch) {
                return suit
            }
        }

        guard let regex = suitLetterRegexp else { return nil }
        let ns = folds as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: folds, options: [], range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        let letter = ns.substring(with: match.range(at: 1)).lowercased()
        switch letter {
        case "s": return .spades
        case "h": return .hearts
        case "d": return .diamonds
        case "c": return .clubs
        default: return nil
        }
    }

    private static let suitLetterRegexp = try? NSRegularExpression(
        pattern: #"(?:^|[\s\|,])([shdc])(?:$|[\s\|,])"#,
        options: [.caseInsensitive]
    )

    private static let compactRankRegexp = try? NSRegularExpression(
        pattern: #"(?:^|[^A-Z0-9])(10|[2-9]|A|K|Q|J)(?:$|[^A-Z0-9])"#,
        options: [.caseInsensitive]
    )

    private static func rankRegexpMatch(_ folded: String) -> Rank? {
        guard let regex = compactRankRegexp else { return nil }
        let ns = folded as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: folded, options: [], range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        let token = ns.substring(with: match.range(at: 1)).uppercased()
        return rankToken(token)
    }

    private static func heuristicRank(_ upper: String) -> Rank? {
        if upper.contains("10") || upper.contains("TEN") { return .ten }
        if upper.contains("ACE") { return .ace }
        if upper.contains("KING") { return .king }
        if upper.contains("QUEEN") || upper.range(of: #"\bQ\b"#, options: .regularExpression) != nil {
            return .queen
        }
        if upper.contains("JACK") || upper.range(of: #"\bJ\b"#, options: .regularExpression) != nil {
            return .jack
        }
        return nil
    }

    private static func rankToken(_ token: String) -> Rank? {
        switch token {
        case "A": return .ace
        case "K": return .king
        case "Q": return .queen
        case "J": return .jack
        case "10": return .ten
        case "9": return .nine
        case "8": return .eight
        case "7": return .seven
        case "6": return .six
        case "5": return .five
        case "4": return .four
        case "3": return .three
        case "2": return .two
        default: return heuristicRank(token)
        }
    }
}
