import CoreGraphics
import XCTest

@testable import GlossOCR

final class OCRTextLayoutTests: XCTestCase {
    func testRestoresReadingOrderAndParagraphBreaks() throws {
        let regions = [
            region("Second line", x: 0.1, y: 0.72),
            region("New paragraph", x: 0.1, y: 0.45),
            region("First line", x: 0.1, y: 0.80),
        ]

        XCTAssertEqual(
            try OCRTextLayout.orderedText(from: regions),
            "First line\nSecond line\n\nNew paragraph"
        )
    }

    func testOrdersRegionsWithinTheSameRowFromLeftToRight() throws {
        let regions = [
            region("right", x: 0.55, y: 0.8),
            region("left", x: 0.1, y: 0.805),
        ]

        XCTAssertEqual(try OCRTextLayout.orderedText(from: regions), "left right")
    }

    func testFiltersBlankAndLowConfidenceRegions() throws {
        let regions = [
            region("kept", x: 0.1, y: 0.8),
            OCRTextRegion(
                text: "noise",
                boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.05),
                confidence: 0.1
            ),
            region("   ", x: 0.1, y: 0.6),
        ]

        XCTAssertEqual(try OCRTextLayout.orderedText(from: regions), "kept")
    }

    func testRejectsOversizedOutput() {
        XCTAssertThrowsError(
            try OCRTextLayout.orderedText(
                from: [region("123456", x: 0.1, y: 0.8)],
                maximumCharacters: 5
            )
        ) { error in
            XCTAssertEqual(error as? OCRError, .tooMuchText(6))
        }
    }

    func testRejectsEmptyOutput() {
        XCTAssertThrowsError(try OCRTextLayout.orderedText(from: [])) { error in
            XCTAssertEqual(error as? OCRError, .noText)
        }
    }

    private func region(_ text: String, x: CGFloat, y: CGFloat) -> OCRTextRegion {
        OCRTextRegion(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: 0.3, height: 0.05),
            confidence: 0.95
        )
    }
}
