import Testing
@testable import CardRecognitionApp

@Suite("Card parsers")
struct CardRecognitionParserTests {
    @Test(arguments: ["10♠", "10 ♠"])
    func parseTenOfSpades(_ text: String) {
        let rank = CardTextParser.parseRank(from: text)
        let suit = CardTextParser.parseSuit(from: text)
        #expect(rank == .ten)
        #expect(suit == .spades)
    }

    @Test(arguments: ["A♥", "\nAce hearts\n"])
    func aceOfHeartsVariants(_ raw: String) {
        let rank = CardTextParser.parseRank(from: raw)
        let suit = CardTextParser.parseSuit(from: raw)
        #expect(rank == .ace)
        #expect(suit == .hearts)
    }

    @Test
    func letterAndWordSuits() {
        let text = "| K c | diamond |"
        #expect(CardTextParser.parseRank(from: text) == .king)
        #expect(CardTextParser.parseSuit(from: "| c |") == .clubs)
        #expect(CardTextParser.parseSuit(from: "| d |") == .diamonds)
    }

    @Test
    func queenViaWords() {
        let combo = "Queen SPADES text"
        #expect(CardTextParser.parseRank(from: combo) == .queen)
        #expect(CardTextParser.parseSuit(from: combo) == .spades)
    }

    @Test
    func visionPipelineReturnsFiveCards() throws {
        let raster = RasterFixture.makeCheckerboard()
        let snapshot = try CardVisionPipeline.analyze(cgImage: raster)
        #expect(snapshot.cards.count == 5)
    }
}

#if os(iOS)
import UIKit

private enum RasterFixture {
    static func makeCheckerboard(width: CGFloat = 480, height: CGFloat = 360) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }
        guard let cg = image.cgImage else {
            preconditionFailure("Could not rasterize UIImage placeholder")
        }
        return cg
    }
}
#elseif os(macOS)
import AppKit

private enum RasterFixture {
    static func makeCheckerboard(width: CGFloat = 480, height: CGFloat = 360) -> CGImage {
        let image = NSImage(size: CGSize(width: width, height: height))
        image.lockFocus()
        NSColor.gray.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        image.unlockFocus()
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cg = bitmap.cgImage
        else {
            preconditionFailure("Could not synthesize raster on macOS tests")
        }
        return cg
    }
}
#else
private enum RasterFixture {
    static func makeCheckerboard(width _: CGFloat = 480, height _: CGFloat = 360) -> CGImage {
        preconditionFailure("Golden raster synthesis is wired for Darwin targets only.")
    }
}
#endif
