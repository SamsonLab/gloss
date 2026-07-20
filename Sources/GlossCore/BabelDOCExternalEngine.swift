import Darwin
import Foundation

public struct BabelDOCRuntimeLaunch: Equatable, Sendable {
    public let executable: String
    public let source: String

    public init(executable: String, source: String) {
        self.executable = executable
        self.source = source
    }
}

public enum BabelDOCOutputMode: String, CaseIterable, Sendable {
    case monolingual
    case bilingual
}

public struct BabelDOCTranslationRequest: Sendable {
    public let inputURL: URL
    public let outputDirectory: URL
    public let sourceLanguageCode: String
    public let targetLanguageCode: String
    public let bridgeBaseURL: URL
    public let bridgeToken: String
    public let qps: Int
    public let maximumPagesPerPart: Int
    public let skipScannedDetection: Bool
    public let outputMode: BabelDOCOutputMode
    public let layoutServiceBaseURL: URL?

    public init(
        inputURL: URL,
        outputDirectory: URL,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        bridgeBaseURL: URL,
        bridgeToken: String,
        qps: Int = 8,
        maximumPagesPerPart: Int = 50,
        skipScannedDetection: Bool = false,
        outputMode: BabelDOCOutputMode = .monolingual,
        layoutServiceBaseURL: URL? = nil
    ) {
        self.inputURL = inputURL
        self.outputDirectory = outputDirectory
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.bridgeBaseURL = bridgeBaseURL
        self.bridgeToken = bridgeToken
        self.qps = max(1, qps)
        self.maximumPagesPerPart = max(1, maximumPagesPerPart)
        self.skipScannedDetection = skipScannedDetection
        self.outputMode = outputMode
        self.layoutServiceBaseURL = layoutServiceBaseURL
    }
}

public struct BabelDOCTranslationResult: Equatable, Sendable {
    public let monolingualPDF: URL?
    public let bilingualPDF: URL?
    public let log: String
    public let timings: BabelDOCPhaseTimings

    public init(
        monolingualPDF: URL?,
        bilingualPDF: URL?,
        log: String,
        timings: BabelDOCPhaseTimings = BabelDOCPhaseTimings()
    ) {
        self.monolingualPDF = monolingualPDF
        self.bilingualPDF = bilingualPDF
        self.log = log
        self.timings = timings
    }
}

public enum BabelDOCExternalEngineError: LocalizedError, Equatable, Sendable {
    case runtimeUnavailable
    case launchFailed(String)
    case processFailed(Int32, String)
    case outputMissing

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "未找到 BabelDOC。请先执行：uv tool install --python 3.12 BabelDOC"
        case .launchFailed(let reason):
            "无法启动 BabelDOC：\(reason)"
        case .processFailed(let status, let log):
            "BabelDOC 处理失败（状态 \(status)）：\(log)"
        case .outputMissing:
            "BabelDOC 已结束，但没有生成可用的 PDF。"
        }
    }
}

public final class BabelDOCExternalEngine: @unchecked Sendable {
    private final class ManagedProcess: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var cancelled = false

        func runAndWait() throws -> Int32 {
            lock.lock()
            if cancelled {
                lock.unlock()
                throw CancellationError()
            }
            do {
                try process.run()
                lock.unlock()
            } catch {
                lock.unlock()
                throw error
            }
            process.waitUntilExit()
            return process.terminationStatus
        }

        func terminate() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            guard process.isRunning else { return }
            process.terminate()
        }
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ value: Data) {
            lock.lock()
            data.append(value)
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return String(decoding: snapshot, as: UTF8.self)
        }
    }

    public init() {}

    public static func resolveRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BabelDOCRuntimeLaunch? {
        if let configured = environment["GLOSS_BABELDOC_BIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty,
            FileManager.default.isExecutableFile(atPath: configured)
        {
            return BabelDOCRuntimeLaunch(
                executable: configured,
                source: "configured"
            )
        }

        var candidates: [(String, String)] = []
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append((String(directory) + "/babeldoc", "path"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(contentsOf: [
            ("/opt/homebrew/bin/babeldoc", "homebrew"),
            ("/usr/local/bin/babeldoc", "usr-local"),
            (home.appendingPathComponent(".local/bin/babeldoc").path, "user-local"),
        ])

        var seen = Set<String>()
        for (candidate, source) in candidates
        where seen.insert(candidate).inserted
            && FileManager.default.isExecutableFile(atPath: candidate)
        {
            return BabelDOCRuntimeLaunch(executable: candidate, source: source)
        }
        return nil
    }

    public func translate(
        _ request: BabelDOCTranslationRequest,
        runtime: BabelDOCRuntimeLaunch? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil,
        onProgress: (@Sendable (BabelDOCProgressUpdate) -> Void)? = nil
    ) async throws -> BabelDOCTranslationResult {
        guard let runtime = runtime ?? Self.resolveRuntime() else {
            throw BabelDOCExternalEngineError.runtimeUnavailable
        }

        try FileManager.default.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let configurationURL = try Self.writeSecureConfiguration(for: request)
        defer { try? FileManager.default.removeItem(at: configurationURL) }
        let baseLaunch = Self.makeLaunch(
            runtime: runtime,
            request: request,
            configurationURL: configurationURL,
            environment: ProcessInfo.processInfo.environment
        )
        let progressRunnerURL = try Self.writeProgressRunner(
            for: runtime,
            in: request.outputDirectory
        )
        defer {
            if let progressRunnerURL {
                try? FileManager.default.removeItem(at: progressRunnerURL)
            }
        }
        let launch = Self.progressLaunch(
            base: baseLaunch,
            runtime: runtime,
            runnerURL: progressRunnerURL
        )
        let managed = ManagedProcess()
        let outputPipe = Pipe()
        let outputBuffer = OutputBuffer()
        let progressParser = ProgressOutputParser()
        let progressTimeline = ProgressTimeline()
        onProgress?(progressTimeline.initialUpdate())
        managed.process.executableURL = URL(fileURLWithPath: launch.executable)
        managed.process.arguments = launch.arguments
        managed.process.environment = launch.environment
        managed.process.standardOutput = outputPipe
        managed.process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBuffer.append(data)
            for event in progressParser.append(data) {
                if let update = progressTimeline.update(event) {
                    onProgress?(update)
                }
            }
            onOutput?(String(decoding: data, as: UTF8.self))
        }

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    do {
                        return try managed.runAndWait()
                    } catch {
                        if error is CancellationError {
                            throw error
                        }
                        throw BabelDOCExternalEngineError.launchFailed(
                            error.localizedDescription
                        )
                    }
                }.value
            } onCancel: {
                managed.terminate()
            }
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        let remainder = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainder.isEmpty {
            outputBuffer.append(remainder)
            for event in progressParser.append(remainder) {
                if let update = progressTimeline.update(event) {
                    onProgress?(update)
                }
            }
            onOutput?(String(decoding: remainder, as: UTF8.self))
        }
        for event in progressParser.finish() {
            if let update = progressTimeline.update(event) {
                onProgress?(update)
            }
        }
        try Task.checkCancellation()

        let log = Self.cleanedLog(outputBuffer.string())
        guard status == 0 else {
            throw BabelDOCExternalEngineError.processFailed(
                status,
                String(log.suffix(2_000))
            )
        }

        let outputs = try Self.discoverOutputs(in: request.outputDirectory)
        guard outputs.monolingualPDF != nil || outputs.bilingualPDF != nil else {
            throw BabelDOCExternalEngineError.outputMissing
        }
        let completedProgress = progressTimeline.finish()
        onProgress?(completedProgress)
        return BabelDOCTranslationResult(
            monolingualPDF: outputs.monolingualPDF,
            bilingualPDF: outputs.bilingualPDF,
            log: log,
            timings: completedProgress.timings
        )
    }

    public static func hasReliableTextLayer(_ pageTexts: [String?]) -> Bool {
        guard !pageTexts.isEmpty else { return false }
        let characterCounts = pageTexts.map { text in
            text?.unicodeScalars.reduce(into: 0) { count, scalar in
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    count += 1
                }
            } ?? 0
        }
        let meaningfulPages = characterCounts.filter { $0 >= 40 }.count
        let requiredPages = max(1, Int(ceil(Double(pageTexts.count) * 0.6)))
        let requiredCharacters = max(120, pageTexts.count * 80)
        return meaningfulPages >= requiredPages
            && characterCounts.reduce(0, +) >= requiredCharacters
    }

    static func makeLaunch(
        runtime: BabelDOCRuntimeLaunch,
        request: BabelDOCTranslationRequest,
        configurationURL: URL,
        environment: [String: String]
    ) -> (
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) {
        var arguments = [
            "--files", request.inputURL.path,
            "--output", request.outputDirectory.path,
            "--lang-in", request.sourceLanguageCode,
            "--lang-out", request.targetLanguageCode,
            "--openai",
            "--openai-model", "gloss-provider",
            "--openai-base-url", request.bridgeBaseURL.absoluteString,
            "--config", configurationURL.path,
            "--qps", String(request.qps),
            "--pool-max-workers", String(request.qps),
            "--report-interval", "0.5",
            "--max-pages-per-part", String(request.maximumPagesPerPart),
            "--watermark-output-mode", "no_watermark",
            "--no-auto-extract-glossary",
            "--disable-rich-text-translate",
        ]
        if request.skipScannedDetection {
            arguments.append("--skip-scanned-detection")
        }
        if let layoutServiceBaseURL = request.layoutServiceBaseURL {
            arguments.append(contentsOf: [
                "--rpc-doclayout",
                layoutServiceBaseURL.absoluteString,
            ])
        }
        let optionalFlags = [
            ("GLOSS_BABELDOC_SKIP_CLEAN", "--skip-clean"),
            (
                "GLOSS_BABELDOC_DISABLE_SAME_TEXT_FALLBACK",
                "--disable-same-text-fallback"
            ),
            ("GLOSS_BABELDOC_IGNORE_CACHE", "--ignore-cache"),
        ]
        for (environmentKey, argument) in optionalFlags
        where environment[environmentKey] == "1" {
            arguments.append(argument)
        }
        switch request.outputMode {
        case .monolingual:
            arguments.append("--no-dual")
        case .bilingual:
            arguments.append("--no-mono")
        }

        var processEnvironment = environment
        let executableDirectory = URL(fileURLWithPath: runtime.executable)
            .deletingLastPathComponent().path
        let inherited = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbacks = [
            executableDirectory,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin").path,
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        var seen = Set<String>()
        processEnvironment["PATH"] = (fallbacks + inherited)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        for key in ["NO_PROXY", "no_proxy"] {
            let inheritedHosts = (environment[key] ?? "")
                .split(separator: ",")
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            var seenHosts = Set<String>()
            processEnvironment[key] = (["127.0.0.1", "localhost", "::1"] + inheritedHosts)
                .filter { !$0.isEmpty && seenHosts.insert($0).inserted }
                .joined(separator: ",")
        }
        return (runtime.executable, arguments, processEnvironment)
    }

    static func progressLaunch(
        base: (
            executable: String,
            arguments: [String],
            environment: [String: String]
        ),
        runtime: BabelDOCRuntimeLaunch,
        runnerURL: URL?
    ) -> (
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) {
        guard let runnerURL,
            let interpreter = pythonInterpreter(for: runtime.executable)
        else { return base }
        var environment = base.environment
        environment["PYTHONUNBUFFERED"] = "1"
        return (
            interpreter,
            [runnerURL.path] + base.arguments,
            environment
        )
    }

    static func pythonInterpreter(for executable: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: executable) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: 512)
        guard let data,
            let firstLine = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first,
            firstLine.hasPrefix("#!")
        else { return nil }
        let command = firstLine.dropFirst(2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.contains(" "),
            URL(fileURLWithPath: command).lastPathComponent.lowercased()
                .contains("python"),
            FileManager.default.isExecutableFile(atPath: command)
        else { return nil }
        return command
    }

    static func writeProgressRunner(
        for runtime: BabelDOCRuntimeLaunch,
        in directory: URL
    ) throws -> URL? {
        guard pythonInterpreter(for: runtime.executable) != nil else { return nil }
        let url = directory.appendingPathComponent(".gloss-babeldoc-progress.py")
        let contents = #"""
            import contextlib
            import json
            import multiprocessing

            import babeldoc.main

            PREFIX = "__GLOSS_BABELDOC_PROGRESS__"
            FIELDS = (
                "type",
                "stage",
                "stage_current",
                "stage_total",
                "overall_progress",
                "part_index",
                "total_parts",
            )

            def create_progress_handler(_translation_config, show_log=False):
                def handle(event):
                    if event.get("type") not in {
                        "stage_summary",
                        "progress_start",
                        "progress_update",
                        "progress_end",
                    }:
                        return
                    payload = {key: event[key] for key in FIELDS if key in event}
                    print(PREFIX + json.dumps(payload, separators=(",", ":")), flush=True)
                return contextlib.nullcontext(), handle

            babeldoc.main.create_progress_handler = create_progress_handler

            if __name__ == "__main__":
                multiprocessing.freeze_support()
                babeldoc.main.cli()
            """#
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    static func writeSecureConfiguration(
        for request: BabelDOCTranslationRequest
    ) throws -> URL {
        let configurationURL = request.outputDirectory
            .appendingPathComponent(".gloss-babeldoc.toml")
        let token = request.bridgeToken
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        let contents = """
            [babeldoc]
            openai-api-key = "\(token)"
            """
        try Data(contents.utf8).write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationURL.path
        )
        return configurationURL
    }

    static func discoverOutputs(
        in directory: URL
    ) throws -> (monolingualPDF: URL?, bilingualPDF: URL?) {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else {
            return (nil, nil)
        }
        let files = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                url.pathExtension.lowercased() == "pdf",
                (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true
            else { return nil }
            return url
        }.sorted { $0.path < $1.path }

        let dual = files.first {
            let name = $0.deletingPathExtension().lastPathComponent.lowercased()
            return name.contains("dual") || name.contains("bilingual")
        }
        let mono = files.first { $0 != dual }
        return (mono ?? (dual == nil ? files.first : nil), dual)
    }

    private static func cleanedLog(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.contains(progressLinePrefix) }
            .suffix(200)
            .joined(separator: "\n")
    }
}
