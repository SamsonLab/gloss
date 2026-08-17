import Foundation
import PDFKit
import XCTest

@testable import GlossCore

final class SparkPackageBenchmarkTests: XCTestCase {
    private struct Result: Codable {
        let model: String?
        let repeatIndex: Int
        let budget: Int
        let attempts: Int
        let sourceItems: Int
        let sourceCharacters: Int
        let estimatedCharacters: Int
        let translatedCharacters: Int
        let turns: Int
        let wallMilliseconds: Int
        let preparationMilliseconds: Int
        let queueWaitMilliseconds: Int
        let modelWaitMilliseconds: Int
        let outputStreamMilliseconds: Int
        let cumulativeTurnMilliseconds: Int
        let error: String?
    }

    private struct PackageRun {
        let outputs: [TranslationOutput]
        let performance: TranslationDispatchState.DocumentPerformanceSnapshot
        let wallMilliseconds: Int
        let attempts: Int
        let error: String?
    }

    func testLiveSparkPackageBenchmarkWhenRequested() async throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        guard processEnvironment["GLOSS_RUN_SPARK_PACKAGE_BENCHMARK"] == "1" else {
            throw XCTSkip(
                "Set GLOSS_RUN_SPARK_PACKAGE_BENCHMARK=1 and provide input/output paths."
            )
        }

        let inputPath = try XCTUnwrap(processEnvironment["GLOSS_SPARK_BENCHMARK_INPUT"])
        let outputPath = try XCTUnwrap(processEnvironment["GLOSS_SPARK_BENCHMARK_OUTPUT"])
        let model =
            processEnvironment["GLOSS_SPARK_BENCHMARK_MODEL"]
            ?? "gpt-5.3-codex-spark"
        let budgets = try parseBudgets(
            processEnvironment["GLOSS_SPARK_BENCHMARK_BUDGETS"]
                ?? "1800,3000,4500,6000,8000"
        )
        let repeatCount = max(
            1,
            processEnvironment["GLOSS_SPARK_BENCHMARK_REPEAT"].flatMap(Int.init) ?? 3
        )
        let sourceCharacterLimit = max(
            budgets.max() ?? 8_000,
            processEnvironment["GLOSS_SPARK_BENCHMARK_SOURCE_CHARACTERS"]
                .flatMap(Int.init) ?? 18_000
        )
        let items = try sourceItems(
            from: URL(fileURLWithPath: inputPath),
            characterLimit: sourceCharacterLimit
        )
        let sourceCharacters = items.reduce(0) { $0 + $1.text.count }
        let estimatedCharacters = items.reduce(0) {
            $0 + $1.text.count + BabelDOCBatchCoordinator.estimatedItemFramingCharacters
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let runtimeLog = GlossRuntimeLog(directory: outputDirectory)
        try runtimeLog.prepare()

        var clientEnvironment = processEnvironment
        clientEnvironment["GLOSS_CODEX_MODEL_WAIT_HEDGE_SECONDS"] = "off"
        clientEnvironment["GLOSS_CODEX_MAX_CONCURRENCY"] = "3"
        clientEnvironment["GLOSS_CODEX_BACKGROUND_CONCURRENCY"] = "2"
        clientEnvironment["GLOSS_CODEX_THREAD_ROTATION_TURNS"] = "10"
        let dispatchState = TranslationDispatchState()
        let client = CodexAppServerClient(
            environment: clientEnvironment,
            timeoutSeconds: 180,
            model: model,
            reasoningEffort: .low,
            documentReasoningEffort: .low,
            dispatchState: dispatchState
        )
        let center = TranslationDispatchCenter(
            backend: client,
            configuration: .init(
                maximumConcurrentJobs: 3,
                maximumBackgroundJobs: 2
            ),
            runtimeLog: runtimeLog,
            dispatchState: dispatchState
        )

        do {
            _ = try await retryOnCapacity(maximumAttempts: 6) {
                try await client.translate(
                    TranslationBatchRequest(
                        items: Array(items.prefix(2)),
                        targetLanguage: "Chinese (Simplified)",
                        profile: .academic,
                        contentKind: .document,
                        context: "Spark package benchmark warm-up.",
                        priority: .background
                    )
                )
            }

            var results = loadResults(from: outputURL)
            for repeatIndex in 1...repeatCount {
                let order = benchmarkOrder(budgets, repeatIndex: repeatIndex)
                for budget in order {
                    if results.contains(where: {
                        $0.repeatIndex == repeatIndex && $0.budget == budget
                    }) {
                        continue
                    }
                    let packageRun = try await runPackage(
                        items: items,
                        budget: budget,
                        center: center,
                        dispatchState: dispatchState,
                        runtimeLog: runtimeLog
                    )
                    let outputs = packageRun.outputs
                    let performance = packageRun.performance
                    if packageRun.error == nil {
                        XCTAssertEqual(outputs.map(\.id), items.map(\.id))
                        XCTAssertTrue(outputs.allSatisfy { !$0.text.isEmpty })
                    }

                    let result = Result(
                        model: model,
                        repeatIndex: repeatIndex,
                        budget: budget,
                        attempts: packageRun.attempts,
                        sourceItems: items.count,
                        sourceCharacters: sourceCharacters,
                        estimatedCharacters: estimatedCharacters,
                        translatedCharacters: outputs.reduce(0) { $0 + $1.text.count },
                        turns: performance.completedTurns,
                        wallMilliseconds: packageRun.wallMilliseconds,
                        preparationMilliseconds: performance.preparationMilliseconds,
                        queueWaitMilliseconds: performance.queueWaitMilliseconds,
                        modelWaitMilliseconds: performance.modelWaitMilliseconds,
                        outputStreamMilliseconds: performance.outputStreamMilliseconds,
                        cumulativeTurnMilliseconds: performance.totalTurnMilliseconds,
                        error: packageRun.error
                    )
                    results.append(result)
                    try write(results, to: outputURL)
                    print(
                        "SPARK_PACKAGE_BENCHMARK model=\(model) repeat=\(repeatIndex) budget=\(budget) attempts=\(result.attempts) items=\(items.count) source_chars=\(sourceCharacters) estimated_chars=\(estimatedCharacters) turns=\(result.turns) wall_ms=\(result.wallMilliseconds) model_wait_ms=\(result.modelWaitMilliseconds) output_ms=\(result.outputStreamMilliseconds) translated_chars=\(result.translatedCharacters) error=\(result.error ?? "none")"
                    )
                }
            }
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    private func parseBudgets(_ value: String) throws -> [Int] {
        let budgets = value.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        guard !budgets.isEmpty, budgets.allSatisfy({ (200...12_000).contains($0) }) else {
            throw XCTSkip("Spark package budgets must be within 200...12000.")
        }
        return Array(Set(budgets)).sorted()
    }

    private func runPackage(
        items: [TranslationItem],
        budget: Int,
        center: TranslationDispatchCenter,
        dispatchState: TranslationDispatchState,
        runtimeLog: GlossRuntimeLog
    ) async throws -> PackageRun {
        for attempt in 1...4 {
            let broker = TranslationBroker(backend: center, cacheLimit: 0)
            let coordinator = BabelDOCBatchCoordinator(
                broker: broker,
                configuration: .init(
                    maximumBatchCharacters: budget,
                    maximumConcurrentBatches: 2,
                    fillDelayNanoseconds: 0,
                    refillDelayNanoseconds: 0
                ),
                runtimeLog: runtimeLog,
                dispatchState: dispatchState
            )
            let runID = UUID()
            await dispatchState.beginDocumentPerformanceRun(id: runID)
            let startedAt = DispatchTime.now().uptimeNanoseconds
            do {
                let outputs = try await coordinator.translate(
                    items: items,
                    targetLanguage: "Chinese (Simplified)",
                    context: "Layout-preserving academic PDF translation benchmark."
                )
                let wallMilliseconds = Int(
                    (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                )
                let snapshot = await dispatchState.endDocumentPerformanceRun(id: runID)
                return PackageRun(
                    outputs: outputs,
                    performance: try XCTUnwrap(snapshot),
                    wallMilliseconds: wallMilliseconds,
                    attempts: attempt,
                    error: nil
                )
            } catch {
                try await waitUntilIdle(center)
                let snapshot = await dispatchState.endDocumentPerformanceRun(id: runID)
                if attempt < 4, isCapacityError(error) {
                    try await Task.sleep(for: .seconds(attempt * 5))
                    continue
                }
                return PackageRun(
                    outputs: [],
                    performance: try XCTUnwrap(snapshot),
                    wallMilliseconds: Int(
                        (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    ),
                    attempts: attempt,
                    error: error.localizedDescription
                )
            }
        }
        throw TranslationError.backendUnavailable("Spark package benchmark exhausted retries.")
    }

    private func retryOnCapacity<T: Sendable>(
        maximumAttempts: Int,
        operation: () async throws -> T
    ) async throws -> T {
        for attempt in 1...maximumAttempts {
            do {
                return try await operation()
            } catch {
                guard attempt < maximumAttempts, isCapacityError(error) else { throw error }
                try await Task.sleep(for: .seconds(min(20, attempt * 5)))
            }
        }
        throw TranslationError.backendUnavailable("Spark package benchmark exhausted retries.")
    }

    private func waitUntilIdle(_ center: TranslationDispatchCenter) async throws {
        for _ in 0..<1_800 {
            if await center.snapshot().activeJobs == 0 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TranslationError.timedOut("Spark package benchmark drain")
    }

    private func isCapacityError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("capacity")
    }

    private func benchmarkOrder(_ budgets: [Int], repeatIndex: Int) -> [Int] {
        guard budgets.count > 1 else { return budgets }
        if repeatIndex.isMultiple(of: 2) {
            return budgets.reversed()
        }
        let offset = ((repeatIndex - 1) / 2) % budgets.count
        return Array(budgets[offset...] + budgets[..<offset])
    }

    private func sourceItems(
        from inputURL: URL,
        characterLimit: Int
    ) throws -> [TranslationItem] {
        guard let document = PDFDocument(url: inputURL) else {
            throw XCTSkip("Cannot read benchmark PDF at \(inputURL.path).")
        }
        var items: [TranslationItem] = []
        var characterCount = 0
        for pageIndex in 0..<document.pageCount {
            guard let text = document.page(at: pageIndex)?.string else { continue }
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                let letterCount = line.unicodeScalars.lazy.filter {
                    CharacterSet.letters.contains($0)
                }.count
                guard line.split(whereSeparator: \.isWhitespace).count >= 3,
                    letterCount >= 12
                else { continue }
                for chunk in chunks(of: line, maximumCharacters: 900) {
                    items.append(
                        TranslationItem(id: "item-\(items.count)", text: chunk)
                    )
                    characterCount += chunk.count
                    if characterCount >= characterLimit { return items }
                }
            }
        }
        guard characterCount >= min(characterLimit, 1_000) else {
            throw XCTSkip("Benchmark PDF did not provide enough extractable text.")
        }
        return items
    }

    private func chunks(of text: String, maximumCharacters: Int) -> [String] {
        var result: [String] = []
        var remainder = text[...]
        while remainder.count > maximumCharacters {
            let boundary = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
            let prefix = remainder[..<boundary]
            let split = prefix.lastIndex(where: \.isWhitespace) ?? boundary
            result.append(String(remainder[..<split]))
            remainder = remainder[split...].drop(while: \.isWhitespace)
        }
        if !remainder.isEmpty { result.append(String(remainder)) }
        return result
    }

    private func write(_ results: [Result], to outputURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: outputURL, options: .atomic)
    }

    private func loadResults(from outputURL: URL) -> [Result] {
        guard let data = try? Data(contentsOf: outputURL) else { return [] }
        return (try? JSONDecoder().decode([Result].self, from: data)) ?? []
    }
}
