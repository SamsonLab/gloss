import Foundation

public enum BabelDOCExecutorLifecycleState: String, Codable, Sendable {
    case stopped
    case starting
    case ready
    case reconnecting
    case stopping
    case failed
}

public struct BabelDOCExecutorExecutionSnapshot: Codable, Equatable, Sendable {
    public let executionID: String
    public let taskID: String
    public let status: String
    public let initialSequence: Int64
    public let firstAvailableSequence: Int64?
    public let lastSequence: Int64
    public let workerFinished: Bool
    public let createdAt: Double
    public let finishedAt: Double?

    enum CodingKeys: String, CodingKey {
        case executionID = "execution_id"
        case taskID = "task_id"
        case status
        case initialSequence = "initial_sequence"
        case firstAvailableSequence = "first_available_sequence"
        case lastSequence = "last_sequence"
        case workerFinished = "worker_finished"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
    }

    public var isTerminal: Bool {
        status == "succeeded" || status == "failed" || status == "cancelled"
    }
}

public struct BabelDOCExecutorServiceSnapshot: Equatable, Sendable {
    public let installed: Bool
    public let runtimeVersion: String?
    public let endpoint: URL?
    public let processIdentifier: Int32?
    public let processStartTime: Double?
    public let instanceID: String?
    public let lifecycleState: BabelDOCExecutorLifecycleState
    public let activeTaskID: String?
    public let activeExecutionID: String?
    public let activeStatus: String?
    public let activeProgress: Double?
    public let lastError: String?

    public init(
        installed: Bool,
        runtimeVersion: String? = nil,
        endpoint: URL? = nil,
        processIdentifier: Int32? = nil,
        processStartTime: Double? = nil,
        instanceID: String? = nil,
        lifecycleState: BabelDOCExecutorLifecycleState,
        activeTaskID: String? = nil,
        activeExecutionID: String? = nil,
        activeStatus: String? = nil,
        activeProgress: Double? = nil,
        lastError: String? = nil
    ) {
        self.installed = installed
        self.runtimeVersion = runtimeVersion
        self.endpoint = endpoint
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.instanceID = instanceID
        self.lifecycleState = lifecycleState
        self.activeTaskID = activeTaskID
        self.activeExecutionID = activeExecutionID
        self.activeStatus = activeStatus
        self.activeProgress = activeProgress
        self.lastError = lastError
    }
}

public struct BabelDOCExecutorConnection: Sendable {
    public let baseURL: URL
    public let bearerToken: String
    public let workrootURL: URL
    public let layoutServiceBaseURL: URL
    public let instanceID: String
    public let processIdentifier: Int32
    public let processStartTime: Double?
    public let parentProcessIdentifier: Int32?
    public let runtimeVersion: String
    let stateHandler: @Sendable (BabelDOCExecutorClientState) -> Void

    public init(
        baseURL: URL,
        bearerToken: String,
        workrootURL: URL,
        layoutServiceBaseURL: URL,
        instanceID: String,
        processIdentifier: Int32,
        processStartTime: Double? = nil,
        parentProcessIdentifier: Int32? = Int32(ProcessInfo.processInfo.processIdentifier),
        runtimeVersion: String
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workrootURL = workrootURL
        self.layoutServiceBaseURL = layoutServiceBaseURL
        self.instanceID = instanceID
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.parentProcessIdentifier = parentProcessIdentifier
        self.runtimeVersion = runtimeVersion
        self.stateHandler = { _ in }
    }

    init(
        baseURL: URL,
        bearerToken: String,
        workrootURL: URL,
        layoutServiceBaseURL: URL,
        instanceID: String,
        processIdentifier: Int32,
        processStartTime: Double?,
        parentProcessIdentifier: Int32? = Int32(ProcessInfo.processInfo.processIdentifier),
        runtimeVersion: String,
        _stateHandler: @escaping @Sendable (BabelDOCExecutorClientState) -> Void
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workrootURL = workrootURL
        self.layoutServiceBaseURL = layoutServiceBaseURL
        self.instanceID = instanceID
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.parentProcessIdentifier = parentProcessIdentifier
        self.runtimeVersion = runtimeVersion
        self.stateHandler = _stateHandler
    }
}

public protocol BabelDOCExecutorManaging: Sendable {
    func executorConnection(
        runtime: BabelDOCRuntimeLaunch,
        timeout: Duration
    ) async throws -> BabelDOCExecutorConnection
}

public enum BabelDOCLegacyFallbackPolicy: Equatable, Sendable {
    /// Only runtimes without the executor protocol may use the transitional CLI path.
    case unsupportedRuntimeOnly
    /// Require the authenticated executor for every translation.
    case never
}

public enum BabelDOCExecutorError: LocalizedError, Equatable, Sendable {
    case unsupportedRuntime
    case unavailable(String)
    case incompatibleRuntime(String)
    case authenticationFailed
    case invalidResponse(String)
    case serviceError(status: Int, code: String, message: String)
    case busy(BabelDOCExecutorExecutionSnapshot?)
    case replayGap(BabelDOCExecutorExecutionSnapshot?)
    case cursorAhead(BabelDOCExecutorExecutionSnapshot?)
    case executionFailed(code: String, message: String)
    case executionCancelled
    case outputMissing

    public var errorDescription: String? {
        switch self {
        case .unsupportedRuntime:
            "已安装的 BabelDOC 尚不支持常驻执行服务。"
        case .unavailable(let message):
            "BabelDOC 常驻执行服务不可用：\(message)"
        case .incompatibleRuntime(let message):
            "BabelDOC 运行时不兼容：\(message)"
        case .authenticationFailed:
            "BabelDOC 常驻执行服务认证失败。"
        case .invalidResponse(let message):
            "BabelDOC 常驻执行服务返回了无效响应：\(message)"
        case .serviceError(_, _, let message):
            "BabelDOC 常驻执行服务失败：\(message)"
        case .busy(let snapshot):
            if let taskID = snapshot?.taskID {
                "BabelDOC 正在处理任务 \(taskID)。"
            } else {
                "BabelDOC 正在处理其他任务。"
            }
        case .replayGap:
            "BabelDOC 进度历史已过期，正在使用权威任务快照恢复。"
        case .cursorAhead:
            "BabelDOC 进度游标与服务状态不一致。"
        case .executionFailed(_, let message):
            "BabelDOC 处理失败：\(message)"
        case .executionCancelled:
            "BabelDOC 任务已取消。"
        case .outputMissing:
            "BabelDOC 已结束，但没有生成可用的 PDF。"
        }
    }
}

struct BabelDOCExecutorClientState: Sendable {
    let taskID: String?
    let executionID: String?
    let status: String?
    let progress: Double?
    let error: String?
}

actor BabelDOCExecutorConnectionRegistry {
    static let shared = BabelDOCExecutorConnectionRegistry()

    private var connectionsByLayoutURL: [String: BabelDOCExecutorConnection] = [:]

    func register(_ connection: BabelDOCExecutorConnection) {
        connectionsByLayoutURL[Self.key(connection.layoutServiceBaseURL)] = connection
    }

    func unregister(layoutServiceBaseURL: URL) {
        connectionsByLayoutURL.removeValue(forKey: Self.key(layoutServiceBaseURL))
    }

    func connection(layoutServiceBaseURL: URL) -> BabelDOCExecutorConnection? {
        connectionsByLayoutURL[Self.key(layoutServiceBaseURL)]
    }

    private static func key(_ url: URL) -> String {
        url.absoluteURL.standardized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public struct BabelDOCExecutorRuntimeResponse: Decodable, Sendable {
    public struct Runtime: Decodable, Sendable {
        public let name: String
        public let version: String
    }

    public struct Service: Decodable, Sendable {
        public let serviceID: String
        public let instanceID: String
        public let pid: Int32
        public let processStartTime: Double?
        public let endpoint: String
        public let parentPID: Int32?
        public let parentStartTime: Double?

        enum CodingKeys: String, CodingKey {
            case serviceID = "service_id"
            case instanceID = "instance_id"
            case pid
            case processStartTime = "process_start_time"
            case endpoint
            case parentPID = "parent_pid"
            case parentStartTime = "parent_start_time"
        }
    }

    public let runtimeAPIVersion: Int
    public let runtime: Runtime
    public let capabilities: [String]
    public let service: Service

    enum CodingKeys: String, CodingKey {
        case runtimeAPIVersion = "runtime_api_version"
        case runtime
        case capabilities
        case service
    }
}

private struct BabelDOCExecutorHealthResponse: Decodable {
    let ok: Bool
    let serviceID: String
    let instanceID: String
    let pid: Int32
    let processStartTime: Double?
    let endpoint: String
    let parentPID: Int32?

    enum CodingKeys: String, CodingKey {
        case ok
        case serviceID = "service_id"
        case instanceID = "instance_id"
        case pid
        case processStartTime = "process_start_time"
        case endpoint
        case parentPID = "parent_pid"
    }
}

private struct BabelDOCExecutionContainer: Decodable {
    let execution: BabelDOCExecutorExecutionSnapshot?
}

private struct BabelDOCExecutionCreated: Decodable {
    let executionID: String
    let status: String
    let initialSequence: Int64
    let replayed: Bool

    enum CodingKeys: String, CodingKey {
        case executionID = "execution_id"
        case status
        case initialSequence = "initial_sequence"
        case replayed
    }
}

private struct BabelDOCExecutorErrorPayload: Decodable {
    let code: String
    let message: String
    let snapshot: BabelDOCExecutorExecutionSnapshot?
}

private struct BabelDOCExecutorEvent: Decodable {
    let schemaVersion: Int
    let serviceID: String
    let instanceID: String
    let type: String
    let executionID: String
    let sequence: Int64?
    let payload: JSONValue

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case serviceID = "service_id"
        case instanceID = "instance_id"
        case type
        case executionID = "execution_id"
        case sequence
        case payload
    }
}

private struct BabelDOCExecutorPerformance: Decodable {
    struct PhaseTimings: Decodable {
        let launching: Int
        let parsing: Int
        let translating: Int
        let typesetting: Int
        let saving: Int
        let finalizing: Int
    }

    let phase: String
    let elapsedMilliseconds: Int
    let phaseTimingsMilliseconds: PhaseTimings
    let layoutIRCacheStatus: String?

    enum CodingKeys: String, CodingKey {
        case phase
        case elapsedMilliseconds = "elapsed_milliseconds"
        case phaseTimingsMilliseconds = "phase_timings_milliseconds"
        case layoutIRCacheStatus = "layout_ir_cache_status"
    }

    var timings: BabelDOCPhaseTimings {
        BabelDOCPhaseTimings(
            launchingMilliseconds: phaseTimingsMilliseconds.launching,
            parsingMilliseconds: phaseTimingsMilliseconds.parsing,
            translatingMilliseconds: phaseTimingsMilliseconds.translating,
            typesettingMilliseconds: phaseTimingsMilliseconds.typesetting,
            savingMilliseconds: phaseTimingsMilliseconds.saving,
            finalizingMilliseconds: phaseTimingsMilliseconds.finalizing
        )
    }
}

private struct BabelDOCExecutionRequestBody: Encodable {
    struct Paths: Encodable {
        let inputFile: String
        let outputDir: String
        let workingDir: String

        enum CodingKeys: String, CodingKey {
            case inputFile = "input_file"
            case outputDir = "output_dir"
            case workingDir = "working_dir"
        }
    }

    struct TranslationConfiguration: Encodable {
        let debug = false
        let langIn: String
        let langOut: String
        let pages: String? = nil
        let noDual: Bool
        let noMono: Bool
        let skipClean: Bool
        let dualTranslateFirst = false
        let disableRichTextTranslate = true
        let useSideBySideDual = false
        let useAlternatingPagesDual = false
        let skipScannedDetection: Bool
        let ocrWorkaround = false
        let customSystemPrompt: String? = nil
        let primaryFontFamily: String? = nil
        let autoExtractGlossary = false
        let autoEnableOCRWorkaround = false
        let onlyIncludeTranslatedPage = false
        let mergeAlternatingLineNumbers = true
        let removeNonFormulaLines = false

        enum CodingKeys: String, CodingKey {
            case debug
            case langIn = "lang_in"
            case langOut = "lang_out"
            case pages
            case noDual = "no_dual"
            case noMono = "no_mono"
            case skipClean = "skip_clean"
            case dualTranslateFirst = "dual_translate_first"
            case disableRichTextTranslate = "disable_rich_text_translate"
            case useSideBySideDual = "use_side_by_side_dual"
            case useAlternatingPagesDual = "use_alternating_pages_dual"
            case skipScannedDetection = "skip_scanned_detection"
            case ocrWorkaround = "ocr_workaround"
            case customSystemPrompt = "custom_system_prompt"
            case primaryFontFamily = "primary_font_family"
            case autoExtractGlossary = "auto_extract_glossary"
            case autoEnableOCRWorkaround = "auto_enable_ocr_workaround"
            case onlyIncludeTranslatedPage = "only_include_translated_page"
            case mergeAlternatingLineNumbers = "merge_alternating_line_numbers"
            case removeNonFormulaLines = "remove_non_formula_lines"
        }
    }

    struct RuntimeLimits: Encodable {
        let qps: Int
        let reportIntervalSeconds: Double
        let maxPagesPerPart: Int
        let poolMaxWorkers: Int
        let termPoolMaxWorkers: Int

        enum CodingKeys: String, CodingKey {
            case qps
            case reportIntervalSeconds = "report_interval_seconds"
            case maxPagesPerPart = "max_pages_per_part"
            case poolMaxWorkers = "pool_max_workers"
            case termPoolMaxWorkers = "term_pool_max_workers"
        }
    }

    struct Gateway: Encodable {
        let model: String
        let baseURL: String
        let apiKey: String

        enum CodingKeys: String, CodingKey {
            case model
            case baseURL = "base_url"
            case apiKey = "api_key"
        }
    }

    struct LayoutGateway: Encodable {
        let adapter = "rpc_doclayout8"
        let baseURL: String
        let requiresLineExtraction = false

        enum CodingKeys: String, CodingKey {
            case adapter
            case baseURL = "base_url"
            case requiresLineExtraction = "requires_line_extraction"
        }
    }

    struct Gateways: Encodable {
        let mainLLM: Gateway
        let ateLLM: Gateway
        let layout: LayoutGateway

        enum CodingKeys: String, CodingKey {
            case mainLLM = "main_llm"
            case ateLLM = "ate_llm"
            case layout
        }
    }

    struct Assets: Encodable {
        struct LayoutIRCache: Encodable {
            let enabled: Bool
        }

        let glossaries: [String] = []
        let layoutIRCache: LayoutIRCache

        enum CodingKeys: String, CodingKey {
            case glossaries
            case layoutIRCache = "layout_ir_cache"
        }
    }

    struct Metadata: Encodable {
        let metadataExtraData: String? = nil

        enum CodingKeys: String, CodingKey {
            case metadataExtraData = "metadata_extra_data"
        }
    }

    let taskID: String
    let paths: Paths
    let translationConfig: TranslationConfiguration
    let runtimeLimits: RuntimeLimits
    let gateways: Gateways
    let assets: Assets
    let metadata = Metadata()

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case paths
        case translationConfig = "translation_config"
        case runtimeLimits = "runtime_limits"
        case gateways
        case assets
        case metadata
    }
}

private final class BabelDOCExecutionIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ newValue: String) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class BabelDOCJobCleanupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var removeJobDirectory = true

    func preserve() {
        lock.lock()
        removeJobDirectory = false
        lock.unlock()
    }

    func shouldRemove() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return removeJobDirectory
    }
}

public struct BabelDOCExecutorClient: Sendable {
    private static let eventStreamRequestTimeout: TimeInterval = 24 * 60 * 60

    public let connection: BabelDOCExecutorConnection
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        connection: BabelDOCExecutorConnection,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.connection = connection
        let configuration =
            sessionConfiguration.copy() as? URLSessionConfiguration
            ?? sessionConfiguration
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Cache-Control": "no-store",
        ]
        self.session = URLSession(configuration: configuration)
    }

    public func runtime(
        requireCurrentParent: Bool = true
    ) async throws -> BabelDOCExecutorRuntimeResponse {
        let response: BabelDOCExecutorRuntimeResponse = try await json(
            method: "GET",
            path: "/v1/runtime"
        )
        try Self.validateRuntime(
            response,
            connection: connection,
            requireCurrentParent: requireCurrentParent
        )
        return response
    }

    public func health(requireCurrentParent: Bool = true) async throws -> Bool {
        let response: BabelDOCExecutorHealthResponse = try await json(
            method: "GET",
            path: "/healthz"
        )
        guard response.ok,
            response.serviceID == "gloss-babeldoc",
            response.instanceID == connection.instanceID,
            response.pid == connection.processIdentifier,
            URL(string: response.endpoint) == connection.baseURL
        else {
            throw BabelDOCExecutorError.incompatibleRuntime(
                "服务身份与已保存会话不一致"
            )
        }
        let expectedParent =
            requireCurrentParent
            ? Int32(ProcessInfo.processInfo.processIdentifier)
            : connection.parentProcessIdentifier
        if let expectedParent, response.parentPID != expectedParent {
            throw BabelDOCExecutorError.incompatibleRuntime("服务父进程身份不一致")
        }
        if let expected = connection.processStartTime,
            let actual = response.processStartTime,
            abs(expected - actual) > 0.01
        {
            throw BabelDOCExecutorError.incompatibleRuntime("进程启动时间不一致")
        }
        return true
    }

    public func currentExecution() async throws -> BabelDOCExecutorExecutionSnapshot? {
        let response: BabelDOCExecutionContainer = try await json(
            method: "GET",
            path: "/v1/executions/current"
        )
        return response.execution
    }

    public func latestExecution() async throws -> BabelDOCExecutorExecutionSnapshot? {
        let response: BabelDOCExecutionContainer = try await json(
            method: "GET",
            path: "/v1/executions/latest"
        )
        return response.execution
    }

    public func execution(
        id: String
    ) async throws -> BabelDOCExecutorExecutionSnapshot {
        try await json(method: "GET", path: "/v1/executions/\(id)")
    }

    @discardableResult
    public func cancel(
        executionID: String
    ) async throws -> BabelDOCExecutorExecutionSnapshot {
        try await json(
            method: "POST",
            path: "/v1/executions/\(executionID)/cancel",
            body: Data("{}".utf8)
        )
    }

    public func cancelCurrent() async throws {
        guard let current = try await currentExecution() else { return }
        _ = try await cancel(executionID: current.executionID)
    }

    public func shutdown(cancelActive: Bool = true) async throws {
        struct ShutdownBody: Encodable {
            let cancelActive: Bool

            enum CodingKeys: String, CodingKey {
                case cancelActive = "cancel_active"
            }
        }
        struct ShutdownResponse: Decodable {
            let status: String
        }
        let body = try encoder.encode(ShutdownBody(cancelActive: cancelActive))
        let response: ShutdownResponse = try await json(
            method: "POST",
            path: "/v1/shutdown",
            body: body
        )
        guard response.status == "stopping" else {
            throw BabelDOCExecutorError.invalidResponse("shutdown status")
        }
    }

    func translate(
        _ request: BabelDOCTranslationRequest,
        onOutput: (@Sendable (String) -> Void)?,
        onProgress: (@Sendable (BabelDOCProgressUpdate) -> Void)?
    ) async throws -> BabelDOCTranslationResult {
        let taskID = "gloss-\(UUID().uuidString.lowercased())"
        let jobDirectory = connection.workrootURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
        let inputDirectory = jobDirectory.appendingPathComponent("input", isDirectory: true)
        let executorOutput = jobDirectory.appendingPathComponent("output", isDirectory: true)
        let executorWorking = jobDirectory.appendingPathComponent("working", isDirectory: true)
        let stagedInput = inputDirectory.appendingPathComponent(
            request.inputURL.lastPathComponent.isEmpty ? "input.pdf" : request.inputURL.lastPathComponent
        )
        try Self.preparePrivateDirectory(inputDirectory)
        try Self.preparePrivateDirectory(executorOutput)
        try Self.preparePrivateDirectory(executorWorking)
        do {
            try FileManager.default.copyItem(at: request.inputURL, to: stagedInput)
        } catch {
            try? FileManager.default.removeItem(at: jobDirectory)
            throw error
        }
        let jobCleanup = BabelDOCJobCleanupBox()
        defer {
            if jobCleanup.shouldRemove() {
                try? FileManager.default.removeItem(at: jobDirectory)
            }
        }

        let relativeInput = try Self.relative(stagedInput, to: connection.workrootURL)
        let relativeOutput = try Self.relative(executorOutput, to: connection.workrootURL)
        let relativeWorking = try Self.relative(executorWorking, to: connection.workrootURL)
        let gateway = BabelDOCExecutionRequestBody.Gateway(
            model: "gloss-provider",
            baseURL: request.bridgeBaseURL.absoluteString,
            apiKey: request.bridgeToken
        )
        let body = BabelDOCExecutionRequestBody(
            taskID: taskID,
            paths: .init(
                inputFile: relativeInput,
                outputDir: relativeOutput,
                workingDir: relativeWorking
            ),
            translationConfig: .init(
                langIn: request.sourceLanguageCode.lowercased(),
                langOut: request.targetLanguageCode,
                noDual: request.outputMode == .monolingual,
                noMono: request.outputMode == .bilingual,
                skipClean:
                    ProcessInfo.processInfo.environment["GLOSS_BABELDOC_SKIP_CLEAN"] == "1",
                skipScannedDetection: request.skipScannedDetection
            ),
            runtimeLimits: .init(
                qps: request.qps,
                reportIntervalSeconds: 0.25,
                maxPagesPerPart: request.maximumPagesPerPart,
                poolMaxWorkers: request.qps,
                termPoolMaxWorkers: request.qps
            ),
            gateways: .init(
                mainLLM: gateway,
                ateLLM: gateway,
                layout: .init(baseURL: connection.layoutServiceBaseURL.absoluteString)
            ),
            assets: .init(
                layoutIRCache: .init(enabled: request.layoutCacheDirectoryURL != nil)
            )
        )
        let executionID = BabelDOCExecutionIDBox()
        let timeline = BabelDOCExternalEngine.ProgressTimeline()
        onProgress?(timeline.initialUpdate())
        connection.stateHandler(
            .init(
                taskID: taskID,
                executionID: nil,
                status: "submitting",
                progress: 0,
                error: nil
            )
        )

        return try await withTaskCancellationHandler {
            do {
                let created: BabelDOCExecutionCreated = try await json(
                    method: "POST",
                    path: "/v1/executions",
                    body: try encoder.encode(body)
                )
                executionID.set(created.executionID)
                connection.stateHandler(
                    .init(
                        taskID: taskID,
                        executionID: created.executionID,
                        status: created.status,
                        progress: 0,
                        error: nil
                    )
                )
                let resultPayload = try await consumeEvents(
                    executionID: created.executionID,
                    initialSequence: created.initialSequence,
                    executorOutput: executorOutput,
                    timeline: timeline,
                    onOutput: onOutput,
                    onProgress: onProgress
                )
                let result = try materializeResult(
                    resultPayload,
                    executorOutput: executorOutput,
                    destination: request.outputDirectory,
                    timeline: timeline,
                    onProgress: onProgress
                )
                connection.stateHandler(
                    .init(
                        taskID: taskID,
                        executionID: created.executionID,
                        status: "succeeded",
                        progress: 100,
                        error: nil
                    )
                )
                return result
            } catch is CancellationError {
                let reachedTerminal = await waitForCancelledWorker(
                    executionID: executionID.get(),
                    taskID: taskID
                )
                if !reachedTerminal {
                    jobCleanup.preserve()
                }
                connection.stateHandler(
                    .init(
                        taskID: taskID,
                        executionID: executionID.get(),
                        status: "cancelled",
                        progress: nil,
                        error: nil
                    )
                )
                throw CancellationError()
            } catch BabelDOCExecutorError.executionCancelled {
                let reachedTerminal = await waitForCancelledWorker(
                    executionID: executionID.get(),
                    taskID: taskID
                )
                if !reachedTerminal {
                    jobCleanup.preserve()
                }
                connection.stateHandler(
                    .init(
                        taskID: taskID,
                        executionID: executionID.get(),
                        status: "cancelled",
                        progress: nil,
                        error: nil
                    )
                )
                throw CancellationError()
            } catch {
                let reachedTerminal = await waitForCancelledWorker(
                    executionID: executionID.get(),
                    taskID: taskID
                )
                if !reachedTerminal {
                    jobCleanup.preserve()
                }
                connection.stateHandler(
                    .init(
                        taskID: taskID,
                        executionID: executionID.get(),
                        status: "failed",
                        progress: nil,
                        error: error.localizedDescription
                    )
                )
                throw error
            }
        } onCancel: {
            guard let value = executionID.get() else { return }
            Task {
                _ = try? await cancel(executionID: value)
            }
        }
    }

    func waitForCancelledWorker(
        executionID: String?,
        taskID: String,
        registrationTimeout: Duration = .seconds(1),
        registrationPollInterval: Duration = .milliseconds(50)
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            var resolvedExecutionID = executionID
            if resolvedExecutionID == nil {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: registrationTimeout)
                while resolvedExecutionID == nil {
                    if let current = try? await self.currentExecution(),
                        current.taskID == taskID
                    {
                        resolvedExecutionID = current.executionID
                        break
                    }
                    guard clock.now < deadline else {
                        return false
                    }
                    try? await Task.sleep(for: registrationPollInterval)
                }
            }
            guard let resolvedExecutionID else {
                return false
            }

            _ = try? await self.cancel(executionID: resolvedExecutionID)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while clock.now < deadline {
                if let snapshot = try? await self.execution(id: resolvedExecutionID),
                    snapshot.isTerminal,
                    snapshot.workerFinished
                {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }.value
    }

    private func consumeEvents(
        executionID: String,
        initialSequence: Int64,
        executorOutput: URL,
        timeline: BabelDOCExternalEngine.ProgressTimeline,
        onOutput: (@Sendable (String) -> Void)?,
        onProgress: (@Sendable (BabelDOCProgressUpdate) -> Void)?
    ) async throws -> JSONValue? {
        var cursor = initialSequence
        var reconnectAttempts = 0
        while true {
            try Task.checkCancellation()
            do {
                var receivedEvent = false
                let events = eventStream(
                    executionID: executionID,
                    afterSequence: cursor
                )
                for try await event in events {
                    receivedEvent = true
                    reconnectAttempts = 0
                    guard event.schemaVersion == 1,
                        event.serviceID == "gloss-babeldoc",
                        event.instanceID == connection.instanceID,
                        event.executionID == executionID
                    else {
                        throw BabelDOCExecutorError.incompatibleRuntime(
                            "事件流服务身份不一致"
                        )
                    }
                    if let sequence = event.sequence {
                        guard sequence > cursor else { continue }
                        cursor = sequence
                    }
                    if event.type != "heartbeat" {
                        let line =
                            try String(
                                data: encoder.encode(event.payload),
                                encoding: .utf8
                            ) ?? ""
                        if !line.isEmpty {
                            onOutput?(line + "\n")
                        }
                    }
                    switch event.type {
                    case "progress":
                        if let update =
                            Self.performanceProgress(from: event.payload)
                            ?? Self.progressEvent(from: event.payload)
                            .flatMap(timeline.update)
                        {
                            onProgress?(update)
                            connection.stateHandler(
                                .init(
                                    taskID: nil,
                                    executionID: executionID,
                                    status: "running",
                                    progress: update.overallProgress,
                                    error: nil
                                )
                            )
                        }
                    case "result":
                        return event.payload
                    case "error":
                        let code = event.payload["code"]?.stringValue ?? "babeldoc_failed"
                        let message =
                            event.payload["message_for_user"]?.stringValue
                            ?? event.payload["message"]?.stringValue
                            ?? "translation failed"
                        throw BabelDOCExecutorError.executionFailed(
                            code: code,
                            message: message
                        )
                    case "cancelled":
                        throw BabelDOCExecutorError.executionCancelled
                    case "stream_error":
                        let snapshot = try Self.snapshot(from: event.payload["snapshot"])
                        if let snapshot, snapshot.isTerminal {
                            return try terminalRecovery(
                                snapshot,
                                executorOutput: executorOutput
                            )
                        }
                        throw BabelDOCExecutorError.replayGap(snapshot)
                    default:
                        continue
                    }
                }
                if !receivedEvent {
                    let snapshot = try await execution(id: executionID)
                    if snapshot.isTerminal {
                        return try terminalRecovery(snapshot, executorOutput: executorOutput)
                    }
                    try await Task.sleep(for: .milliseconds(150))
                }
            } catch let error as BabelDOCExecutorError {
                switch error {
                case .replayGap(let snapshot), .cursorAhead(let snapshot):
                    if let snapshot, snapshot.isTerminal {
                        return try terminalRecovery(snapshot, executorOutput: executorOutput)
                    }
                    throw error
                case .unavailable where reconnectAttempts < 3:
                    reconnectAttempts += 1
                    try await Task.sleep(
                        for: .milliseconds(150 * reconnectAttempts)
                    )
                    continue
                default:
                    throw error
                }
            } catch  where reconnectAttempts < 3 {
                reconnectAttempts += 1
                let snapshot = try? await execution(id: executionID)
                if let snapshot, snapshot.isTerminal {
                    return try terminalRecovery(snapshot, executorOutput: executorOutput)
                }
                try await Task.sleep(for: .milliseconds(150 * reconnectAttempts))
            }
        }
    }

    private func eventStream(
        executionID: String,
        afterSequence: Int64
    ) -> AsyncThrowingStream<BabelDOCExecutorEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let path =
                    "/v1/executions/\(executionID)/events?after_sequence=\(afterSequence)"
                do {
                    var request = try makeRequest(method: "GET", path: path)
                    // Translation streams are intentionally quiet while a model or
                    // typesetter is working. Keep control requests fail-fast, but
                    // let this authenticated local stream live for the job.
                    request.timeoutInterval = Self.eventStreamRequestTimeout
                    let (bytes, rawResponse) = try await session.bytes(for: request)
                    guard let response = rawResponse as? HTTPURLResponse else {
                        throw BabelDOCExecutorError.invalidResponse("缺少 HTTP 响应")
                    }
                    if response.statusCode == 410 || response.statusCode == 409 {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                        }
                        let payload = try? decoder.decode(
                            BabelDOCExecutorErrorPayload.self,
                            from: body
                        )
                        if response.statusCode == 410 {
                            throw BabelDOCExecutorError.replayGap(payload?.snapshot)
                        }
                        throw BabelDOCExecutorError.cursorAhead(payload?.snapshot)
                    }
                    guard (200...299).contains(response.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                        }
                        try validate(response: response, data: body)
                        throw BabelDOCExecutorError.invalidResponse("空错误响应")
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let data = line.data(using: .utf8) else {
                            continue
                        }
                        continuation.yield(
                            try decoder.decode(BabelDOCExecutorEvent.self, from: data)
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func terminalRecovery(
        _ snapshot: BabelDOCExecutorExecutionSnapshot,
        executorOutput: URL
    ) throws -> JSONValue? {
        switch snapshot.status {
        case "succeeded":
            guard
                let discovered = try? BabelDOCExternalEngine.discoverOutputs(
                    in: executorOutput
                ),
                discovered.monolingualPDF != nil || discovered.bilingualPDF != nil
            else {
                throw BabelDOCExecutorError.outputMissing
            }
            return nil
        case "cancelled":
            throw BabelDOCExecutorError.executionCancelled
        case "failed":
            throw BabelDOCExecutorError.executionFailed(
                code: "babeldoc_failed",
                message: "任务失败，且终端事件已不在服务的重放窗口中"
            )
        default:
            throw BabelDOCExecutorError.replayGap(snapshot)
        }
    }

    private func materializeResult(
        _ payload: JSONValue?,
        executorOutput: URL,
        destination: URL,
        timeline: BabelDOCExternalEngine.ProgressTimeline,
        onProgress: (@Sendable (BabelDOCProgressUpdate) -> Void)?
    ) throws -> BabelDOCTranslationResult {
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        var mono: URL?
        var dual: URL?
        if let files = payload?["files"], case .object(let object) = files {
            mono = try materialize(
                object["mono_no_watermark_pdf"] ?? object["mono_pdf"],
                destination: destination
            )
            dual = try materialize(
                object["dual_no_watermark_pdf"] ?? object["dual_pdf"],
                destination: destination
            )
        } else {
            let discovered = try BabelDOCExternalEngine.discoverOutputs(in: executorOutput)
            mono = try copy(discovered.monolingualPDF, to: destination)
            dual = try copy(discovered.bilingualPDF, to: destination)
        }
        guard mono != nil || dual != nil else {
            throw BabelDOCExecutorError.outputMissing
        }
        let completed = timeline.finish()
        let performance = Self.performance(from: payload?["performance"])
        let finalUpdate =
            performance.map {
                BabelDOCProgressUpdate(
                    phase: .completed,
                    overallProgress: 100,
                    elapsedMilliseconds: $0.elapsedMilliseconds,
                    timings: $0.timings
                )
            } ?? completed
        onProgress?(finalUpdate)
        let cacheStatus =
            performance?.layoutIRCacheStatus
            ?? payload?["layout_cache_status"]?.stringValue
            ?? payload?["metrics"]?["layout_cache_status"]?.stringValue
        return BabelDOCTranslationResult(
            monolingualPDF: mono,
            bilingualPDF: dual,
            log: "",
            timings: finalUpdate.timings,
            layoutCacheStatus: cacheStatus
        )
    }

    private func materialize(
        _ value: JSONValue?,
        destination: URL
    ) throws -> URL? {
        guard let relativePath = value?.stringValue else { return nil }
        let source = connection.workrootURL.appendingPathComponent(relativePath)
        let canonicalRoot = connection.workrootURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        let prefix =
            canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        guard canonicalSource.path.hasPrefix(prefix),
            FileManager.default.isReadableFile(atPath: canonicalSource.path)
        else {
            throw BabelDOCExecutorError.invalidResponse("输出文件越过 workroot")
        }
        return try copy(canonicalSource, to: destination)
    }

    private func copy(_ source: URL?, to destination: URL) throws -> URL? {
        guard let source else { return nil }
        let target = destination.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    private func json<T: Decodable>(
        method: String,
        path: String,
        body: Data? = nil
    ) async throws -> T {
        let (data, response) = try await data(method: method, path: path, body: body)
        try validate(response: response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BabelDOCExecutorError.invalidResponse(error.localizedDescription)
        }
    }

    private func data(
        method: String,
        path: String,
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try makeRequest(method: method, path: path, body: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw BabelDOCExecutorError.invalidResponse("缺少 HTTP 响应")
            }
            return (data, response)
        } catch let error as BabelDOCExecutorError {
            throw error
        } catch {
            throw BabelDOCExecutorError.unavailable(error.localizedDescription)
        }
    }

    private func makeRequest(
        method: String,
        path: String,
        body: Data? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: connection.baseURL)?.absoluteURL else {
            throw BabelDOCExecutorError.invalidResponse("无效服务 URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(
            "Bearer \(connection.bearerToken)",
            forHTTPHeaderField: "Authorization"
        )
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        if response.statusCode == 401 {
            throw BabelDOCExecutorError.authenticationFailed
        }
        let payload = try? decoder.decode(BabelDOCExecutorErrorPayload.self, from: data)
        if response.statusCode == 409, payload?.code == "busy" {
            throw BabelDOCExecutorError.busy(payload?.snapshot)
        }
        throw BabelDOCExecutorError.serviceError(
            status: response.statusCode,
            code: payload?.code ?? "http_\(response.statusCode)",
            message: payload?.message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        )
    }

    static func validateRuntime(
        _ response: BabelDOCExecutorRuntimeResponse,
        connection: BabelDOCExecutorConnection,
        requireCurrentParent: Bool = true
    ) throws {
        let requiredCapabilities = [
            "executor.http.v1",
            "executor.events.ndjson.v1",
            "layout.rpc-doclayout8.v1",
            "runtime-info.v1",
        ]
        guard response.runtimeAPIVersion == 1,
            response.runtime.name == "gloss-babeldoc",
            response.service.serviceID == "gloss-babeldoc",
            response.service.instanceID == connection.instanceID,
            response.service.pid == connection.processIdentifier,
            requiredCapabilities.allSatisfy(response.capabilities.contains)
        else {
            throw BabelDOCExecutorError.incompatibleRuntime(
                "缺少 v1 executor 能力或服务身份不匹配"
            )
        }
        let expectedParent =
            requireCurrentParent
            ? Int32(ProcessInfo.processInfo.processIdentifier)
            : connection.parentProcessIdentifier
        if let expectedParent, response.service.parentPID != expectedParent {
            throw BabelDOCExecutorError.incompatibleRuntime("服务父进程身份不匹配")
        }
    }

    private static func progressEvent(
        from payload: JSONValue
    ) -> BabelDOCExternalEngine.ProgressWireEvent? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return try? JSONDecoder().decode(
            BabelDOCExternalEngine.ProgressWireEvent.self,
            from: data
        )
    }

    private static func performance(
        from value: JSONValue?
    ) -> BabelDOCExecutorPerformance? {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONDecoder().decode(BabelDOCExecutorPerformance.self, from: data)
    }

    private static func performanceProgress(
        from payload: JSONValue
    ) -> BabelDOCProgressUpdate? {
        guard let performance = performance(from: payload["performance"]),
            let phase = BabelDOCTranslationPhase(rawValue: performance.phase)
        else { return nil }
        return BabelDOCProgressUpdate(
            phase: phase,
            stageName: payload["stage"]?.stringValue,
            overallProgress:
                payload["overall_progress"].flatMap {
                    if case .number(let value) = $0 { value } else { nil }
                } ?? 0,
            stageCurrent: payload["stage_current"]?.intValue,
            stageTotal: payload["stage_total"]?.intValue,
            partIndex: payload["part_index"]?.intValue,
            totalParts: payload["total_parts"]?.intValue,
            elapsedMilliseconds: performance.elapsedMilliseconds,
            timings: performance.timings
        )
    }

    private static func snapshot(
        from value: JSONValue?
    ) throws -> BabelDOCExecutorExecutionSnapshot? {
        guard let value, value != .null else { return nil }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(
            BabelDOCExecutorExecutionSnapshot.self,
            from: data
        )
    }

    private static func preparePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private static func relative(_ url: URL, to root: URL) throws -> String {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath =
            canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        guard canonicalURL.path.hasPrefix(rootPath) else {
            throw BabelDOCExecutorError.invalidResponse("任务路径越过 workroot")
        }
        return String(canonicalURL.path.dropFirst(rootPath.count))
    }
}
