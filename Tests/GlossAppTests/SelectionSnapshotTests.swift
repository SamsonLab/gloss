import AppKit
import XCTest
@testable import Gloss

@MainActor
final class SelectionSnapshotTests: XCTestCase {
    func testReplacementAvailabilityIncludesClipboardFallback() {
        let unavailable = makeSelection(isEditable: false, processIdentifier: nil).canReplace
        let directlyEditable = makeSelection(isEditable: true, processIdentifier: nil).canReplace
        let clipboardFallback = makeSelection(isEditable: false, processIdentifier: 42).canReplace

        XCTAssertFalse(unavailable)
        XCTAssertTrue(directlyEditable)
        XCTAssertTrue(clipboardFallback)
    }

    private func makeSelection(
        isEditable: Bool,
        processIdentifier: pid_t?
    ) -> SelectionSnapshot {
        SelectionSnapshot(
            text: "Text",
            surroundingContext: nil,
            applicationName: "Test",
            bundleIdentifier: "com.example.test",
            processIdentifier: processIdentifier,
            element: nil,
            isEditable: isEditable,
            anchor: .zero
        )
    }
}
