import Foundation
import XCTest

@testable import GlossCore

final class TranslationHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlossHistoryTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("history.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPersistsNewestFirstAndHonorsLimit() async throws {
        let store = TranslationHistoryStore(fileURL: fileURL, limit: 2)
        try await store.record(entry("one", at: 1))
        try await store.record(entry("two", at: 2))
        try await store.record(entry("three", at: 3))

        let reloaded = TranslationHistoryStore(fileURL: fileURL, limit: 2)
        let entries = try await reloaded.entries()
        XCTAssertEqual(entries.map(\.sourceText), ["three", "two"])
    }

    func testSkipsConsecutiveDuplicate() async throws {
        let store = TranslationHistoryStore(fileURL: fileURL)
        try await store.record(entry("same", at: 1))
        try await store.record(entry("same", at: 2))

        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 1)
    }

    func testDeleteClearAndPrivatePermissions() async throws {
        let store = TranslationHistoryStore(fileURL: fileURL)
        let first = entry("first", at: 1)
        try await store.record(first)
        try await store.record(entry("second", at: 2))

        try await store.delete(id: first.id)
        let remaining = try await store.entries()
        XCTAssertEqual(remaining.map(\.sourceText), ["second"])

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try await store.clear()
        let cleared = try await store.entries()
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRecoversFromUnreadableHistory() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)
        let store = TranslationHistoryStore(fileURL: fileURL)

        let entries = try await store.entries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let archived = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(archived.count, 1)
        XCTAssertTrue(archived[0].hasPrefix("history.unreadable-"))
    }

    private func entry(_ source: String, at time: TimeInterval) -> TranslationHistoryEntry {
        TranslationHistoryEntry(
            createdAt: Date(timeIntervalSince1970: time),
            sourceText: source,
            translatedText: "translated:\(source)",
            sourceName: "Tests",
            targetLanguage: "English",
            profile: .natural,
            contentKind: .selection
        )
    }
}
