import Foundation
import XCTest
@testable import Gloss

final class BrowserExtensionFilesTests: XCTestCase {
    func testContentsMatchIgnoresMarkerAndDetectsChangedOrExtraFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-extension-test-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("manifest".utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("script".utf8).write(to: source.appendingPathComponent("nested/script.js"))
        try Data("manifest".utf8).write(to: destination.appendingPathComponent("manifest.json"))
        try Data("script".utf8).write(to: destination.appendingPathComponent("nested/script.js"))
        try Data("managed".utf8).write(to: destination.appendingPathComponent(".gloss-managed"))

        XCTAssertTrue(try BrowserExtensionFiles.contentsMatch(source: source, destination: destination))

        try Data("changed".utf8).write(to: destination.appendingPathComponent("nested/script.js"))
        XCTAssertFalse(try BrowserExtensionFiles.contentsMatch(source: source, destination: destination))

        try Data("script".utf8).write(to: destination.appendingPathComponent("nested/script.js"))
        try Data("extra".utf8).write(to: destination.appendingPathComponent("extra.js"))
        XCTAssertFalse(try BrowserExtensionFiles.contentsMatch(source: source, destination: destination))
    }

    func testContentsMatchAcceptsOnlyTheExpectedGeneratedPairingConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-pairing-test-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try Data("manifest".utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("manifest".utf8).write(to: destination.appendingPathComponent("manifest.json"))
        try Data("globalThis.GLOSS_PAIRING_TOKEN = \"\";\n".utf8).write(
            to: source.appendingPathComponent("gloss-config.js")
        )
        try BrowserExtensionFiles.pairingConfiguration(for: "expected-token").write(
            to: destination.appendingPathComponent("gloss-config.js")
        )
        try Data("managed".utf8).write(to: destination.appendingPathComponent(".gloss-managed"))

        XCTAssertTrue(
            try BrowserExtensionFiles.contentsMatch(
                source: source,
                destination: destination,
                pairingToken: "expected-token"
            )
        )
        XCTAssertFalse(
            try BrowserExtensionFiles.contentsMatch(
                source: source,
                destination: destination,
                pairingToken: "different-token"
            )
        )
        XCTAssertFalse(try BrowserExtensionFiles.contentsMatch(source: source, destination: destination))
    }

    func testPairingConfigurationEscapesJavaScriptStringContent() throws {
        let token = "quote: \" and newline:\n"
        let configuration = try BrowserExtensionFiles.pairingConfiguration(for: token)
        let script = try XCTUnwrap(String(data: configuration, encoding: .utf8))
        let prefix = "globalThis.GLOSS_PAIRING_TOKEN = "
        let suffix = ";\n"

        XCTAssertTrue(script.hasPrefix(prefix))
        XCTAssertTrue(script.hasSuffix(suffix))
        let literal = script.dropFirst(prefix.count).dropLast(suffix.count)
        let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        XCTAssertEqual(decoded, token)
    }
}
