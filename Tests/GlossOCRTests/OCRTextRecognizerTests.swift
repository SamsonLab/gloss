import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import GlossOCR

final class OCRTextRecognizerTests: XCTestCase {
    func testRecognizesRenderedTextWithVision() async throws {
        guard ProcessInfo.processInfo.environment["GLOSS_RUN_VISION_TESTS"] == "1" else {
            throw XCTSkip("Set GLOSS_RUN_VISION_TESTS=1 to run the macOS Vision integration test.")
        }
        let text = try await OCRTextRecognizer.recognize(renderedTextImage())

        XCTAssertTrue(
            text.localizedCaseInsensitiveContains("Hello Gloss"),
            "Unexpected OCR output: \(text)"
        )
    }

    private func renderedTextImage() -> CGImage {
        let width = 1_200
        let height = 300
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 112, nil)
        let attributes =
            [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
            ] as CFDictionary
        let attributedText = CFAttributedStringCreate(
            nil,
            "Hello Gloss" as CFString,
            attributes
        )!
        let line = CTLineCreateWithAttributedString(attributedText)
        context.textPosition = CGPoint(x: 60, y: 90)
        CTLineDraw(line, context)

        return context.makeImage()!
    }
}
