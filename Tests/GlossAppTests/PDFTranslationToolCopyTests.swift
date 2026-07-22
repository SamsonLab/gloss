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

    func testTimingDescriptionIncludesPreparationAndSavePhases() {
        let description = PDFTranslationToolCopy.timingDescription(
            timings: BabelDOCPhaseTimings(
                launchingMilliseconds: 15_550,
                parsingMilliseconds: 11_210,
                translatingMilliseconds: 1_168,
                typesettingMilliseconds: 2_509,
                savingMilliseconds: 8_013
            ),
            performance: .init()
        )

        XCTAssertEqual(
            description,
            "准备 15.6s · 解析 11.2s · 翻译 1.2s · 排版 2.5s · 保存 8.0s"
        )
    }

    func testTimingDescriptionLabelsCumulativeModelWait() {
        let description = PDFTranslationToolCopy.timingDescription(
            timings: BabelDOCPhaseTimings(
                launchingMilliseconds: 14_400,
                parsingMilliseconds: 15_000,
                translatingMilliseconds: 40_360
            ),
            performance: .init(
                completedTurns: 33,
                modelWaitMilliseconds: 59_840
            )
        )

        XCTAssertEqual(
            description,
            "准备 14.4s · 解析 15.0s · 模型等待累计 59.8s"
        )
    }

    func testTimingDescriptionFallsBackToElapsedTime() {
        XCTAssertEqual(
            PDFTranslationToolCopy.timingDescription(
                timings: .init(),
                performance: .init(),
                elapsedMilliseconds: 2_345
            ),
            "已用时 2.3s"
        )
    }
}
