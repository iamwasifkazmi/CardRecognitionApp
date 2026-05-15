import Foundation

/// Combines several live-camera `ScanResult`s so a single bad frame (moire, refresh, motion) does not dominate.
enum CameraMultiSampleConsensus: Sendable {
    static func merge(samples: [CardVisionPipeline.ScanResult]) -> CardVisionPipeline.ScanResult {
        guard samples.isEmpty == false else {
            return CardVisionPipeline.ScanResult(cards: [])
        }
        let maxSlots = samples.map(\.cards.count).max() ?? 0
        guard maxSlots > 0 else {
            return CardVisionPipeline.ScanResult(cards: [])
        }
        var merged: [RecognizedPlayingCard] = []
        merged.reserveCapacity(maxSlots)
        for slot in 0 ..< maxSlots {
            let readings = samples.compactMap { sample -> RecognizedPlayingCard? in
                guard slot < sample.cards.count else { return nil }
                return sample.cards[slot]
            }
            merged.append(mergeSlot(readings: readings))
        }
        return CardVisionPipeline.ScanResult(cards: merged)
    }

    private static func mergeSlot(readings: [RecognizedPlayingCard]) -> RecognizedPlayingCard {
        guard readings.isEmpty == false else {
            return RecognizedPlayingCard()
        }

        /// LCD moiré often yields all-`?` frames; a single steady frame can carry the true index. Drop pure empties when any slot had signal.
        let pool: [RecognizedPlayingCard] = {
            let nonEmpty = readings.filter { r in
                r.rank != nil || r.suit != nil || r.confidence >= 0.035
            }
            return nonEmpty.isEmpty ? readings : nonEmpty
        }()

        guard pool.isEmpty == false else {
            return RecognizedPlayingCard()
        }

        struct Signature: Hashable {
            let rank: Rank?
            let suit: Suit?
        }
        var tallies: [Signature: (count: Int, confidenceSum: Float, best: RecognizedPlayingCard)] = [:]
        for card in pool {
            let sig = Signature(rank: card.rank, suit: card.suit)
            var entry = tallies[sig] ?? (count: 0, confidenceSum: 0, best: card)
            entry.count += 1
            entry.confidenceSum += card.confidence
            if card.confidence > entry.best.confidence {
                entry.best = card
            }
            tallies[sig] = entry
        }
        guard let chosen = tallies.max(by: { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            return lhs.value.confidenceSum < rhs.value.confidenceSum
        }) else {
            return RecognizedPlayingCard()
        }
        let sig = chosen.key
        let tally = chosen.value
        let agreement = Float(tally.count) / Float(pool.count)
        let avgConf = tally.confidenceSum / Float(tally.count)
        let mergedConf = min(1, avgConf * (0.55 + 0.45 * agreement))

        let header = "Live camera ▸ merged \(readings.count) frames (\(pool.count) informative), \(tally.count)× this rank/suit"
        let diagnosis: String
        if tally.best.diagnosis.isEmpty {
            diagnosis = header
        } else {
            diagnosis = "\(header)\n\(tally.best.diagnosis)"
        }

        return RecognizedPlayingCard(
            rank: sig.rank,
            suit: sig.suit,
            confidence: mergedConf,
            diagnosis: diagnosis
        )
    }
}
