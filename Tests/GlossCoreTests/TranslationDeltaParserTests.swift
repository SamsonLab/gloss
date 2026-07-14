import XCTest

@testable import GlossCore

final class TranslationDeltaParserTests: XCTestCase {
    func testEmitsEachCompleteItemWithoutWaitingForEnvelope() {
        var parser = TranslationDeltaParser()

        XCTAssertEqual(parser.append("{\"translations\":[{\"id\":\"one\",\"index\":0,\"text\":\"你"), [])
        XCTAssertEqual(
            parser.append("好\"},{\"id\":\"two\",\"index\":1,\"text\":\"世"),
            [TranslationDeltaParser.Item(id: "one", index: 0, text: "你好")]
        )
        XCTAssertEqual(
            parser.append("界\"}]}"),
            [TranslationDeltaParser.Item(id: "two", index: 1, text: "世界")]
        )
    }

    func testHandlesEscapedQuotesAndNestedBracesInText() {
        var parser = TranslationDeltaParser()
        let output = parser.append(
            #"{"translations":[{"id":"one","index":0,"text":"say \"{yes}\""}]}"#
        )

        XCTAssertEqual(
            output,
            [TranslationDeltaParser.Item(id: "one", index: 0, text: "say \"{yes}\"")]
        )
    }
}
