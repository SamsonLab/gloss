import GlossCore
import XCTest

@testable import Gloss

final class GlossAppScenarioActivationTests: XCTestCase {
    func testDefaultScenariosStartBrowserAndPDFInfrastructure() {
        let activation = GlossAppScenarioActivation(registry: .current)

        XCTAssertTrue(activation.startsTranslationBridge)
        XCTAssertTrue(activation.preparesBrowserExtensions)
        XCTAssertTrue(activation.preparesPDFRuntime)
        XCTAssertTrue(activation.prewarmsTranslationProvider)
        XCTAssertTrue(activation.acceptsPDFOpenRequests)
        XCTAssertFalse(activation.configuresSystemServices)
        XCTAssertFalse(activation.observesWorkspaceApplications)
    }

    func testBrowserOnlyDoesNotStartPDFInfrastructure() {
        let activation = GlossAppScenarioActivation(
            registry: GlossCapabilityRegistry(
                enabledScenarios: [.browserTranslation]
            )
        )

        XCTAssertTrue(activation.startsTranslationBridge)
        XCTAssertTrue(activation.preparesBrowserExtensions)
        XCTAssertTrue(activation.prewarmsTranslationProvider)
        XCTAssertFalse(activation.preparesPDFRuntime)
        XCTAssertFalse(activation.acceptsPDFOpenRequests)
    }

    func testPDFOnlyStillStartsTranslationBridge() {
        let activation = GlossAppScenarioActivation(
            registry: GlossCapabilityRegistry(
                enabledScenarios: [.pdfTranslation]
            )
        )

        XCTAssertTrue(activation.startsTranslationBridge)
        XCTAssertFalse(activation.preparesBrowserExtensions)
        XCTAssertTrue(activation.preparesPDFRuntime)
        XCTAssertTrue(activation.prewarmsTranslationProvider)
        XCTAssertTrue(activation.acceptsPDFOpenRequests)
    }

    func testNoBusinessScenariosStartNoTranslationServices() {
        let activation = GlossAppScenarioActivation(
            registry: GlossCapabilityRegistry(enabledScenarios: [])
        )

        XCTAssertFalse(activation.startsTranslationBridge)
        XCTAssertFalse(activation.preparesBrowserExtensions)
        XCTAssertFalse(activation.preparesPDFRuntime)
        XCTAssertFalse(activation.prewarmsTranslationProvider)
        XCTAssertFalse(activation.acceptsPDFOpenRequests)
        XCTAssertFalse(activation.configuresSystemServices)
        XCTAssertFalse(activation.observesWorkspaceApplications)
    }

    func testSecondaryScenariosStartOnlyTheirSupportingLifecycleWork() {
        let activation = GlossAppScenarioActivation(
            registry: GlossCapabilityRegistry(
                enabledScenarios: [
                    .clipboardTranslation,
                    .imageTranslation,
                    .selectionTranslation,
                ]
            )
        )

        XCTAssertTrue(activation.configuresSystemServices)
        XCTAssertTrue(activation.observesWorkspaceApplications)
        XCTAssertTrue(activation.prewarmsTranslationProvider)
        XCTAssertFalse(activation.startsTranslationBridge)
        XCTAssertFalse(activation.preparesBrowserExtensions)
        XCTAssertFalse(activation.preparesPDFRuntime)
    }
}
