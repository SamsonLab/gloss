import Foundation
import XCTest

@testable import GlossCore

final class BabelDOCExternalEngineTests: XCTestCase {
    func testReliableTextLayerRequiresTextAcrossMostSampledPages() {
        let densePage = String(repeating: "A paragraph of selectable text. ", count: 5)

        XCTAssertTrue(
            BabelDOCExternalEngine.hasReliableTextLayer([
                densePage,
                densePage,
                densePage,
            ])
        )
        XCTAssertFalse(
            BabelDOCExternalEngine.hasReliableTextLayer([
                densePage,
                nil,
                "  ",
            ])
        )
        XCTAssertFalse(BabelDOCExternalEngine.hasReliableTextLayer([]))
    }

    func testConfiguredRuntimeTakesPriority() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("babeldoc")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let runtime = BabelDOCExternalEngine.resolveRuntime(
            environment: [
                "GLOSS_BABELDOC_BIN": executable.path,
                "PATH": "",
            ]
        )

        XCTAssertEqual(
            runtime,
            BabelDOCRuntimeLaunch(
                executable: executable.path,
                source: "configured"
            )
        )
    }

    func testLaunchUsesGlossBridgeWithoutPuttingTokenInArguments() {
        let runtime = BabelDOCRuntimeLaunch(
            executable: "/tmp/babeldoc",
            source: "test"
        )
        let request = BabelDOCTranslationRequest(
            inputURL: URL(fileURLWithPath: "/tmp/input.pdf"),
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            sourceLanguageCode: "EN",
            targetLanguageCode: "zh-CN",
            bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
            bridgeToken: "secret-token",
            qps: 3,
            skipScannedDetection: true
        )

        let launch = BabelDOCExternalEngine.makeLaunch(
            runtime: runtime,
            request: request,
            configurationURL: URL(fileURLWithPath: "/tmp/gloss-babeldoc.toml"),
            environment: ["PATH": "/usr/bin"]
        )

        XCTAssertEqual(launch.executable, runtime.executable)
        XCTAssertTrue(launch.arguments.contains("--openai"))
        XCTAssertTrue(launch.arguments.contains("http://127.0.0.1:8787/v1"))
        XCTAssertTrue(launch.arguments.contains("--no-auto-extract-glossary"))
        XCTAssertTrue(
            launch.arguments.contains("--disable-rich-text-translate")
        )
        XCTAssertTrue(launch.arguments.contains("--no-dual"))
        XCTAssertFalse(launch.arguments.contains("--no-mono"))
        let qpsIndex = launch.arguments.firstIndex(of: "--qps")
        XCTAssertEqual(qpsIndex.map { launch.arguments[$0 + 1] }, "3")
        let workerIndex = launch.arguments.firstIndex(of: "--pool-max-workers")
        XCTAssertEqual(workerIndex.map { launch.arguments[$0 + 1] }, "3")
        XCTAssertTrue(launch.arguments.contains("--skip-scanned-detection"))
        XCTAssertTrue(launch.arguments.contains("--config"))
        XCTAssertTrue(launch.arguments.contains("/tmp/gloss-babeldoc.toml"))
        XCTAssertFalse(launch.arguments.contains("secret-token"))
        XCTAssertNil(launch.environment["OPENAI_API_KEY"])
        XCTAssertEqual(
            launch.environment["NO_PROXY"],
            "127.0.0.1,localhost,::1"
        )
        XCTAssertEqual(
            launch.environment["no_proxy"],
            "127.0.0.1,localhost,::1"
        )
    }

    func testDualOutputModeDisablesMonolingualPDF() {
        let runtime = BabelDOCRuntimeLaunch(
            executable: "/tmp/babeldoc",
            source: "test"
        )
        let request = BabelDOCTranslationRequest(
            inputURL: URL(fileURLWithPath: "/tmp/input.pdf"),
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN",
            bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
            bridgeToken: "token",
            outputMode: .bilingual
        )

        let launch = BabelDOCExternalEngine.makeLaunch(
            runtime: runtime,
            request: request,
            configurationURL: URL(fileURLWithPath: "/tmp/config.toml"),
            environment: [:]
        )

        XCTAssertTrue(launch.arguments.contains("--no-mono"))
        XCTAssertFalse(launch.arguments.contains("--no-dual"))
        let qpsIndex = launch.arguments.firstIndex(of: "--qps")
        XCTAssertEqual(qpsIndex.map { launch.arguments[$0 + 1] }, "8")
    }

    func testExperimentalPerformanceFlagsAreOptIn() {
        let runtime = BabelDOCRuntimeLaunch(
            executable: "/tmp/babeldoc",
            source: "test"
        )
        let request = BabelDOCTranslationRequest(
            inputURL: URL(fileURLWithPath: "/tmp/input.pdf"),
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN",
            bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
            bridgeToken: "token"
        )

        let normalLaunch = BabelDOCExternalEngine.makeLaunch(
            runtime: runtime,
            request: request,
            configurationURL: URL(fileURLWithPath: "/tmp/config.toml"),
            environment: [:]
        )
        let fastLaunch = BabelDOCExternalEngine.makeLaunch(
            runtime: runtime,
            request: request,
            configurationURL: URL(fileURLWithPath: "/tmp/config.toml"),
            environment: [
                "GLOSS_BABELDOC_SKIP_CLEAN": "1",
                "GLOSS_BABELDOC_DISABLE_SAME_TEXT_FALLBACK": "1",
                "GLOSS_BABELDOC_IGNORE_CACHE": "1",
            ]
        )

        for argument in [
            "--skip-clean",
            "--disable-same-text-fallback",
            "--ignore-cache",
        ] {
            XCTAssertFalse(normalLaunch.arguments.contains(argument))
            XCTAssertTrue(fastLaunch.arguments.contains(argument))
        }
    }

    func testWritesBridgeTokenToPrivateConfigurationFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let request = BabelDOCTranslationRequest(
            inputURL: directory.appendingPathComponent("input.pdf"),
            outputDirectory: directory,
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN",
            bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
            bridgeToken: #"secret-"token""#
        )

        let configurationURL =
            try BabelDOCExternalEngine.writeSecureConfiguration(for: request)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: configurationURL.path
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        )
        let contents = try String(contentsOf: configurationURL, encoding: .utf8)

        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertTrue(contents.contains(#"openai-api-key = "secret-\"token\"""#))
    }

    func testDiscoversMonoAndDualOutputs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let mono = directory.appendingPathComponent("paper-mono.pdf")
        let dual = directory.appendingPathComponent("paper-dual.pdf")
        try Data("mono".utf8).write(to: mono)
        try Data("dual".utf8).write(to: dual)

        let outputs = try BabelDOCExternalEngine.discoverOutputs(in: directory)

        XCTAssertEqual(
            outputs.monolingualPDF?.resolvingSymlinksInPath(),
            mono.resolvingSymlinksInPath()
        )
        XCTAssertEqual(
            outputs.bilingualPDF?.resolvingSymlinksInPath(),
            dual.resolvingSymlinksInPath()
        )
    }

    func testRunsExternalEngineAndCollectsOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("babeldoc")
        let input = directory.appendingPathComponent("input.pdf")
        let output = directory.appendingPathComponent("output", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let script = """
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--output" ]; then
                shift
                output="$1"
              fi
              shift
            done
            mkdir -p "$output"
            printf 'pdf' > "$output/result-mono.pdf"
            printf '50%%\\n100%%\\n'
            """
        try Data(script.utf8).write(to: executable)
        try Data("input".utf8).write(to: input)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let result = try await BabelDOCExternalEngine().translate(
            BabelDOCTranslationRequest(
                inputURL: input,
                outputDirectory: output,
                sourceLanguageCode: "EN",
                targetLanguageCode: "zh-CN",
                bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
                bridgeToken: "token"
            ),
            runtime: BabelDOCRuntimeLaunch(
                executable: executable.path,
                source: "test"
            )
        )

        XCTAssertNotNil(result.monolingualPDF)
        XCTAssertTrue(result.log.contains("100%"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: output.appendingPathComponent(".gloss-babeldoc.toml").path
            )
        )
    }
}
