import XCTest

@testable import GlossCore

final class CodexAppServerClientTests: XCTestCase {
    func testUsesFastTranslationModelByDefault() async {
        let client = CodexAppServerClient(environment: [:])

        let status = await client.status()

        XCTAssertEqual(status.model, "gpt-5.3-codex-spark")
    }

    func testModelCanBeOverridden() async {
        let client = CodexAppServerClient(
            environment: ["GLOSS_CODEX_MODEL": "custom-model"]
        )

        let status = await client.status()

        XCTAssertEqual(status.model, "custom-model")
    }
}
