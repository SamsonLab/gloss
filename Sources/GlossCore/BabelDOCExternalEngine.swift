import CryptoKit
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
    public let layoutCacheDirectoryURL: URL?

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
        layoutServiceBaseURL: URL? = nil,
        layoutCacheDirectoryURL: URL? = nil
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
        self.layoutCacheDirectoryURL = layoutCacheDirectoryURL
    }
}

public struct BabelDOCTranslationResult: Equatable, Sendable {
    public let monolingualPDF: URL?
    public let bilingualPDF: URL?
    public let log: String
    public let timings: BabelDOCPhaseTimings
    public let layoutCacheStatus: String?

    public init(
        monolingualPDF: URL?,
        bilingualPDF: URL?,
        log: String,
        timings: BabelDOCPhaseTimings = BabelDOCPhaseTimings(),
        layoutCacheStatus: String? = nil
    ) {
        self.monolingualPDF = monolingualPDF
        self.bilingualPDF = bilingualPDF
        self.log = log
        self.timings = timings
        self.layoutCacheStatus = layoutCacheStatus
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

        let layoutCacheKey: String?
        if request.layoutCacheDirectoryURL != nil {
            let keyTask = Task.detached(priority: .utility) {
                try Self.layoutCacheKey(for: request)
            }
            do {
                layoutCacheKey = try await withTaskCancellationHandler {
                    try await keyTask.value
                } onCancel: {
                    keyTask.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                layoutCacheKey = nil
            }
        } else {
            layoutCacheKey = nil
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
            environment: ProcessInfo.processInfo.environment,
            layoutCacheKey: layoutCacheKey
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

        let rawLog = outputBuffer.string()
        let layoutCacheStatus = Self.layoutCacheStatus(in: rawLog)
        let log = Self.cleanedLog(rawLog)
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
            timings: completedProgress.timings,
            layoutCacheStatus: layoutCacheStatus
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
        environment: [String: String],
        layoutCacheKey: String? = nil
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
        processEnvironment.removeValue(forKey: "GLOSS_BABELDOC_LAYOUT_CACHE_DIR")
        processEnvironment.removeValue(forKey: "GLOSS_BABELDOC_LAYOUT_CACHE_KEY")
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
        if let layoutCacheDirectoryURL = request.layoutCacheDirectoryURL,
            let layoutCacheKey
        {
            processEnvironment["GLOSS_BABELDOC_LAYOUT_CACHE_DIR"] =
                layoutCacheDirectoryURL.path
            processEnvironment["GLOSS_BABELDOC_LAYOUT_CACHE_KEY"] = layoutCacheKey
        }
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

    static func layoutCacheKey(for request: BabelDOCTranslationRequest) throws -> String {
        let handle = try FileHandle(forReadingFrom: request.inputURL)
        defer { try? handle.close() }
        var fileHasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            fileHasher.update(data: data)
        }
        let fileDigest = fileHasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        let identity = [
            "gloss-layout-ir-v2",
            "babeldoc-0.6.3",
            fileDigest,
            request.sourceLanguageCode.lowercased(),
            request.targetLanguageCode.lowercased(),
            request.skipScannedDetection ? "skip-scan" : "detect-scan",
            "max-pages-per-part=\(request.maximumPagesPerPart)",
            "parser-profile=gloss-default-v1",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
            import dataclasses
            import functools
            import hashlib
            import importlib.metadata
            import json
            import multiprocessing
            import os
            import pickle
            import stat
            import sys
            import tempfile
            import time
            from pathlib import Path

            import babeldoc.main

            PREFIX = "__GLOSS_BABELDOC_PROGRESS__"
            CACHE_PREFIX = "__GLOSS_BABELDOC_LAYOUT_CACHE__"
            CACHE_SCHEMA = 2
            MAX_CACHE_FILE_BYTES = 256 * 1024 * 1024
            MAX_CACHE_TOTAL_BYTES = 512 * 1024 * 1024
            MAX_CACHE_ENTRIES = 8
            PARSE_STAGE = "Parse PDF and Create Intermediate Representation"
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

            def install_font_asset_cache():
                try:
                    if importlib.metadata.version("babeldoc") != "0.6.3":
                        return
                    from babeldoc.assets import assets
                except (ImportError, AttributeError, importlib.metadata.PackageNotFoundError):
                    return
                loader = getattr(assets, "get_font_and_metadata", None)
                if loader is None or hasattr(loader, "cache_info"):
                    return
                assets.get_font_and_metadata = functools.lru_cache(maxsize=None)(loader)

            def emit_cache_status(status):
                print(CACHE_PREFIX + status, flush=True)

            def single_input_path():
                try:
                    index = sys.argv.index("--files") + 1
                except ValueError:
                    return None
                paths = []
                while index < len(sys.argv) and not sys.argv[index].startswith("--"):
                    paths.append(sys.argv[index])
                    index += 1
                return Path(paths[0]) if len(paths) == 1 else None

            def module_fingerprint(modules):
                digest = hashlib.sha256()
                unique_modules = {
                    module.__name__: module
                    for module in modules
                    if module is not None and getattr(module, "__file__", None)
                }
                for name in sorted(unique_modules):
                    path = Path(unique_modules[name].__file__).resolve()
                    digest.update(name.encode("utf-8"))
                    digest.update(b"\0")
                    with path.open("rb") as handle:
                        while chunk := handle.read(1024 * 1024):
                            digest.update(chunk)
                return digest.hexdigest()

            def stable_file_fingerprint(path):
                before = os.stat(path)
                digest = hashlib.sha256()
                with path.open("rb") as handle:
                    while chunk := handle.read(1024 * 1024):
                        digest.update(chunk)
                after = os.stat(path)
                before_identity = (
                    before.st_dev,
                    before.st_ino,
                    before.st_size,
                    before.st_mtime_ns,
                    before.st_ctime_ns,
                )
                after_identity = (
                    after.st_dev,
                    after.st_ino,
                    after.st_size,
                    after.st_mtime_ns,
                    after.st_ctime_ns,
                )
                if before_identity != after_identity:
                    raise ValueError("input changed while hashing")
                return digest.hexdigest(), after_identity

            def install_layout_ir_cache():
                cache_root_value = os.environ.get("GLOSS_BABELDOC_LAYOUT_CACHE_DIR")
                cache_key = os.environ.get("GLOSS_BABELDOC_LAYOUT_CACHE_KEY", "")
                if not cache_root_value or len(cache_key) != 64:
                    return
                if any(character not in "0123456789abcdef" for character in cache_key):
                    emit_cache_status("invalid_key")
                    return
                try:
                    if importlib.metadata.version("babeldoc") != "0.6.3":
                        emit_cache_status("unsupported_version")
                        return
                    if "--skip-scanned-detection" not in sys.argv:
                        emit_cache_status("ineligible")
                        return
                    from babeldoc.format.pdf.document_il.midend.layout_parser import LayoutParser
                    from babeldoc.format.pdf.document_il.midend.paragraph_finder import ParagraphFinder
                    from babeldoc.format.pdf.document_il.midend.styles_and_formulas import StylesAndFormulas
                    from babeldoc.format.pdf.document_il import il_version_1
                    from babeldoc.format.pdf.new_parser import native_parse
                    import fitz
                except (ImportError, AttributeError, importlib.metadata.PackageNotFoundError):
                    emit_cache_status("unsupported_runtime")
                    return

                input_path = single_input_path()
                if input_path is None:
                    emit_cache_status("ineligible")
                    return
                try:
                    input_fingerprint, input_identity = stable_file_fingerprint(
                        input_path
                    )
                    with fitz.open(input_path) as input_document:
                        expected_page_count = input_document.page_count
                    maximum_pages_index = sys.argv.index("--max-pages-per-part") + 1
                    maximum_pages_per_part = int(sys.argv[maximum_pages_index])
                    if expected_page_count < 1 or expected_page_count > maximum_pages_per_part:
                        raise ValueError("input would be split")
                except (OSError, RuntimeError, ValueError, IndexError):
                    emit_cache_status("ineligible")
                    return
                expected_page_numbers = list(range(expected_page_count))
                il_module_name = "babeldoc.format.pdf.document_il.il_version_1"
                try:
                    runtime_fingerprint = module_fingerprint(
                        [
                            il_version_1,
                            native_parse,
                            sys.modules.get("babeldoc.format.pdf.high_level"),
                            sys.modules.get(LayoutParser.__module__),
                            sys.modules.get(ParagraphFinder.__module__),
                            sys.modules.get(StylesAndFormulas.__module__),
                        ]
                    )
                    cache_key = hashlib.sha256(
                        (
                            f"{cache_key}\0{input_fingerprint}"
                            f"\0{runtime_fingerprint}"
                        ).encode("utf-8")
                    ).hexdigest()
                except (OSError, ValueError):
                    emit_cache_status("unsupported_runtime")
                    return
                allowed_il_types = {
                    name: value
                    for name, value in vars(il_version_1).items()
                    if isinstance(value, type)
                    and dataclasses.is_dataclass(value)
                    and value.__module__ == il_module_name
                }

                class RestrictedILUnpickler(pickle.Unpickler):
                    def find_class(self, module, name):
                        if module == il_module_name and name in allowed_il_types:
                            return allowed_il_types[name]
                        raise pickle.UnpicklingError(
                            f"forbidden pickle global: {module}.{name}"
                        )

                def validated_page_numbers(document):
                    if not isinstance(document, il_version_1.Document):
                        raise ValueError("cached document type is invalid")
                    pages = getattr(document, "page", None)
                    if not isinstance(pages, list) or len(pages) != expected_page_count:
                        raise ValueError("cached page count is invalid")
                    page_numbers = [getattr(page, "page_number", None) for page in pages]
                    if page_numbers != expected_page_numbers:
                        raise ValueError("cached page numbers are invalid")
                    total_pages = getattr(document, "total_pages", None)
                    if total_pages not in (None, expected_page_count):
                        raise ValueError("cached total page count is invalid")
                    return page_numbers

                try:
                    cache_root = Path(cache_root_value)
                    root_info = os.lstat(cache_root)
                    if not stat.S_ISDIR(root_info.st_mode) or stat.S_ISLNK(root_info.st_mode):
                        raise ValueError("cache path is not a directory")
                    if root_info.st_uid != os.getuid():
                        raise ValueError("cache directory owner is invalid")
                    if stat.S_IMODE(root_info.st_mode) != 0o700:
                        raise ValueError("cache directory permissions are unsafe")
                except Exception:
                    emit_cache_status("unsafe_directory")
                    return

                def process_exists(process_identifier):
                    try:
                        os.kill(process_identifier, 0)
                        return True
                    except ProcessLookupError:
                        return False
                    except PermissionError:
                        return True

                def cleanup_temporary_files():
                    try:
                        candidates = list(cache_root.glob(".layout-ir-*.tmp"))
                    except OSError:
                        return
                    for candidate in candidates:
                        try:
                            info = os.lstat(candidate)
                        except OSError:
                            continue
                        if (
                            not stat.S_ISREG(info.st_mode)
                            or stat.S_ISLNK(info.st_mode)
                            or info.st_uid != os.getuid()
                            or info.st_mode & 0o077
                        ):
                            continue
                        remainder = candidate.name[len(".layout-ir-") :]
                        process_value = remainder.split("-", 1)[0]
                        if process_value.isdigit():
                            if process_exists(int(process_value)):
                                continue
                        elif time.time() - info.st_mtime < 60 * 60:
                            continue
                        try:
                            candidate.unlink()
                        except OSError:
                            pass

                cleanup_temporary_files()
                cache_path = cache_root / f"{cache_key}.pickle"
                state = {
                    "hit": False,
                    "valid_character_count": 0,
                    "valid_token_count": 0,
                    "eligible": True,
                }

                def input_is_unchanged():
                    try:
                        current = os.stat(input_path)
                    except OSError:
                        return False
                    current_identity = (
                        current.st_dev,
                        current.st_ino,
                        current.st_size,
                        current.st_mtime_ns,
                        current.st_ctime_ns,
                    )
                    return current_identity == input_identity

                def cache_entries():
                    entries = []
                    try:
                        candidates = list(cache_root.iterdir())
                    except OSError:
                        return entries
                    for candidate in candidates:
                        if (
                            candidate.suffix != ".pickle"
                            or len(candidate.stem) != 64
                            or any(
                                character not in "0123456789abcdef"
                                for character in candidate.stem
                            )
                        ):
                            continue
                        try:
                            info = os.lstat(candidate)
                        except OSError:
                            continue
                        if (
                            not stat.S_ISREG(info.st_mode)
                            or stat.S_ISLNK(info.st_mode)
                            or info.st_uid != os.getuid()
                            or info.st_mode & 0o077
                        ):
                            continue
                        entries.append((candidate, info))
                    return entries

                def prune_cache(
                    maximum_bytes,
                    maximum_entries,
                    protected_path=None,
                ):
                    total_bytes = 0
                    kept_entries = 0
                    entries = sorted(
                        cache_entries(),
                        key=lambda entry: (
                            entry[0] == protected_path,
                            entry[1].st_mtime_ns,
                        ),
                        reverse=True,
                    )
                    for candidate, info in entries:
                        if (
                            kept_entries < maximum_entries
                            and total_bytes + info.st_size <= maximum_bytes
                        ):
                            kept_entries += 1
                            total_bytes += info.st_size
                            continue
                        try:
                            candidate.unlink()
                        except OSError:
                            pass

                class LimitedWriter:
                    def __init__(self, handle, limit):
                        self.handle = handle
                        self.limit = limit
                        self.bytes_written = 0

                    def write(self, data):
                        next_size = self.bytes_written + len(data)
                        if next_size > self.limit:
                            raise ValueError("cache is too large")
                        written = self.handle.write(data)
                        self.bytes_written += written
                        return written

                def load_document():
                    try:
                        info = os.lstat(cache_path)
                        if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                            raise ValueError("cache is not a regular file")
                        if info.st_uid != os.getuid() or info.st_mode & 0o077:
                            raise ValueError("cache permissions are unsafe")
                        if info.st_size <= 0 or info.st_size > MAX_CACHE_FILE_BYTES:
                            raise ValueError("cache size is invalid")
                        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                        descriptor = os.open(cache_path, flags)
                        with os.fdopen(descriptor, "rb") as handle:
                            payload = RestrictedILUnpickler(handle).load()
                        if not isinstance(payload, dict):
                            raise ValueError("cache payload is invalid")
                        if payload.get("schema") != CACHE_SCHEMA:
                            raise ValueError("cache schema is invalid")
                        if payload.get("key") != cache_key:
                            raise ValueError("cache key is invalid")
                        document = payload.get("document")
                        page_numbers = validated_page_numbers(document)
                        if payload.get("page_count") != expected_page_count:
                            raise ValueError("cache page count is invalid")
                        if payload.get("page_numbers") != page_numbers:
                            raise ValueError("cache page numbers are invalid")
                        valid_character_count = payload.get("valid_character_count")
                        valid_token_count = payload.get("valid_token_count")
                        if (
                            not isinstance(valid_character_count, int)
                            or isinstance(valid_character_count, bool)
                            or valid_character_count < 0
                            or not isinstance(valid_token_count, int)
                            or isinstance(valid_token_count, bool)
                            or valid_token_count < 0
                        ):
                            raise ValueError("cache text statistics are invalid")
                        state["valid_character_count"] = valid_character_count
                        state["valid_token_count"] = valid_token_count
                        try:
                            os.utime(cache_path, None, follow_symlinks=False)
                        except OSError:
                            pass
                        return document
                    except FileNotFoundError:
                        return None
                    except Exception:
                        try:
                            cache_path.unlink()
                        except OSError:
                            pass
                        emit_cache_status("invalidated")
                        return None

                def store_document(document, translation_config):
                    descriptor = None
                    temporary_path = None
                    try:
                        if not state["eligible"] or not input_is_unchanged():
                            emit_cache_status("input_changed")
                            return
                        page_numbers = validated_page_numbers(document)
                        shared_context = getattr(
                            translation_config,
                            "shared_context_cross_split_part",
                            None,
                        )
                        valid_character_count = getattr(
                            shared_context,
                            "valid_char_count_total",
                            0,
                        )
                        valid_token_count = getattr(
                            shared_context,
                            "total_valid_text_token_count",
                            0,
                        )
                        if not isinstance(valid_character_count, int):
                            valid_character_count = 0
                        if not isinstance(valid_token_count, int):
                            valid_token_count = 0
                        prune_cache(
                            MAX_CACHE_TOTAL_BYTES - MAX_CACHE_FILE_BYTES,
                            MAX_CACHE_ENTRIES - 1,
                        )
                        descriptor, temporary_name = tempfile.mkstemp(
                            prefix=f".layout-ir-{os.getpid()}-",
                            suffix=".tmp",
                            dir=cache_root,
                        )
                        temporary_path = Path(temporary_name)
                        os.fchmod(descriptor, 0o600)
                        with os.fdopen(descriptor, "wb") as handle:
                            descriptor = None
                            limited_writer = LimitedWriter(
                                handle,
                                MAX_CACHE_FILE_BYTES,
                            )
                            pickle.dump(
                                {
                                    "schema": CACHE_SCHEMA,
                                    "key": cache_key,
                                    "page_count": expected_page_count,
                                    "page_numbers": page_numbers,
                                    "valid_character_count": valid_character_count,
                                    "valid_token_count": valid_token_count,
                                    "document": document,
                                },
                                limited_writer,
                                protocol=5,
                            )
                            handle.flush()
                            os.fsync(handle.fileno())
                        os.replace(temporary_path, cache_path)
                        os.chmod(cache_path, 0o600)
                        prune_cache(
                            MAX_CACHE_TOTAL_BYTES,
                            MAX_CACHE_ENTRIES,
                            protected_path=cache_path,
                        )
                        emit_cache_status("stored")
                    except Exception:
                        emit_cache_status("write_error")
                    finally:
                        if descriptor is not None:
                            os.close(descriptor)
                        if temporary_path is not None:
                            try:
                                temporary_path.unlink()
                            except OSError:
                                pass

                def complete_stage(config, stage_name, total):
                    monitor = getattr(config, "progress_monitor", None)
                    if monitor is None or stage_name not in getattr(monitor, "stage", {}):
                        return
                    with monitor.stage_start(stage_name, max(1, total)):
                        pass

                original_parse = native_parse.parse_prepared_pdf_with_new_parser_to_legacy_ir
                original_layout_process = LayoutParser.process
                original_paragraph_init = ParagraphFinder.__init__
                original_paragraph_process = ParagraphFinder.process
                original_styles_init = StylesAndFormulas.__init__
                original_styles_process = StylesAndFormulas.process

                def cached_parse(*args, **kwargs):
                    if not input_is_unchanged():
                        state["eligible"] = False
                        emit_cache_status("input_changed")
                        return original_parse(*args, **kwargs)
                    document = load_document()
                    if document is not None:
                        state["hit"] = True
                        translation_config = kwargs.get("config")
                        shared_context = getattr(
                            translation_config,
                            "shared_context_cross_split_part",
                            None,
                        )
                        if shared_context is not None:
                            shared_context.valid_char_count_total = state[
                                "valid_character_count"
                            ]
                            shared_context.total_valid_text_token_count = state[
                                "valid_token_count"
                            ]
                        complete_stage(
                            translation_config,
                            PARSE_STAGE,
                            expected_page_count,
                        )
                        emit_cache_status("hit")
                        return document
                    emit_cache_status("miss")
                    return original_parse(*args, **kwargs)

                def cached_layout_process(self, document, mupdf_document):
                    if state["hit"]:
                        complete_stage(
                            self.translation_config,
                            self.stage_name,
                            len(document.page) * 2,
                        )
                        return document
                    return original_layout_process(self, document, mupdf_document)

                def cached_paragraph_init(self, translation_config):
                    if state["hit"]:
                        self.translation_config = translation_config
                        return
                    original_paragraph_init(self, translation_config)

                def cached_paragraph_process(self, document):
                    if state["hit"]:
                        complete_stage(
                            self.translation_config,
                            self.stage_name,
                            len(document.page),
                        )
                        return None
                    return original_paragraph_process(self, document)

                def cached_styles_init(self, translation_config):
                    if state["hit"]:
                        self.translation_config = translation_config
                        return
                    original_styles_init(self, translation_config)

                def cached_styles_process(self, document):
                    if state["hit"]:
                        complete_stage(
                            self.translation_config,
                            self.stage_name,
                            len(document.page),
                        )
                        return None
                    result = original_styles_process(self, document)
                    store_document(document, self.translation_config)
                    return result

                native_parse.parse_prepared_pdf_with_new_parser_to_legacy_ir = cached_parse
                LayoutParser.process = cached_layout_process
                ParagraphFinder.__init__ = cached_paragraph_init
                ParagraphFinder.process = cached_paragraph_process
                StylesAndFormulas.__init__ = cached_styles_init
                StylesAndFormulas.process = cached_styles_process

            babeldoc.main.create_progress_handler = create_progress_handler
            install_font_asset_cache()
            install_layout_ir_cache()

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

    static let layoutCacheLinePrefix = "__GLOSS_BABELDOC_LAYOUT_CACHE__"

    static func layoutCacheStatus(in value: String) -> String? {
        value
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                guard let range = line.range(of: layoutCacheLinePrefix) else {
                    return nil
                }
                let status = line[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return status.isEmpty ? nil : status
            }
            .last
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
