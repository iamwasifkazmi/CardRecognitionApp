import Foundation

/// Parses rank/suit hints from OCR text on cropped card imagery.
enum CardTextParser: Sendable {
    static func parseRank(from raw: String) -> Rank? {
        let folded = raw.folding(options: .diacriticInsensitive, locale: .current)
        let normalized = normalizeOCRDigitArtifacts(folded)
        if let r = rankRegexpMatch(normalized) { return r }
        if let r = rankAnywhereMatch(normalized) { return r }
        if let r = courtRankWithNoiseMatch(normalized) { return r }
        if let r = heuristicRank(normalized.uppercased()) { return r }
        return relaxedDigitRank(normalized)
    }

    /// Tries each snippet in order (e.g. corner → mirror → full); skips strings that look like OCR garbage.
    static func firstRank(in sources: [String]) -> Rank? {
        for raw in sources {
            for chunk in ocrChunks(from: raw) {
                guard chunk.isEmpty == false,
                      isPlausibleOCRSnippet(chunk),
                      isSlotMachineChromeText(chunk) == false
                else { continue }
                if let r = parseRank(from: chunk) { return r }
            }
        }
        return nil
    }

    /// Index corner first, then body/mirror — avoids `leftBand`/`pip` digits stealing rank on neighbor bleed.
    static func firstRank(cornerSources: [String], then otherSources: [String]) -> Rank? {
        firstRank(in: cornerSources) ?? firstRank(in: otherSources)
    }

    /// Suit symbols and bounded SHDC letters only — never scan every character (avoids `"the"` → hearts via `h`).
    static func firstSuit(in sources: [String]) -> Suit? {
        for raw in sources {
            for chunk in ocrChunks(from: raw) {
                guard chunk.isEmpty == false,
                      isPlausibleOCRSnippet(chunk),
                      isSlotMachineChromeText(chunk) == false
                else { continue }
                if let s = parseSuit(from: chunk) { return s }
            }
        }
        return nil
    }

    /// Ignores rank-only OCR noise (`"4"`, `"2"`, `"J"`) so templates are not fed false “suit” evidence.
    static func firstSuitExplicit(in sources: [String]) -> Suit? {
        for raw in sources {
            for chunk in ocrChunks(from: raw) {
                guard chunk.isEmpty == false,
                      isPlausibleOCRSnippet(chunk),
                      isSlotMachineChromeText(chunk) == false,
                      hasExplicitSuitSignal(chunk)
                else { continue }
                if let s = parseSuit(from: chunk) { return s }
            }
        }
        return nil
    }

    private static func hasExplicitSuitSignal(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        for ch in trimmed {
            if Suit.from(character: ch) != nil { return true }
        }
        if parseSuit(from: trimmed) != nil { return true }
        if gluedRankSuitLetter(trimmed) != nil || trailingRankSuitLetter(trimmed) != nil { return true }
        if trimmed.count <= 2, parseRank(from: trimmed) != nil, parseSuit(from: trimmed) == nil { return false }
        if trimmed.count <= 3, trimmed.allSatisfy(\.isNumber) { return false }
        return false
    }

    /// WIN / BET / CREDIT labels under the reel are not card indices — ignore them for rank/suit pooling.
    static func isSlotMachineChromeText(_ raw: String) -> Bool {
        let upper = raw.folding(options: .diacriticInsensitive, locale: .current).uppercased()
        guard upper.count >= 3 else { return false }
        let chrome = [
            "WIN", "CREDIT", "REDIT", "DEBIT", "BET", "BALANCE", "CASHOUT", "CASH OUT",
            "COIN", "PAID", "PAYLINE", "HOLD", "DEAL", "DRAW",
        ]
        for word in chrome {
            if upper.contains(word) { return true }
        }
        if upper.range(of: #"\bBET\s*\d"#, options: .regularExpression) != nil { return true }
        if upper.range(of: #"\bCREDIT\s*\d"#, options: .regularExpression) != nil { return true }
        if upper.range(of: #"\bWIN\s*\d"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// True when the string is mostly Latin / digits / card symbols ( Vision sometimes emits Cyrillic noise in pips).
    static func isPlausibleOCRSnippet(_ raw: String) -> Bool {
        if raw.count > 120 { return false }
        let scalars = raw.unicodeScalars
        var garbage = 0
        var printable = 0
        for us in scalars {
            if us.properties.generalCategory == .control { continue }
            printable += 1
            let v = us.value
            if (0x0400 ... 0x04FF).contains(v) || (0x0500 ... 0x052F).contains(v) {
                garbage += 1
            }
        }
        guard printable > 0 else { return false }
        return Float(garbage) / Float(printable) < 0.35
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
            switch ch {
            case "\u{2660}", "\u{2665}", "\u{2666}", "\u{2663}",
                 "\u{2664}", "\u{2661}", "\u{2662}", "\u{2667}":
                return Suit.from(character: ch)
            default:
                continue
            }
        }

        if let glued = gluedRankSuitLetter(folds) { return glued }
        if let trailing = trailingRankSuitLetter(folds) { return trailing }

        guard let regex = suitLetterRegexp else { return nil }
        let ns = folds as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: folds, options: [], range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        return suitFromLetter(ns.substring(with: match.range(at: 1)))
    }

    /// OCR often glues rank + suit letter (`2d`, `Jh`, `9c`) with no separator.
    private static func gluedRankSuitLetter(_ folds: String) -> Suit? {
        guard let regex = gluedRankSuitRegexp else { return nil }
        let ns = folds as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: folds, options: [], range: range), match.numberOfRanges >= 3 else {
            return nil
        }
        return suitFromLetter(ns.substring(with: match.range(at: 2)))
    }

    private static func trailingRankSuitLetter(_ folds: String) -> Suit? {
        let trimmed = folds.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let last = trimmed.last else { return nil }
        let letter = String(last)
        guard let suit = suitFromLetter(letter) else { return nil }
        let head = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.isEmpty == false, parseRank(from: head) != nil else { return nil }
        return suit
    }

    private static func suitFromLetter(_ letter: String) -> Suit? {
        switch letter.lowercased() {
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

    private static let gluedRankSuitRegexp = try? NSRegularExpression(
        pattern: #"(?:^|[^A-Za-z0-9])(10|[2-9]|A|K|Q|J)([shdc])(?:$|[^A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )

    private static let compactRankRegexp = try? NSRegularExpression(
        pattern: #"(?:^|[^A-Z0-9])(10|[2-9]|A|K|Q|J)(?:$|[^A-Z0-9])"#,
        options: [.caseInsensitive]
    )

    private static let rankAnywhereRegexp = try? NSRegularExpression(
        pattern: #"\b(10|[2-9]|A|K|Q|J)\b"#,
        options: [.caseInsensitive]
    )

    /// Vision often appends a stray letter to court glyphs (`Qf`, `K|`, `Jr`).
    private static let courtRankWithOCRNoiseRegexp = try? NSRegularExpression(
        pattern: #"\b(10|[2-9]|A|[KQJ])[A-Za-z]{0,2}\b"#,
        options: [.caseInsensitive]
    )

    private static let splitDigitTenRegexp = try? NSRegularExpression(
        pattern: #"\b(?:1\s+0|0\s+1)\b"#,
        options: [.caseInsensitive]
    )

    /// When Vision reads “10” as “LO”, “IO”, “1O”, etc.
    private static let ocrTenTokenRegexes: [NSRegularExpression] = {
        /// Glue forms like **LOof** (no `\b` between **O** and **o**) are common mirror-OCR reads of **10**.
        let patterns = [
            #"(?i)\bLO\b"#,
            #"(?i)\bL0\b"#,
            #"(?i)\bIO\b"#,
            #"(?i)\blO\b"#,
            #"(?i)\b1O\b"#,
            #"(?i)\b1o\b"#,
            #"(?i)\bI0\b"#,
            #"(?i)\bl0\b"#,
            #"(?i)(?:^|[\s\|,])1O(?:$|[\s\|,])"#,
            #"(?i)(?:^|[\s\|,])IO(?:$|[\s\|,])"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    /// Last resort: a lone digit/rank glyph surrounded by OCR noise (“RET 4 …” keeps “4”).
    private static let relaxedDigitRankRegexp = try? NSRegularExpression(
        pattern: #"(?:^|[^0-9A-Za-z])(10|[2-9]|A|K|Q|J)(?:$|[^0-9A-Za-z])"#,
        options: [.caseInsensitive]
    )

    private static func normalizeOCRDigitArtifacts(_ s: String) -> String {
        var result = s
        /// Slot reels often misread **9** as **O1** / **01** in the top-left index.
        if let o1 = try? NSRegularExpression(pattern: #"(?i)\bO\s*1\b"#, options: []) {
            let r = NSRange(location: 0, length: (result as NSString).length)
            result = o1.stringByReplacingMatches(in: result, options: [], range: r, withTemplate: "9")
        }
        if let ol = try? NSRegularExpression(pattern: #"(?i)\bO\s*l\b"#, options: []) {
            let r = NSRange(location: 0, length: (result as NSString).length)
            result = ol.stringByReplacingMatches(in: result, options: [], range: r, withTemplate: "9")
        }
        /// Mirror/corner misreads of **9** as **LOof** / **10of** (do not treat as ten).
        if let nineGlue = try? NSRegularExpression(
            pattern: #"(?i)LOof|L0of|10of|1Oof|1o\s*of"#, options: []
        ) {
            let r = NSRange(location: 0, length: (result as NSString).length)
            result = nineGlue.stringByReplacingMatches(in: result, options: [], range: r, withTemplate: "9")
        }
        /// Vision often splits ten into two glyphs (**`1 0`**) or mirrored order (**`0 1`**).
        if let re = splitDigitTenRegexp {
            let r = NSRange(location: 0, length: (result as NSString).length)
            result = re.stringByReplacingMatches(in: result, options: [], range: r, withTemplate: "10")
        }

        let len = (result as NSString).length
        guard len > 0 else { return result }
        var range = NSRange(location: 0, length: len)
        for regex in ocrTenTokenRegexes {
            range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "10")
        }
        return result
    }

    /// Keeps plausible checks sane for long pooled OCR strings — try head + tail slices.
    private static func ocrChunks(from raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let limit = 120
        guard trimmed.count > limit else { return [trimmed] }
        return [String(trimmed.prefix(limit)), String(trimmed.suffix(limit))]
    }

    private static func relaxedDigitRank(_ s: String) -> Rank? {
        guard let regex = relaxedDigitRankRegexp else { return nil }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: s, options: [], range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        let token = ns.substring(with: match.range(at: 1)).uppercased()
        return rankToken(token)
    }

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

    private static func rankAnywhereMatch(_ folded: String) -> Rank? {
        guard let regex = rankAnywhereRegexp else { return nil }
        let ns = folded as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: folded, options: [], range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        let token = ns.substring(with: match.range(at: 1)).uppercased()
        return rankToken(token)
    }

    private static func courtRankWithNoiseMatch(_ folded: String) -> Rank? {
        guard let regex = courtRankWithOCRNoiseRegexp else { return nil }
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
        if upper.range(of: #"\bK\b"#, options: .regularExpression) != nil { return .king }
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
