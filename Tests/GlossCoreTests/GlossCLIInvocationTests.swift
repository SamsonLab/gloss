import Foundation
import XCTest

@testable import GlossCore

final class GlossCLIInvocationTests: XCTestCase {
    func testLegacyFlatTextInvocationRemainsCompatible() throws {
        let invocation = try GlossCLIInvocationParser.parse([
            "--target", "Japanese",
            "--profile", "technical",
            "Hello", "world",
        ])
        guard case .legacyText(let options) = invocation else {
            return XCTFail("Expected legacy text invocation")
        }

        XCTAssertEqual(options.targetLanguage, "Japanese")
        XCTAssertEqual(options.profile, .technical)
        XCTAssertEqual(options.contentKind, .selection)
        XCTAssertEqual(options.textParts, ["Hello", "world"])
    }

    func testBrowserCommandMapsToWebpageScenario() throws {
        let invocation = try GlossCLIInvocationParser.parse([
            GlossCLICommand.browser.rawValue,
            "--provider", "llama",
            "Browser text",
        ])
        guard case .browser(let options) = invocation else {
            return XCTFail("Expected browser invocation")
        }

        XCTAssertEqual(options.contentKind, .webpage)
        XCTAssertEqual(options.provider, .llama)
        XCTAssertEqual(options.textParts, ["Browser text"])
    }

    func testExplicitTextCommandMapsToCoreTranslationCapability() throws {
        let invocation = try GlossCLIInvocationParser.parse([
            GlossCLICommand.text.rawValue,
            "--kind", "document",
            "Document text",
        ])
        guard case .text(let options) = invocation else {
            return XCTFail("Expected text invocation")
        }

        XCTAssertEqual(options.contentKind, .document)
        XCTAssertEqual(options.textParts, ["Document text"])
    }

    func testBrowserRejectsNonWebpageKind() {
        XCTAssertThrowsError(
            try GlossCLIInvocationParser.parse([
                GlossCLICommand.browser.rawValue,
                "--kind", "selection",
                "Text",
            ])
        )
    }

    func testPDFCommandAcceptsBatchAndUsesDocumentDefaults() throws {
        let invocation = try GlossCLIInvocationParser.parse([
            GlossCLICommand.pdf.rawValue,
            "one.pdf",
            "two.pdf",
            "--output", "/tmp/output",
        ])
        guard case .pdf(let options) = invocation else {
            return XCTFail("Expected PDF invocation")
        }

        XCTAssertEqual(options.inputPaths, ["one.pdf", "two.pdf"])
        XCTAssertEqual(options.outputDirectoryPath, "/tmp/output")
        XCTAssertEqual(options.sourceLanguageCode, "en")
        XCTAssertEqual(options.targetLanguage, "Chinese (Simplified)")
        XCTAssertEqual(options.outputMode, .monolingual)
    }

    func testCapabilitiesJSONCommandIsExplicit() throws {
        let invocation = try GlossCLIInvocationParser.parse([
            GlossCLICommand.capabilities.rawValue,
            "--json",
        ])
        guard case .capabilitiesJSON = invocation else {
            return XCTFail("Expected capabilities JSON invocation")
        }
    }

    func testDisabledScenarioCannotBeDispatched() {
        let registry = GlossCapabilityRegistry(
            enabledScenarios: [.pdfTranslation]
        )

        XCTAssertThrowsError(
            try GlossCLIInvocationParser.parse(
                [GlossCLICommand.browser.rawValue, "Text"],
                registry: registry
            )
        )
        XCTAssertNoThrow(
            try GlossCLIInvocationParser.parse(
                [
                    GlossCLICommand.pdf.rawValue,
                    "one.pdf",
                    "--output", "/tmp/output",
                ],
                registry: registry
            )
        )
    }

    func testLegacyTextInvocationCannotBypassCapabilityRegistry() {
        let registry = GlossCapabilityRegistry(enabledScenarios: [])

        XCTAssertThrowsError(
            try GlossCLIInvocationParser.parse(
                ["Legacy text"],
                registry: registry
            )
        )
        XCTAssertNoThrow(
            try GlossCLIInvocationParser.parse(
                ["--help"],
                registry: registry
            )
        )
    }

    func testCapabilityReportUsesStableSortedCollections() {
        let report = GlossCapabilitiesReport()

        XCTAssertEqual(
            report.availableCoreCapabilities.map(\.rawValue),
            report.availableCoreCapabilities.map(\.rawValue).sorted()
        )
        XCTAssertEqual(
            report.enabledCoreCapabilities.map(\.rawValue),
            report.enabledCoreCapabilities.map(\.rawValue).sorted()
        )
        XCTAssertEqual(
            report.availableScenarios.map(\.rawValue),
            report.availableScenarios.map(\.rawValue).sorted()
        )
        XCTAssertEqual(
            report.enabledScenarios.map(\.rawValue),
            report.enabledScenarios.map(\.rawValue).sorted()
        )
        XCTAssertEqual(
            report.commandMappings.map(\.command.rawValue),
            report.commandMappings.map(\.command.rawValue).sorted()
        )
        for mapping in report.commandMappings {
            XCTAssertEqual(
                mapping.requiredCapabilities.map(\.rawValue),
                mapping.requiredCapabilities.map(\.rawValue).sorted()
            )
            XCTAssertEqual(
                mapping.scenarioCapabilities.map(\.rawValue),
                mapping.scenarioCapabilities.map(\.rawValue).sorted()
            )
        }
    }
}
