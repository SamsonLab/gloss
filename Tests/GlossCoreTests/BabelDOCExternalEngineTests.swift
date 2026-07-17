import Foundation
import XCTest

@testable import GlossCore

final class BabelDOCExternalEngineTests: XCTestCase {
    func testLiveBenchmarkWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GLOSS_RUN_BABELDOC_BENCHMARK"] == "1" else {
            throw XCTSkip(
                "Set GLOSS_RUN_BABELDOC_BENCHMARK=1 and the benchmark paths to run BabelDOC end to end."
            )
        }
        let inputPath = try XCTUnwrap(environment["GLOSS_BABELDOC_BENCHMARK_INPUT"])
        let outputPath = try XCTUnwrap(environment["GLOSS_BABELDOC_BENCHMARK_OUTPUT"])
        let tokenPath = try XCTUnwrap(environment["GLOSS_BABELDOC_BENCHMARK_TOKEN_FILE"])
        let token = try String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let qps =
            environment["GLOSS_BABELDOC_BENCHMARK_QPS"]
            .flatMap(Int.init) ?? 8
        let pageGroupSize =
            environment["GLOSS_BABELDOC_BENCHMARK_PAGE_GROUP_SIZE"]
            .flatMap(Int.init) ?? 50
        let outputMode =
            environment["GLOSS_BABELDOC_BENCHMARK_OUTPUT_MODE"]
            .flatMap(BabelDOCOutputMode.init(rawValue:)) ?? .monolingual
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )

        let start = ContinuousClock.now
        let result = try await BabelDOCExternalEngine().translate(
            BabelDOCTranslationRequest(
                inputURL: URL(fileURLWithPath: inputPath),
                outputDirectory: outputURL,
                sourceLanguageCode: "en",
                targetLanguageCode: "zh-CN",
                bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
                bridgeToken: token,
                qps: qps,
                maximumPagesPerPart: pageGroupSize,
                skipScannedDetection: true,
                outputMode: outputMode
            )
        )
        let elapsed = start.duration(to: .now)
        try Data(result.log.utf8).write(
            to: outputURL.appendingPathComponent("benchmark.log"),
            options: .atomic
        )

        switch outputMode {
        case .monolingual:
            XCTAssertNotNil(result.monolingualPDF)
        case .bilingual:
            XCTAssertNotNil(result.bilingualPDF)
        }
        print(
            "BABELDOC_BENCHMARK elapsed=\(elapsed) qps=\(qps) page_group=\(pageGroupSize) mode=\(outputMode.rawValue) launching_ms=\(result.timings.launchingMilliseconds) parsing_ms=\(result.timings.parsingMilliseconds) translating_ms=\(result.timings.translatingMilliseconds) typesetting_ms=\(result.timings.typesettingMilliseconds) saving_ms=\(result.timings.savingMilliseconds) output=\(outputURL.path)"
        )
    }

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
        let partIndex = launch.arguments.firstIndex(of: "--max-pages-per-part")
        XCTAssertEqual(partIndex.map { launch.arguments[$0 + 1] }, "50")
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

    func testPageGroupSizeIsPassedToBabelDOC() {
        let request = BabelDOCTranslationRequest(
            inputURL: URL(fileURLWithPath: "/tmp/input.pdf"),
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN",
            bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
            bridgeToken: "token",
            maximumPagesPerPart: 7
        )
        let launch = BabelDOCExternalEngine.makeLaunch(
            runtime: BabelDOCRuntimeLaunch(
                executable: "/tmp/babeldoc",
                source: "test"
            ),
            request: request,
            configurationURL: URL(fileURLWithPath: "/tmp/config.toml"),
            environment: [:]
        )

        let index = launch.arguments.firstIndex(of: "--max-pages-per-part")
        XCTAssertEqual(index.map { launch.arguments[$0 + 1] }, "7")
    }

    func testProgressParserHandlesChunkedNDJSON() throws {
        let parser = BabelDOCExternalEngine.ProgressOutputParser()
        let prefix = BabelDOCExternalEngine.progressLinePrefix
        let first = Data(
            (prefix
                + #"{"type":"progress_update","stage":"Parse Page Layout","stage_current":3,"stage_total":10,"overall_progress":12.5,"part_index":1,"total_parts":2}"#
                + "\n"
                + prefix
                + #"{"type":"progress_update","stage":"Translate Para"#).utf8
        )
        let second = Data(
            (#"graphs","stage_current":4,"stage_total":20,"overall_progress":42.0,"part_index":1,"total_parts":2}"#
                + "\n").utf8
        )

        let firstEvents = parser.append(first)
        XCTAssertEqual(firstEvents.count, 1)
        XCTAssertEqual(firstEvents[0].stage, "Parse Page Layout")
        XCTAssertEqual(firstEvents[0].overallProgress, 12.5)

        let secondEvents = parser.append(second)
        XCTAssertEqual(secondEvents.count, 1)
        XCTAssertEqual(secondEvents[0].stage, "Translate Paragraphs")
        XCTAssertEqual(secondEvents[0].partIndex, 1)
        XCTAssertEqual(secondEvents[0].totalParts, 2)
    }

    func testProgressTimelineMapsBabelDOCStagesToProductPhases() throws {
        let timeline = BabelDOCExternalEngine.ProgressTimeline()
        let parser = BabelDOCExternalEngine.ProgressOutputParser()
        func event(stage: String, progress: Double) throws
            -> BabelDOCExternalEngine.ProgressWireEvent
        {
            let line =
                BabelDOCExternalEngine.progressLinePrefix
                + "{\"type\":\"progress_update\",\"stage\":\"\(stage)\",\"overall_progress\":\(progress)}\n"
            return try XCTUnwrap(parser.append(Data(line.utf8)).first)
        }

        XCTAssertEqual(timeline.initialUpdate().phase, .launching)
        XCTAssertEqual(
            timeline.update(try event(stage: "Parse Paragraphs", progress: 20))?.phase,
            .parsing
        )
        XCTAssertEqual(
            timeline.update(try event(stage: "Translate Paragraphs", progress: 55))?.phase,
            .translating
        )
        XCTAssertEqual(
            timeline.update(try event(stage: "Typesetting", progress: 80))?.phase,
            .typesetting
        )
        XCTAssertEqual(
            timeline.update(try event(stage: "Save PDF", progress: 98))?.phase,
            .saving
        )
        XCTAssertEqual(timeline.finish().phase, .completed)
    }

    func testProgressRunnerEmitsNativeBabelDOCEventsAsNDJSON() throws {
        let interpreter = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ].first(where: FileManager.default.isExecutableFile(atPath:))
        guard let interpreter else {
            throw XCTSkip("Python is unavailable for the BabelDOC runner integration test.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = directory.appendingPathComponent("babeldoc", isDirectory: true)
        let executable = directory.appendingPathComponent("babeldoc-cli")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        try Data().write(to: package.appendingPathComponent("__init__.py"))
        let fakeMain = """
            def create_progress_handler(config, show_log=False):
                raise RuntimeError("runner did not replace the handler")

            def cli():
                context, handler = create_progress_handler(None)
                with context:
                    handler({
                        "type": "progress_update",
                        "stage": "Translate Paragraphs",
                        "stage_current": 3,
                        "stage_total": 8,
                        "overall_progress": 51.5,
                        "part_index": 2,
                        "total_parts": 3,
                    })
            """
        try Data(fakeMain.utf8).write(
            to: package.appendingPathComponent("main.py")
        )
        try Data("#!\(interpreter)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let runtime = BabelDOCRuntimeLaunch(
            executable: executable.path,
            source: "test"
        )
        let runner = try XCTUnwrap(
            BabelDOCExternalEngine.writeProgressRunner(
                for: runtime,
                in: directory
            )
        )
        let launch = BabelDOCExternalEngine.progressLaunch(
            base: (executable.path, [], ["PYTHONPATH": directory.path]),
            runtime: runtime,
            runnerURL: runner
        )
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()

        XCTAssertEqual(process.terminationStatus, 0)
        let events = BabelDOCExternalEngine.ProgressOutputParser().append(output)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].stage, "Translate Paragraphs")
        XCTAssertEqual(events[0].overallProgress, 51.5)
        XCTAssertEqual(events[0].partIndex, 2)
        XCTAssertEqual(events[0].totalParts, 3)
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
