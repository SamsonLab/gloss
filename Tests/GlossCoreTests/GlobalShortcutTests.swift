import CoreGraphics
import Foundation
import XCTest
@testable import GlossCore

final class GlobalShortcutTests: XCTestCase {
    func testDefaultShortcutMatchesWhileIgnoringUnrelatedFlags() {
        let shortcut = GlobalShortcut.defaultValue

        XCTAssertTrue(
            shortcut.matches(
                keyCode: 5,
                modifiers: shortcut.modifiers | CGEventFlags.maskAlphaShift.rawValue
            )
        )
        XCTAssertFalse(shortcut.matches(keyCode: 4, modifiers: shortcut.modifiers))
        XCTAssertFalse(
            shortcut.matches(
                keyCode: 5,
                modifiers: shortcut.modifiers | CGEventFlags.maskShift.rawValue
            )
        )
    }

    func testRejectsShortcutWithoutPrimaryModifier() {
        XCTAssertNil(GlobalShortcut(keyCode: 5, modifiers: 0, keyLabel: "G"))
        XCTAssertNil(
            GlobalShortcut(
                keyCode: 5,
                modifiers: CGEventFlags.maskShift.rawValue,
                keyLabel: "G"
            )
        )
        XCTAssertNil(
            GlobalShortcut(
                keyCode: 5,
                modifiers: CGEventFlags.maskCommand.rawValue,
                keyLabel: "G"
            )
        )
    }

    func testDisplaysModifiersInStableMacOrder() throws {
        let shortcut = try XCTUnwrap(
            GlobalShortcut(
                keyCode: 5,
                modifiers: CGEventFlags.maskCommand.rawValue
                    | CGEventFlags.maskShift.rawValue
                    | CGEventFlags.maskControl.rawValue,
                keyLabel: "G"
            )
        )

        XCTAssertEqual(shortcut.displayName, "⌃⇧⌘G")
    }

    func testPersistsAndRejectsInvalidStoredValue() throws {
        let suiteName = "GlobalShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = try XCTUnwrap(
            GlobalShortcut(
                keyCode: 40,
                modifiers: CGEventFlags.maskControl.rawValue
                    | CGEventFlags.maskAlternate.rawValue,
                keyLabel: "K"
            )
        )

        shortcut.save(to: defaults)
        XCTAssertEqual(GlobalShortcut.load(from: defaults), shortcut)

        defaults.set(
            ["keyCode": 40, "modifiers": 0, "keyLabel": "K"],
            forKey: "globalShortcut"
        )
        XCTAssertEqual(GlobalShortcut.load(from: defaults), .defaultValue)
    }
}
