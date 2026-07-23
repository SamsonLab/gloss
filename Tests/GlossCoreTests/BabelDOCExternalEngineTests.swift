import Foundation
import XCTest

@testable import GlossCore

final class BabelDOCExternalEngineTests: XCTestCase {
    func testRuntimeUnavailablePointsToGlossManagedInstallation() {
        let message = BabelDOCExternalEngineError.runtimeUnavailable.errorDescription

        XCTAssertEqual(
            message,
            "PDF 运行时尚未安装。请在 Gloss 设置的“PDF 运行时”中安装或重试。"
        )
        XCTAssertFalse(message?.contains("uv tool install") == true)
    }

    func testPersistentLayoutServiceSmokeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["GLOSS_RUN_BABELDOC_SERVICE_SMOKE"] == "1"
        else {
            throw XCTSkip(
                "Set GLOSS_RUN_BABELDOC_SERVICE_SMOKE=1 to load the live DocLayout service."
            )
        }
        let runtime = try XCTUnwrap(BabelDOCExternalEngine.resolveRuntime())
        let session = BabelDOCServiceSession()
        do {
            let baseURL = try await session.start(
                runtime: runtime,
                timeout: .seconds(120)
            )
            let (data, response) = try await URLSession.shared.data(
                from: baseURL.appendingPathComponent("healthz")
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("ok"))
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }

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
        let repeatCount = max(
            1,
            environment["GLOSS_BABELDOC_BENCHMARK_REPEAT"].flatMap(Int.init) ?? 1
        )
        let usePersistentLayout =
            environment["GLOSS_BABELDOC_BENCHMARK_PERSISTENT_LAYOUT"] == "1"
        let useLayoutCache =
            environment["GLOSS_BABELDOC_BENCHMARK_LAYOUT_CACHE"] != "0"
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        let runtime = try XCTUnwrap(BabelDOCExternalEngine.resolveRuntime())
        let service = usePersistentLayout ? BabelDOCServiceSession() : nil
        do {
            let layoutServiceBaseURL = try await service?.start(
                runtime: runtime,
                timeout: .seconds(120)
            )
            let layoutCacheDirectoryURL =
                useLayoutCache ? await service?.layoutCacheDirectoryURL : nil
            for run in 1...repeatCount {
                let runOutputURL =
                    repeatCount == 1
                    ? outputURL
                    : outputURL.appendingPathComponent("run-\(run)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: runOutputURL,
                    withIntermediateDirectories: true
                )
                let start = ContinuousClock.now
                let result = try await BabelDOCExternalEngine().translate(
                    BabelDOCTranslationRequest(
                        inputURL: URL(fileURLWithPath: inputPath),
                        outputDirectory: runOutputURL,
                        sourceLanguageCode: "en",
                        targetLanguageCode: "zh-CN",
                        bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
                        bridgeToken: token,
                        qps: qps,
                        maximumPagesPerPart: pageGroupSize,
                        skipScannedDetection: true,
                        outputMode: outputMode,
                        layoutServiceBaseURL: layoutServiceBaseURL,
                        layoutCacheDirectoryURL: layoutCacheDirectoryURL
                    ),
                    runtime: runtime,
                    onOutput: { output in
                        if environment["GLOSS_BABELDOC_BENCHMARK_VERBOSE"] == "1" {
                            print(output, terminator: "")
                        }
                    }
                )
                let elapsed = start.duration(to: .now)
                try Data(result.log.utf8).write(
                    to: runOutputURL.appendingPathComponent("benchmark.log"),
                    options: .atomic
                )

                switch outputMode {
                case .monolingual:
                    XCTAssertNotNil(result.monolingualPDF)
                case .bilingual:
                    XCTAssertNotNil(result.bilingualPDF)
                }
                print(
                    "BABELDOC_BENCHMARK run=\(run)/\(repeatCount) elapsed=\(elapsed) qps=\(qps) page_group=\(pageGroupSize) mode=\(outputMode.rawValue) launching_ms=\(result.timings.launchingMilliseconds) parsing_ms=\(result.timings.parsingMilliseconds) translating_ms=\(result.timings.translatingMilliseconds) typesetting_ms=\(result.timings.typesettingMilliseconds) saving_ms=\(result.timings.savingMilliseconds) layout_cache=\(result.layoutCacheStatus ?? "disabled") output=\(runOutputURL.path)"
                )
            }
            await service?.stop()
        } catch {
            await service?.stop()
            throw error
        }
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

    func testPersistentLayoutServiceIsPassedToBabelDOC() {
        let request = BabelDOCTranslationRequest(
            inputURL: URL(fileURLWithPath: "/tmp/input.pdf"),
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN",
            bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
            bridgeToken: "token",
            layoutServiceBaseURL: URL(string: "http://127.0.0.1:49152")!
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

        let index = launch.arguments.firstIndex(of: "--rpc-doclayout")
        XCTAssertEqual(
            index.map { launch.arguments[$0 + 1] },
            "http://127.0.0.1:49152"
        )
    }

    func testLayoutCacheKeyTracksContentAndLanguage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let input = directory.appendingPathComponent("input.pdf")
        try Data("first".utf8).write(to: input)
        func request(
            target: String = "zh-CN",
            maximumPagesPerPart: Int = 50
        ) -> BabelDOCTranslationRequest {
            BabelDOCTranslationRequest(
                inputURL: input,
                outputDirectory: directory,
                sourceLanguageCode: "en",
                targetLanguageCode: target,
                bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
                bridgeToken: "token",
                maximumPagesPerPart: maximumPagesPerPart,
                skipScannedDetection: true,
                layoutCacheDirectoryURL: directory
            )
        }

        let first = try BabelDOCExternalEngine.layoutCacheKey(for: request())
        XCTAssertEqual(first, try BabelDOCExternalEngine.layoutCacheKey(for: request()))
        XCTAssertNotEqual(
            first,
            try BabelDOCExternalEngine.layoutCacheKey(for: request(target: "ja"))
        )
        XCTAssertNotEqual(
            first,
            try BabelDOCExternalEngine.layoutCacheKey(
                for: request(maximumPagesPerPart: 25)
            )
        )

        try Data("second".utf8).write(to: input)
        XCTAssertNotEqual(
            first,
            try BabelDOCExternalEngine.layoutCacheKey(for: request())
        )
    }

    func testLayoutCacheEnvironmentRequiresComputedKey() {
        let cacheDirectory = URL(fileURLWithPath: "/tmp/layout-cache")
        let request = BabelDOCTranslationRequest(
            inputURL: URL(fileURLWithPath: "/tmp/input.pdf"),
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN",
            bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
            bridgeToken: "token",
            skipScannedDetection: true,
            layoutCacheDirectoryURL: cacheDirectory
        )
        let runtime = BabelDOCRuntimeLaunch(executable: "/tmp/babeldoc", source: "test")
        let withoutKey = BabelDOCExternalEngine.makeLaunch(
            runtime: runtime,
            request: request,
            configurationURL: URL(fileURLWithPath: "/tmp/config.toml"),
            environment: [
                "GLOSS_BABELDOC_LAYOUT_CACHE_DIR": "/tmp/untrusted-cache",
                "GLOSS_BABELDOC_LAYOUT_CACHE_KEY": String(repeating: "f", count: 64),
            ]
        )
        let withKey = BabelDOCExternalEngine.makeLaunch(
            runtime: runtime,
            request: request,
            configurationURL: URL(fileURLWithPath: "/tmp/config.toml"),
            environment: [:],
            layoutCacheKey: String(repeating: "a", count: 64)
        )

        XCTAssertNil(withoutKey.environment["GLOSS_BABELDOC_LAYOUT_CACHE_DIR"])
        XCTAssertNil(withoutKey.environment["GLOSS_BABELDOC_LAYOUT_CACHE_KEY"])
        XCTAssertEqual(
            withKey.environment["GLOSS_BABELDOC_LAYOUT_CACHE_DIR"],
            cacheDirectory.path
        )
        XCTAssertEqual(
            withKey.environment["GLOSS_BABELDOC_LAYOUT_CACHE_KEY"],
            String(repeating: "a", count: 64)
        )
    }

    func testLayoutCacheStatusUsesLastRunnerEvent() {
        let prefix = BabelDOCExternalEngine.layoutCacheLinePrefix
        XCTAssertEqual(
            BabelDOCExternalEngine.layoutCacheStatus(
                in: "\(prefix)miss\n\(prefix)stored\n"
            ),
            "stored"
        )
        XCTAssertEqual(
            BabelDOCExternalEngine.layoutCacheStatus(in: "\(prefix)hit\n"),
            "hit"
        )
        XCTAssertNil(BabelDOCExternalEngine.layoutCacheStatus(in: "ordinary log\n"))
    }

    func testPersistentLayoutServiceReadyPortParser() {
        XCTAssertEqual(
            BabelDOCServiceSession.readyPort(
                in: "loading\n__GLOSS_BABELDOC_LAYOUT_READY__51234\n"
            ),
            51_234
        )
        XCTAssertNil(
            BabelDOCServiceSession.readyPort(
                in: "__GLOSS_BABELDOC_LAYOUT_READY__70000\n"
            )
        )
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
        let distribution = directory.appendingPathComponent(
            "babeldoc-0.6.3.dist-info",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: distribution,
            withIntermediateDirectories: true
        )
        try Data("Name: babeldoc\nVersion: 0.6.3\n".utf8).write(
            to: distribution.appendingPathComponent("METADATA")
        )
        let assetsPackage = package.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assetsPackage,
            withIntermediateDirectories: true
        )
        try Data().write(to: assetsPackage.appendingPathComponent("__init__.py"))
        try Data(
            """
            calls = 0

            def get_font_and_metadata(name):
                global calls
                calls += 1
                return name
            """.utf8
        ).write(to: assetsPackage.appendingPathComponent("assets.py"))
        let fakeMain = """
            from babeldoc.assets import assets

            def create_progress_handler(config, show_log=False):
                raise RuntimeError("runner did not replace the handler")

            def cli():
                assets.get_font_and_metadata("font-a")
                assets.get_font_and_metadata("font-a")
                print(f"FONT_ASSET_CALLS={assets.calls}")
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
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("FONT_ASSET_CALLS=1"))
        let events = BabelDOCExternalEngine.ProgressOutputParser().append(output)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].stage, "Translate Paragraphs")
        XCTAssertEqual(events[0].overallProgress, 51.5)
        XCTAssertEqual(events[0].partIndex, 2)
        XCTAssertEqual(events[0].totalParts, 3)
    }

    func testProgressRunnerReusesCachedLayoutIR() throws {
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
        defer { try? FileManager.default.removeItem(at: directory) }
        func writePackageFile(_ relativePath: String, _ contents: String = "") throws {
            let url = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        for packagePath in [
            "babeldoc/__init__.py",
            "babeldoc/format/__init__.py",
            "babeldoc/format/pdf/__init__.py",
            "babeldoc/format/pdf/new_parser/__init__.py",
            "babeldoc/format/pdf/document_il/__init__.py",
            "babeldoc/format/pdf/document_il/midend/__init__.py",
        ] {
            try writePackageFile(packagePath)
        }
        try writePackageFile(
            "babeldoc-0.6.3.dist-info/METADATA",
            "Name: babeldoc\nVersion: 0.6.3\n"
        )
        try writePackageFile(
            "babeldoc/format/pdf/document_il/il_version_1.py",
            """
            from dataclasses import dataclass

            @dataclass
            class Page:
                page_number: int

            @dataclass
            class Document:
                page: list
                total_pages: int = None
            """
        )
        try writePackageFile(
            "babeldoc/format/pdf/new_parser/native_parse.py",
            """
            from babeldoc.format.pdf.document_il.il_version_1 import Document, Page

            calls = 0

            def parse_prepared_pdf_with_new_parser_to_legacy_ir(*args, **kwargs):
                global calls
                calls += 1
                context = kwargs["config"].shared_context_cross_split_part
                context.valid_char_count_total = 123
                context.total_valid_text_token_count = 45
                return Document([Page(0), Page(1)], total_pages=2)
            """
        )
        try writePackageFile(
            "fitz.py",
            """
            class InputDocument:
                page_count = 2

                def __enter__(self):
                    return self

                def __exit__(self, *_args):
                    return False

            def open(_path):
                return InputDocument()
            """
        )
        try writePackageFile(
            "babeldoc/format/pdf/document_il/midend/layout_parser.py",
            """
            calls = 0

            class LayoutParser:
                stage_name = "Parse Page Layout"

                def __init__(self, translation_config):
                    self.translation_config = translation_config

                def process(self, document, _mupdf_document):
                    global calls
                    calls += 1
                    document.layout_complete = True
                    return document
            """
        )
        try writePackageFile(
            "babeldoc/format/pdf/document_il/midend/paragraph_finder.py",
            """
            calls = 0

            class ParagraphFinder:
                stage_name = "Parse Paragraphs"

                def __init__(self, translation_config):
                    self.translation_config = translation_config

                def process(self, document):
                    global calls
                    calls += 1
                    document.paragraphs_complete = True
            """
        )
        try writePackageFile(
            "babeldoc/format/pdf/document_il/midend/styles_and_formulas.py",
            """
            calls = 0

            class StylesAndFormulas:
                stage_name = "Parse Formulas and Styles"

                def __init__(self, translation_config):
                    self.translation_config = translation_config

                def process(self, document):
                    global calls
                    calls += 1
                    document.styles_complete = True
            """
        )
        try writePackageFile(
            "babeldoc/main.py",
            """
            from babeldoc.format.pdf.document_il.midend import layout_parser
            from babeldoc.format.pdf.document_il.midend import paragraph_finder
            from babeldoc.format.pdf.document_il.midend import styles_and_formulas
            from babeldoc.format.pdf.new_parser import native_parse

            class Stage:
                def __enter__(self):
                    return self

                def __exit__(self, *_args):
                    return False

            class Monitor:
                stage = {
                    "Parse Page Layout": object(),
                    "Parse Paragraphs": object(),
                    "Parse Formulas and Styles": object(),
                }

                def stage_start(self, _name, _total):
                    return Stage()

            class Config:
                progress_monitor = Monitor()

                class SharedContext:
                    valid_char_count_total = 0
                    total_valid_text_token_count = 0

                shared_context_cross_split_part = SharedContext()

            def create_progress_handler(config, show_log=False):
                raise RuntimeError("runner did not replace the handler")

            def cli():
                config = Config()
                document = native_parse.parse_prepared_pdf_with_new_parser_to_legacy_ir(
                    config=config
                )
                document = layout_parser.LayoutParser(config).process(document, None)
                paragraph_finder.ParagraphFinder(config).process(document)
                styles_and_formulas.StylesAndFormulas(config).process(document)
                print(
                    "PIPELINE_CALLS="
                    f"{native_parse.calls},"
                    f"{layout_parser.calls},"
                    f"{paragraph_finder.calls},"
                    f"{styles_and_formulas.calls}"
                )
                context = config.shared_context_cross_split_part
                print(
                    "VALID_COUNTS="
                    f"{context.valid_char_count_total},"
                    f"{context.total_valid_text_token_count}"
                )
            """
        )
        let executable = directory.appendingPathComponent("babeldoc-cli")
        try Data("#!\(interpreter)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let runtime = BabelDOCRuntimeLaunch(executable: executable.path, source: "test")
        let runner = try XCTUnwrap(
            BabelDOCExternalEngine.writeProgressRunner(for: runtime, in: directory)
        )
        let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let abandonedTemporaryFile = cacheDirectory.appendingPathComponent(
            ".layout-ir-2147483647-abandoned.tmp"
        )
        try Data("abandoned".utf8).write(to: abandonedTemporaryFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: abandonedTemporaryFile.path
        )
        let cacheKey = String(repeating: "a", count: 64)
        let input = directory.appendingPathComponent("input.pdf")
        try Data("fake pdf".utf8).write(to: input)

        func run(cacheKey: String = cacheKey) throws -> String {
            let launch = BabelDOCExternalEngine.progressLaunch(
                base: (
                    executable.path,
                    [
                        "--files", input.path,
                        "--max-pages-per-part", "50",
                        "--skip-scanned-detection",
                    ],
                    [
                        "PYTHONPATH": directory.path,
                        "GLOSS_BABELDOC_LAYOUT_CACHE_DIR": cacheDirectory.path,
                        "GLOSS_BABELDOC_LAYOUT_CACHE_KEY": cacheKey,
                    ]
                ),
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
            let output = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            XCTAssertEqual(process.terminationStatus, 0, output)
            return output
        }

        let first = try run()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: abandonedTemporaryFile.path)
        )
        XCTAssertTrue(first.contains("PIPELINE_CALLS=1,1,1,1"), first)
        XCTAssertTrue(first.contains("__GLOSS_BABELDOC_LAYOUT_CACHE__stored"), first)

        let second = try run()
        XCTAssertTrue(second.contains("PIPELINE_CALLS=0,0,0,0"), second)
        XCTAssertTrue(second.contains("VALID_COUNTS=123,45"), second)
        XCTAssertTrue(second.contains("__GLOSS_BABELDOC_LAYOUT_CACHE__hit"), second)

        let marker = directory.appendingPathComponent("unsafe-pickle-executed")
        let cacheFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "pickle" })
        )
        let cacheDirectoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: cacheDirectory.path)[
                .posixPermissions
            ] as? NSNumber
        )
        let cacheFilePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: cacheFile.path)[
                .posixPermissions
            ] as? NSNumber
        )
        XCTAssertEqual(cacheDirectoryPermissions.intValue & 0o777, 0o700)
        XCTAssertEqual(cacheFilePermissions.intValue & 0o777, 0o600)
        let maliciousPickleWriter = directory.appendingPathComponent("write-malicious.py")
        try Data(
            """
            import os
            import pickle
            import sys

            class Exploit:
                def __reduce__(self):
                    return (os.system, (f"touch {sys.argv[2]}",))

            with open(sys.argv[1], "wb") as handle:
                pickle.dump(Exploit(), handle, protocol=5)
            """.utf8
        ).write(to: maliciousPickleWriter)
        let maliciousWriter = Process()
        maliciousWriter.executableURL = URL(fileURLWithPath: interpreter)
        maliciousWriter.arguments = [
            maliciousPickleWriter.path,
            cacheFile.path,
            marker.path,
        ]
        try maliciousWriter.run()
        maliciousWriter.waitUntilExit()
        XCTAssertEqual(maliciousWriter.terminationStatus, 0)

        let afterUnsafeCache = try run()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(
            afterUnsafeCache.contains("__GLOSS_BABELDOC_LAYOUT_CACHE__invalidated"),
            afterUnsafeCache
        )
        XCTAssertTrue(afterUnsafeCache.contains("PIPELINE_CALLS=1,1,1,1"), afterUnsafeCache)

        let stylesModule = directory.appendingPathComponent(
            "babeldoc/format/pdf/document_il/midend/styles_and_formulas.py"
        )
        let stylesContents = try String(contentsOf: stylesModule, encoding: .utf8)
        try Data((stylesContents + "\n# runtime fingerprint changed\n").utf8).write(
            to: stylesModule,
            options: .atomic
        )
        let afterRuntimeChange = try run()
        XCTAssertTrue(afterRuntimeChange.contains("PIPELINE_CALLS=1,1,1,1"))
        XCTAssertTrue(
            afterRuntimeChange.contains("__GLOSS_BABELDOC_LAYOUT_CACHE__miss"),
            afterRuntimeChange
        )
        XCTAssertFalse(afterRuntimeChange.contains("__GLOSS_BABELDOC_LAYOUT_CACHE__hit"))

        for index in 0..<9 {
            let boundedKey = String(repeating: "0", count: 63) + String(index)
            let output = try run(cacheKey: boundedKey)
            XCTAssertTrue(
                output.contains("__GLOSS_BABELDOC_LAYOUT_CACHE__stored"),
                output
            )
        }
        let boundedCacheFiles = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "pickle" }
        XCTAssertLessThanOrEqual(boundedCacheFiles.count, 8)
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
