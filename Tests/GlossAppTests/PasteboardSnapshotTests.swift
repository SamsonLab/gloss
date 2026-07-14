import AppKit
import XCTest
@testable import Gloss

@MainActor
final class PasteboardSnapshotTests: XCTestCase {
    func testRestoresMultipleItemsAndTypes() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("com.gloss.tests.custom")
        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        first.setData(Data([1, 2, 3]), forType: customType)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        let snapshot = try XCTUnwrap(PasteboardSnapshot(pasteboard))

        pasteboard.clearContents()
        pasteboard.setString("replacement", forType: .string)
        XCTAssertTrue(snapshot.restore(to: pasteboard))

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "first")
        XCTAssertEqual(items[0].data(forType: customType), Data([1, 2, 3]))
        XCTAssertEqual(items[1].string(forType: .string), "second")
    }

    func testRejectsProtectedClipboardMarkers() {
        for typeName in [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "com.agilebits.onepassword",
            "com.apple.pasteboard.promised-file-url",
        ] {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            let item = NSPasteboardItem()
            item.setString("protected", forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType(typeName))
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([item]))

            XCTAssertNil(PasteboardSnapshot(pasteboard), typeName)
        }
    }

    func testRejectsTooManyClipboardItems() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let items = (0...64).map { index -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(String(index), forType: .string)
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))

        XCTAssertNil(PasteboardSnapshot(pasteboard))
    }

    func testProtectedTextIsMarkedAndCannotBeSnapshotted() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        XCTAssertNotNil(PasteboardPrivacy.writeProtectedText("secret", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "secret")
        let types = Set(try XCTUnwrap(pasteboard.pasteboardItems?.first).types.map(\.rawValue))
        XCTAssertTrue(types.contains("org.nspasteboard.ConcealedType"))
        XCTAssertTrue(types.contains("org.nspasteboard.TransientType"))
        XCTAssertNil(PasteboardSnapshot(pasteboard))
    }

    func testRestoresAnEmptyClipboard() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let snapshot = try XCTUnwrap(PasteboardSnapshot(pasteboard))
        pasteboard.setString("temporary", forType: .string)

        XCTAssertTrue(snapshot.restore(to: pasteboard))
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("GlossTests.\(UUID().uuidString)"))
    }
}
