import AppKit
import XCTest
@testable import Gloss

@MainActor
final class GlossBrandTests: XCTestCase {
    func testMenuHeaderPlacesVersionAfterProductName() {
        let title = GlossBrand.menuHeaderTitle(version: "1.2.3")

        XCTAssertEqual(title.string, "Gloss  v1.2.3")
    }
}
