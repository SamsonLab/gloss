import Foundation
import XCTest

@testable import GlossCore

final class GlossDistributionProfileTests: XCTestCase {
    func testExplicitBundleValueTakesPriority() {
        let profile = GlossDistributionProfile.resolve(
            bundleValue: false,
            executableURL: nil
        )

        XCTAssertFalse(profile.safariExtensionAvailable)
    }

    func testStandaloneHelperReadsEnclosingAppProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "gloss-distribution-test-\(UUID().uuidString)",
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
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: helper.path,
                contents: Data()
            )
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "GlossSafariExtensionAvailable": false
            ],
            format: .xml,
            options: 0
        )
        try plist.write(
            to: contents.appendingPathComponent("Info.plist")
        )

        let profile = GlossDistributionProfile.resolve(
            bundleValue: nil,
            executableURL: helper,
            workingDirectoryURL: root
        )

        XCTAssertFalse(profile.safariExtensionAvailable)
    }

    func testMissingDistributionFlagFailsClosed() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "gloss-missing-distribution-\(UUID().uuidString)",
                isDirectory: true
            )
        let profile = GlossDistributionProfile.resolve(
            bundleValue: nil,
            executableURL: nil,
            workingDirectoryURL: root
        )

        XCTAssertFalse(profile.safariExtensionAvailable)
    }
}
