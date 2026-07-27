import XCTest

@testable import GlossCore

final class GlossCapabilityRegistryTests: XCTestCase {
    func testDefaultRegistryEnablesBrowserAndPDFScenariosOnly() {
        let registry = GlossCapabilityRegistry()

        XCTAssertEqual(
            registry.enabledScenarios,
            [.browserTranslation, .pdfTranslation]
        )
    }

    func testDefaultBrowserScenarioSupportsBothExtensionFamilies() {
        let registry = GlossCapabilityRegistry()

        XCTAssertTrue(registry.supports(.textTranslation))
        XCTAssertTrue(registry.supports(.translationLoopbackBridge))
        XCTAssertTrue(registry.supports(.browserBridge))
        XCTAssertTrue(registry.supports(.chromeExtension))
        XCTAssertTrue(registry.supports(.safariExtension))
    }

    func testDefaultPDFScenarioSupportsRuntimeAndBatchQueue() {
        let registry = GlossCapabilityRegistry()

        XCTAssertTrue(registry.supports(.textTranslation))
        XCTAssertTrue(registry.supports(.documentTranslation))
        XCTAssertTrue(registry.supports(.translationLoopbackBridge))
        XCTAssertTrue(registry.supports(.pdfLayoutAnalysis))
        XCTAssertTrue(registry.supports(.pdfRuntime))
        XCTAssertTrue(registry.supports(.pdfBatchQueue))
        XCTAssertTrue(registry.supports(.pdfExport))
    }

    func testDefaultRegistryKeepsInfrastructureButHidesSecondaryTools() {
        let registry = GlossCapabilityRegistry()

        XCTAssertTrue(registry.supports(.providerConfiguration))
        XCTAssertTrue(registry.supports(.languageConfiguration))
        XCTAssertTrue(registry.supports(.appUpdates))
        XCTAssertTrue(registry.supports(.diagnostics))
        XCTAssertTrue(registry.supports(.launchAtLogin))
        XCTAssertFalse(registry.supports(.clipboardText))
        XCTAssertFalse(registry.supports(.clipboardImage))
        XCTAssertFalse(registry.supports(.screenshotCapture))
        XCTAssertFalse(registry.supports(.selectionCapture))
        XCTAssertFalse(registry.supports(.automaticSelection))
        XCTAssertFalse(registry.supports(.appExclusions))
        XCTAssertFalse(registry.supports(.glossaryManagement))
        XCTAssertFalse(registry.supports(.translationHistory))
    }

    func testSecondaryScenarioCanBeRestoredWithoutChangingTheRegistry() {
        let registry = GlossCapabilityRegistry(
            enabledScenarios: [
                .browserTranslation,
                .pdfTranslation,
                .selectionTranslation,
            ]
        )

        XCTAssertTrue(registry.supports(.selectionCapture))
        XCTAssertTrue(registry.supports(.automaticSelection))
        XCTAssertTrue(registry.supports(.appExclusions))
    }

    func testCoreCapabilitiesAndCommandMappingsAreStable() {
        let registry = GlossCapabilityRegistry()

        XCTAssertEqual(
            registry.enabledCoreCapabilities,
            [
                .browserBridge,
                .chromeExtension,
                .documentTranslation,
                .pdfBatchQueue,
                .pdfExport,
                .pdfLayoutAnalysis,
                .pdfRuntime,
                .safariExtension,
                .textTranslation,
                .translationLoopbackBridge,
            ]
        )
        XCTAssertEqual(
            registry.commandMappings.map(\.command),
            [.capabilities, .text, .browser, .pdf]
        )
        XCTAssertEqual(
            registry.commandMappings.map(\.enabled),
            [true, true, true, true]
        )
        let browser = registry.commandMappings.first {
            $0.command == .browser
        }
        XCTAssertEqual(
            browser?.requiredCapabilities,
            [
                .languageConfiguration,
                .providerConfiguration,
                .textTranslation,
            ]
        )
        XCTAssertEqual(
            browser?.scenarioCapabilities,
            GlossBusinessScenario.browserTranslation.requiredCapabilities.sorted {
                $0.rawValue < $1.rawValue
            }
        )
        let pdf = registry.commandMappings.first {
            $0.command == .pdf
        }
        XCTAssertEqual(pdf?.scenario, .pdfTranslation)
        XCTAssertEqual(
            pdf?.requiredCapabilities,
            GlossBusinessScenario.pdfTranslation.requiredCapabilities.sorted {
                $0.rawValue < $1.rawValue
            }
        )
        XCTAssertEqual(
            pdf?.scenarioCapabilities,
            pdf?.requiredCapabilities
        )
    }
}
