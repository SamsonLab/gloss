import GlossCore
import XCTest

@testable import Gloss

final class PDFTranslationToolCopyTests: XCTestCase {
    func testOutputDescriptionsMatchMonoAndDualModes() {
        XCTAssertEqual(
            PDFTranslationToolCopy.outputDescription(for: .monolingual),
            "仅输出译文 PDF，文件更轻，适合直接阅读。"
        )
        XCTAssertEqual(
            PDFTranslationToolCopy.outputDescription(for: .bilingual),
            "保留原文与译文对照，适合核对内容。"
        )
    }

    func testOutputSuffixesKeepSingleSelectedPDFMode() {
        XCTAssertEqual(
            PDFTranslationToolCopy.outputSuffix(for: .monolingual),
            "-gloss-mono.pdf"
        )
        XCTAssertEqual(
            PDFTranslationToolCopy.outputSuffix(for: .bilingual),
            "-gloss-dual.pdf"
        )
    }

    func testOutputFileNameUsesSourceNameAndSelectedMode() {
        let sourceURL = URL(fileURLWithPath: "/tmp/attention-is-all-you-need.pdf")

        XCTAssertEqual(
            PDFTranslationToolCopy.outputFileName(
                for: sourceURL,
                outputMode: .monolingual
            ),
            "attention-is-all-you-need-gloss-mono.pdf"
        )
    }
}
