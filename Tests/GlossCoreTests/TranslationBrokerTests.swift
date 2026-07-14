import XCTest

@testable import GlossCore

final class TranslationBrokerTests: XCTestCase {
    func testDeduplicatesAndCachesEqualText() async throws {
        let backend = FakeBackend()
        let broker = TranslationBroker(backend: backend)
        let request = TranslationBatchRequest(
            items: [
                TranslationItem(id: "first", text: "hello"),
                TranslationItem(id: "second", text: "hello"),
            ],
            targetLanguage: "Chinese (Simplified)"
        )

        let first = try await broker.translate(request)
        let second = try await broker.translate(
            TranslationBatchRequest(
                items: [TranslationItem(id: "third", text: "hello")],
                targetLanguage: "Chinese (Simplified)"
            )
        )

        XCTAssertEqual(
            first,
            [
                TranslationOutput(id: "first", text: "translated:hello"),
                TranslationOutput(id: "second", text: "translated:hello"),
            ])
        XCTAssertEqual(second, [TranslationOutput(id: "third", text: "translated:hello")])
        let callCount = await backend.callCount()
        let itemCount = await backend.receivedItemCount()
        let cacheCount = await broker.cacheCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(itemCount, 1)
        XCTAssertEqual(cacheCount, 1)
    }

    func testCoalescesConcurrentRequests() async throws {
        let backend = FakeBackend(delayNanoseconds: 120_000_000)
        let broker = TranslationBroker(backend: backend)

        async let first = broker.translateText(
            "shared",
            targetLanguage: "English"
        )
        async let second = broker.translateText(
            "shared",
            targetLanguage: "English"
        )

        let values = try await [first, second]
        XCTAssertEqual(values, ["translated:shared", "translated:shared"])
        let callCount = await backend.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testCacheSeparatesProfilesAndContext() async throws {
        let backend = FakeBackend()
        let broker = TranslationBroker(backend: backend)

        _ = try await broker.translateText(
            "term",
            targetLanguage: "English",
            profile: .natural,
            context: "context one"
        )
        _ = try await broker.translateText(
            "term",
            targetLanguage: "English",
            profile: .technical,
            context: "context one"
        )
        _ = try await broker.translateText(
            "term",
            targetLanguage: "English",
            profile: .natural,
            context: "context two"
        )

        let callCount = await backend.callCount()
        XCTAssertEqual(callCount, 3)
    }

    func testRejectsDuplicateIDs() async throws {
        let broker = TranslationBroker(backend: FakeBackend())
        let request = TranslationBatchRequest(
            items: [
                TranslationItem(id: "same", text: "one"),
                TranslationItem(id: "same", text: "two"),
            ],
            targetLanguage: "English"
        )

        do {
            _ = try await broker.translate(request)
            XCTFail("Expected duplicate id failure")
        } catch let error as TranslationError {
            XCTAssertEqual(error, .duplicateID("same"))
        }
    }

    func testPreservesBatchOrderAndReusesWebpageTextAcrossURLs() async throws {
        let backend = FakeBackend()
        let broker = TranslationBroker(backend: backend)

        _ = try await broker.translate(
            TranslationBatchRequest(
                items: [
                    TranslationItem(id: "second", text: "two"),
                    TranslationItem(id: "first", text: "one"),
                    TranslationItem(id: "duplicate", text: "two"),
                ],
                targetLanguage: "English",
                contentKind: .webpage,
                context: "Website: first.example"
            )
        )
        _ = try await broker.translate(
            TranslationBatchRequest(
                items: [TranslationItem(id: "cached", text: "two")],
                targetLanguage: "English",
                contentKind: .webpage,
                context: "Website: second.example"
            )
        )

        let batches = await backend.receivedBatches()
        XCTAssertEqual(batches, [["two", "one"]])
    }
}

private actor FakeBackend: TranslationBackend {
    private let delayNanoseconds: UInt64
    private var calls = 0
    private var itemCount = 0
    private var batches: [[String]] = []

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func translate(_ request: TranslationBatchRequest) async throws -> [TranslationOutput] {
        calls += 1
        itemCount += request.items.count
        batches.append(request.items.map(\.text))
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return request.items.map {
            TranslationOutput(id: $0.id, text: "translated:\($0.text)")
        }
    }

    func callCount() -> Int {
        calls
    }

    func receivedItemCount() -> Int {
        itemCount
    }

    func receivedBatches() -> [[String]] {
        batches
    }
}
