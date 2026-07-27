import Foundation
import XCTest

@testable import GlossCore

final class BabelDOCRuntimeCompatibilityTests: XCTestCase {
    func testMinimumCompatibleManagedRuntimeVersion() {
        XCTAssertFalse(
            BabelDOCRuntimeCompatibility.isCompatible(
                "0.6.4+gloss.4"
            )
        )
        XCTAssertTrue(
            BabelDOCRuntimeCompatibility.isCompatible(
                "0.6.4+gloss.5"
            )
        )
        XCTAssertTrue(
            BabelDOCRuntimeCompatibility.isCompatible(
                "0.6.5+gloss.1"
            )
        )
        XCTAssertTrue(
            BabelDOCRuntimeCompatibility.isCompatible(
                "0.6.5"
            )
        )
    }

    func testUnprovenRuntimeVersionsFailClosed() {
        let unprovenVersions: [String?] = [
            nil,
            "",
            "0.6.4",
            "0.6.4+gloss.05",
            "0.6.4+gloss.5-dev",
            "0.6.4+gloss.5.1",
            "0.6.4+other.9",
            "not-a-version",
        ]

        for version in unprovenVersions {
            XCTAssertFalse(
                BabelDOCRuntimeCompatibility.isCompatible(version),
                "\(version ?? "nil") should not be trusted"
            )
        }
    }

    func testStandaloneHelperResolvesEnclosingAppVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "gloss-version-test-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent(
            "Gloss.app/Contents",
            isDirectory: true
        )
        let helper = contents.appendingPathComponent(
            "Helpers/gloss-cli"
        )
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleShortVersionString": "9.8.7"
            ],
            format: .xml,
            options: 0
        )
        try plist.write(
            to: contents.appendingPathComponent("Info.plist")
        )

        XCTAssertEqual(
            GlossProductVersionResolver.resolve(
                bundleVersion: nil,
                executableURL: helper,
                workingDirectoryURL: root
            ),
            "9.8.7"
        )
    }

    func testDevelopmentCheckoutResolvesResourcesPlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "gloss-checkout-version-test-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent(
            "Resources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleShortVersionString": "1.2.3"
            ],
            format: .xml,
            options: 0
        )
        try plist.write(
            to: resources.appendingPathComponent("Info.plist")
        )

        XCTAssertEqual(
            GlossProductVersionResolver.resolve(
                bundleVersion: nil,
                executableURL: nil,
                workingDirectoryURL: root
            ),
            "1.2.3"
        )
    }
}
