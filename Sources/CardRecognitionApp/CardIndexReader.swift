import CoreGraphics

/// Rank from index OCR + staged fallbacks; suit from explicit OCR glyphs or icon template match — **never** hue-only guesses (`?` when unknown).
enum CardIndexReader: Sendable {
    enum SuitSource: String, Sendable {
        case ocr
        case indexShape
        case centerShape
        case indexIcon
        case centerIcon
        case pipColor
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
        let mlKitPool = TextRecognition.thirdPartySlotOCR(
            cardCrop: cardCrop,
            slotIndex: slotIndex,
            rowSliceColumn: rowSliceColumn
        )

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

        let dedicatedSuitOCR = dedicatedIndexSuitOCR(
            cardCrop: cardCrop,
            rowSliceColumn: rowSliceColumn,
            slotIndex: slotIndex
        )

        /// Rank from index corner + ML Kit (never from center-pip digit pools on column slices).
        let cornerRankOnlySources = [
            physicalIndex,
            physicalMirror,
            cornerROI,
            rankCorner,
            snap.topStripText,
        ].filter { !$0.isEmpty }

        let cornerRankSources = [mlKitPool] + cornerRankOnlySources

        var rank = CardTextParser.firstRank(cornerSources: cornerRankSources, then: [])

        if rank == nil, containsCourtLetterHint(cornerRankSources + [snap.fullCardText]) {
            let faceText = TextRecognition.cornerIndexSuitForFaceRank(
                cardCrop: cardCrop,
                narrowColumn: rowSliceColumn,
                slotIndex: slotIndex
            )
            rank = CardTextParser.firstRank(cornerSources: [faceText, snap.topStripText], then: [])
        }
        if rank == nil, rowSliceColumn == false {
            rank = CardTextParser.firstRank(
                cornerSources: [snap.fullCardText, snap.pipCentralText],
                then: []
            )
        }
        if rank == nil, rowSliceColumn == false {
            rank = CardTextParser.firstRank(
                cornerSources: [snap.leftBandText, snap.combinedText],
                then: []
            )
        }

        let rankKnown = rank != nil

        var ocrSuitSources = [
            dedicatedSuitOCR,
            physicalSuit,
            physicalIndex,
            physicalMirror,
            suitGlyphROI,
            cornerROI,
            snap.suitCornerText,
            snap.topStripText,
        ]
        ocrSuitSources.insert(mlKitPool, at: 0)
        if rowSliceColumn == false {
            ocrSuitSources.append(contentsOf: [snap.pipCentralText, snap.leftBandText])
        }
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
            slotIndex: slotIndex,
            rankKnown: rankKnown
        ) {
            suit = icon.suit
            suitSource = mapIconMethod(icon.method)
        }

        /// Perspective warps often miss the index stack; one narrow-column OCR pass rescues rank/suit.
        if rowSliceColumn == false, (rank == nil || suit == nil) {
            let rescue = read(
                cardCrop: cardCrop,
                slotIndex: slotIndex,
                rowSliceColumn: true
            )
            if rank == nil { rank = rescue.rank }
            if suit == nil {
                suit = rescue.suit
                suitSource = rescue.suitSource
            }
        }

        let cornerText = [
            physicalIndex,
            physicalSuit,
            snap.topStripText,
            snap.suitCornerText,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        if let tag = slotIndex {
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

    /// Extra OCR passes focused on the index stack + small suit glyph (all ranks).
    private static func dedicatedIndexSuitOCR(
        cardCrop: CGImage,
        rowSliceColumn: Bool,
        slotIndex: Int?
    ) -> String {
        let row = TextRecognition.cornerIndexSuitForRowSlice(
            cardCrop: cardCrop,
            slotIndex: slotIndex
        )
        let stack = TextRecognition.cornerIndexStackText(
            cardCrop: cardCrop,
            slotIndex: slotIndex,
            rowSliceColumn: rowSliceColumn
        )
        return [row, stack].filter { !$0.isEmpty }.joined(separator: " ")
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
            return [
                TextRecognition.physicalSuitGlyphText(
                    cardCrop: cardCrop,
                    slotIndex: slotIndex,
                    rowSliceColumn: rowSliceColumn
                ),
                TextRecognition.cornerSuitGlyphText(
                    cardCrop: cardCrop,
                    slotIndex: slotIndex,
                    rowSliceColumn: rowSliceColumn
                ),
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        }
    }

    private static func mapIconMethod(_ method: SuitIconDetector.Method) -> SuitSource {
        switch method {
        case .ocr: .ocr
        case .indexShape: .indexShape
        case .centerShape: .centerShape
        case .indexIcon: .indexIcon
        case .centerIcon: .centerIcon
        case .pipColor: .pipColor
        }
    }
}
