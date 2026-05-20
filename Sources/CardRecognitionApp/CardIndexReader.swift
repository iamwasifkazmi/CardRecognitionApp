import CoreGraphics

/// Rank from index OCR; suit from OCR glyph or **icon template** on the index/court pip (not guessed defaults).
enum CardIndexReader: Sendable {
    enum SuitSource: String, Sendable {
        case ocr
        case indexIcon
        case centerIcon
    }

    struct Reading: Sendable {
        var cornerText: String
        var rank: Rank?
        var suit: Suit?
        var suitSource: SuitSource?
    }

    static func read(
        cardCrop: CGImage,
        slotIndex: Int? = nil,
        rowSliceColumn: Bool = false
    ) -> Reading {
        let physicalIndex = TextRecognition.physicalIndexCornerText(
            cardCrop: cardCrop,
            slotIndex: slotIndex,
            rowSliceColumn: rowSliceColumn
        )
        let physicalSuit = TextRecognition.physicalSuitGlyphText(
            cardCrop: cardCrop,
            slotIndex: slotIndex,
            rowSliceColumn: rowSliceColumn
        )
        let physicalMirror = TextRecognition.physicalMirrorIndexText(
            cardCrop: cardCrop,
            slotIndex: slotIndex,
            rowSliceColumn: rowSliceColumn
        )
        let cornerROI = TextRecognition.cornerIndexStackText(
            cardCrop: cardCrop,
            slotIndex: slotIndex,
            rowSliceColumn: rowSliceColumn
        )
        let suitGlyphROI = TextRecognition.cornerSuitGlyphText(
            cardCrop: cardCrop,
            slotIndex: slotIndex,
            rowSliceColumn: rowSliceColumn
        )
        let rankCorner = TextRecognition.rankOnlyCornerText(
            cardCrop: cardCrop,
            rowSliceColumn: rowSliceColumn
        )
        let snap = TextRecognition.extract(
            cardCrop: cardCrop,
            slotIndex: slotIndex,
            rowSliceColumn: rowSliceColumn
        )

        let cornerRankSources = [
            physicalIndex,
            physicalMirror,
            cornerROI,
            rankCorner,
            snap.topStripText,
        ]
        var rank = CardTextParser.firstRank(cornerSources: cornerRankSources, then: [])

        if rank == nil, containsCourtLetterHint(cornerRankSources) {
            let faceText = TextRecognition.cornerIndexSuitForFaceRank(
                cardCrop: cardCrop,
                narrowColumn: rowSliceColumn,
                slotIndex: slotIndex
            )
            rank = CardTextParser.firstRank(cornerSources: [faceText, snap.topStripText], then: [])
        }
        if rank == nil {
            rank = CardTextParser.firstRank(cornerSources: [snap.leftBandText], then: [])
        }

        var ocrSuitSources = [
            physicalSuit,
            physicalIndex,
            physicalMirror,
            suitGlyphROI,
            cornerROI,
            snap.suitCornerText,
            snap.topStripText,
        ]
        if let r = rank {
            let extra = rankSpecificSuitOCR(
                cardCrop: cardCrop,
                rank: r,
                rowSliceColumn: rowSliceColumn,
                slotIndex: slotIndex
            )
            if extra.isEmpty == false {
                ocrSuitSources.insert(extra, at: 0)
            }
        }

        var suit = CardTextParser.firstSuitExplicit(in: ocrSuitSources)
        var suitSource: SuitSource? = suit != nil ? .ocr : nil

        if suit == nil, let icon = SuitIconDetector.detect(
            cardCrop: cardCrop,
            rowSliceColumn: rowSliceColumn,
            slotIndex: slotIndex
        ) {
            suit = icon.suit
            suitSource = icon.method == .indexGlyph ? .indexIcon : .centerIcon
        }

        let cornerText = [
            physicalIndex,
            physicalSuit,
            snap.topStripText,
            snap.suitCornerText,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        if SlotRecognitionDiagnostics.isLoggingEnabled, let tag = slotIndex {
            SlotRecognitionDiagnostics.log(
                """
                OCR[slot \(tag)] row_slice=\(rowSliceColumn) text='\(SlotRecognitionDiagnostics.ellipsis(cornerText, limit: 70))' \
                → rank=\(rank.map(\.rawValue) ?? "?") suit=\(suit.map(\.rawValue) ?? "?") \
                suit_via=\(suitSource?.rawValue ?? "none")
                """
            )
        }

        return Reading(
            cornerText: cornerText,
            rank: rank,
            suit: suit,
            suitSource: suitSource
        )
    }

    private static func containsCourtLetterHint(_ sources: [String]) -> Bool {
        for raw in sources {
            let upper = raw.uppercased()
            if upper.contains("Q") || upper.contains("K") || upper.contains("J") { return true }
        }
        return false
    }

    private static func rankSpecificSuitOCR(
        cardCrop: CGImage,
        rank: Rank,
        rowSliceColumn: Bool,
        slotIndex: Int?
    ) -> String {
        switch rank {
        case .seven:
            return TextRecognition.cornerIndexSuitForRankSeven(
                cardCrop: cardCrop,
                narrowColumn: rowSliceColumn,
                slotIndex: slotIndex
            )
        case .jack, .queen, .king:
            return TextRecognition.cornerIndexSuitForFaceRank(
                cardCrop: cardCrop,
                narrowColumn: rowSliceColumn,
                slotIndex: slotIndex
            )
        default:
            return TextRecognition.physicalSuitGlyphText(
                cardCrop: cardCrop,
                slotIndex: slotIndex,
                rowSliceColumn: rowSliceColumn
            )
        }
    }
}
