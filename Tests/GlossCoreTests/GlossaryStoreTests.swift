import Foundation
import XCTest

@testable import GlossCore

final class GlossaryStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlossGlossaryTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("glossary.tsv")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPersistsSimpleTSVWithPrivatePermissions() async throws {
        let store = GlossaryStore(fileURL: fileURL)
        let terms = [
            GlossaryTerm(source: "Gloss", target: "Gloss"),
            GlossaryTerm(source: "workflow", target: "工作流"),
        ]
        try await store.replace(with: terms)

        let reloaded = GlossaryStore(fileURL: fileURL)
        let reloadedTerms = try await reloaded.terms()
        XCTAssertEqual(reloadedTerms, terms)
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "Gloss\tGloss\nworkflow\t工作流\n"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMatchesOnlyPresentTermsCaseInsensitivelyAndLongestFirst() async throws {
        let store = GlossaryStore(fileURL: fileURL)
        try await store.replace(with: [
            GlossaryTerm(source: "flow", target: "流"),
            GlossaryTerm(source: "workflow", target: "工作流"),
            GlossaryTerm(source: "missing", target: "不应发送"),
        ])

        let matched = try await store.matchingTerms(
            in: ["A reliable WORKFLOW keeps the flow clear."]
        )
        XCTAssertEqual(matched.map(\.source), ["workflow", "flow"])
    }

    func testRejectsDuplicateAndMalformedTerms() async throws {
        let store = GlossaryStore(fileURL: fileURL)
        do {
            try await store.replace(with: [
                GlossaryTerm(source: "Gloss", target: "one"),
                GlossaryTerm(source: "gloss", target: "two"),
            ])
            XCTFail("Expected duplicate source rejection")
        } catch let error as GlossaryError {
            XCTAssertEqual(error, .duplicateSource("gloss"))
        }

        do {
            try await store.replace(with: [GlossaryTerm(source: "bad\nterm", target: "value")])
            XCTFail("Expected invalid term rejection")
        } catch let error as GlossaryError {
            XCTAssertEqual(error, .invalidTerm(1))
        }
    }

    func testArchivesUnreadableTSV() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("missing-tab".utf8).write(to: fileURL)
        let store = GlossaryStore(fileURL: fileURL)

        let terms = try await store.terms()
        XCTAssertTrue(terms.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let archived = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(archived.count, 1)
        XCTAssertTrue(archived[0].hasPrefix("glossary.unreadable-"))
    }
}
