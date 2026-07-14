import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Gloss

@MainActor
final class ScreenshotCaptureTests: XCTestCase {
    func testLoadsCapturedPNG() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GlossScreenshotTests-\(UUID().uuidString).png"
        )
        defer { try? FileManager.default.removeItem(at: file) }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 3,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                file as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let loaded = try ScreenshotCapture.loadImage(at: file)
        XCTAssertEqual(loaded.width, 2)
        XCTAssertEqual(loaded.height, 3)
    }

    func testRejectsUnreadableCapture() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GlossScreenshotTests-\(UUID().uuidString).png"
        )
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not an image".utf8).write(to: file)

        XCTAssertThrowsError(try ScreenshotCapture.loadImage(at: file)) { error in
            XCTAssertEqual(error as? ScreenshotCaptureError, .unreadable)
        }
    }
}
