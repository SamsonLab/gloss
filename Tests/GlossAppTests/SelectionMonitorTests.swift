import AppKit
import XCTest
@testable import Gloss

@MainActor
final class SelectionMonitorTests: XCTestCase {
    func testEscapeDismissesSelectionUI() {
        var dismissCount = 0
        let monitor = SelectionMonitor(
            onSelection: { _ in },
            onDismiss: { dismissCount += 1 },
            shouldIgnorePoint: { _ in false },
            shouldCaptureAutomatically: { _ in false },
            globalShortcut: .defaultValue
        )

        monitor.handleEvent(
            type: .keyDown,
            location: .zero,
            flags: [],
            clickCount: 0,
            keyCode: 1
        )
        let beforeEscape = dismissCount

        monitor.handleEvent(
            type: .keyDown,
            location: .zero,
            flags: [],
            clickCount: 0,
            keyCode: 53
        )
        let afterEscape = dismissCount

        XCTAssertEqual(beforeEscape, 0)
        XCTAssertEqual(afterEscape, 1)
    }
}
