import Foundation
import XCTest

@testable import GlossCore

final class DocumentTranslationTests: XCTestCase {
    func testSegmenterJoinsVisualLinesAndPreservesParagraphs() {
        let blocks = DocumentBlockSegmenter.blocks(
            from: """
                This is a visual line that contin-
                ues on the next line.

                This is a second paragraph.
                """,
            pageIndex: 2
        )

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(
            blocks[0].sourceText,
            "This is a visual line that continues on the next line."
        )
        XCTAssertEqual(blocks[0].pageIndex, 2)
        XCTAssertEqual(blocks[0].blockIndex, 0)
        XCTAssertTrue(blocks[0].id.hasPrefix("p3-b1-"))
        XCTAssertEqual(blocks[1].sourceText, "This is a second paragraph.")
    }

    func testSegmenterBoundsLongParagraphs() {
        let source = Array(repeating: "translation", count: 150).joined(separator: " ")
        let blocks = DocumentBlockSegmenter.blocks(
            from: source,
            pageIndex: 0,
            maximumCharacters: 240
        )

        XCTAssertGreaterThan(blocks.count, 1)
        XCTAssertTrue(blocks.allSatisfy { $0.sourceText.count <= 240 })
        XCTAssertEqual(
            blocks.map(\.sourceText).joined(separator: " "),
            source
        )
    }

    func testPositionedSegmenterUsesVerticalGapsAndListMarkers() {
        let lines = [
            DocumentLine(
                text: "1. Who we are",
                bounds: CGRect(x: 40, y: 700, width: 180, height: 14)
            ),
            DocumentLine(
                text: "This policy explains how Gloss handles",
                bounds: CGRect(x: 60, y: 680, width: 300, height: 14)
            ),
            DocumentLine(
                text: "documents on your Mac.",
                bounds: CGRect(x: 60, y: 663, width: 220, height: 14)
            ),
            DocumentLine(
                text: "2. What we store",
                bounds: CGRect(x: 40, y: 625, width: 180, height: 14)
            ),
        ]

        let blocks = DocumentBlockSegmenter.blocks(from: lines, pageIndex: 0)

        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].sourceText, "1. Who we are")
        XCTAssertEqual(
            blocks[1].sourceText,
            "This policy explains how Gloss handles documents on your Mac."
        )
        XCTAssertEqual(blocks[1].boundingRects.count, 2)
        XCTAssertEqual(blocks[2].sourceText, "2. What we store")
    }

    func testDocumentDigestIsDeterministic() {
        XCTAssertEqual(
            DocumentDigest.text("Gloss"),
            DocumentDigest.text("Gloss")
        )
        XCTAssertNotEqual(
            DocumentDigest.text("Gloss"),
            DocumentDigest.text("gloss")
        )
    }

    func testDocumentTranslationStorePersistsByProviderRevision() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("document-translations.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstKey = DocumentTranslationCacheKey(
            documentDigest: "document",
            pageIndex: 0,
            blockIndex: 0,
            sourceDigest: "source",
            targetLanguage: "Chinese (Simplified)",
            profile: .academic,
            providerRevision: "revision-a"
        )
        let secondKey = DocumentTranslationCacheKey(
            documentDigest: "document",
            pageIndex: 0,
            blockIndex: 0,
            sourceDigest: "source",
            targetLanguage: "Chinese (Simplified)",
            profile: .academic,
            providerRevision: "revision-b"
        )

        let writer = DocumentTranslationStore(fileURL: fileURL)
        try await writer.record([firstKey: "第一版"])

        let reader = DocumentTranslationStore(fileURL: fileURL)
        let values = try await reader.values(for: [firstKey, secondKey])
        XCTAssertEqual(values[firstKey], "第一版")
        XCTAssertNil(values[secondKey])
    }
}
