import Foundation
import XCTest

@testable import GlossCore

final class GlossRuntimeLogTests: XCTestCase {
    func testWritesPrivateStructuredAndCodexLogs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-log-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = GlossRuntimeLog(directory: directory)

        try log.prepare()
        log.write("bridge", "health status=200\nnext")
        log.appendCodexStderr(Data("codex diagnostic\n".utf8))

        let structured = try String(
            contentsOf: directory.appendingPathComponent("gloss.log"),
            encoding: .utf8
        )
        XCTAssertTrue(structured.contains("[bridge] health status=200\\nnext"))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("codex-stderr.log")),
            Data("codex diagnostic\n".utf8)
        )

        let directoryMode = try permissions(at: directory)
        let logMode = try permissions(at: directory.appendingPathComponent("gloss.log"))
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(logMode, 0o600)
    }

    func testRotatesStructuredLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-log-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = GlossRuntimeLog(directory: directory, maximumBytes: 1_024)

        log.write("test", String(repeating: "a", count: 900))
        log.write("test", String(repeating: "b", count: 900))

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("gloss.log.1").path
            )
        )
        let current = try String(
            contentsOf: directory.appendingPathComponent("gloss.log"),
            encoding: .utf8
        )
        XCTAssertTrue(current.contains(String(repeating: "b", count: 100)))
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
