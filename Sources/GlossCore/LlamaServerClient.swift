import Darwin
import Foundation

public struct LlamaBackendStatus: Sendable {
    public let isRunning: Bool
    public let model: String
    public let lastError: String?

    public init(isRunning: Bool, model: String, lastError: String?) {
        self.isRunning = isRunning
        self.model = model
        self.lastError = lastError
    }
}

struct LlamaRuntimeLaunch: Equatable, Sendable {
    let executable: String
    let source: String
}

public actor LlamaServerClient: TranslationBackend {
    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let stream = false

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
            case stream
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private struct ErrorResponse: Decodable {
        struct ErrorBody: Decodable {
            let message: String
        }

        let error: ErrorBody
    }

    private static let alias = "gloss-local"
    private static let maximumRecentOutputBytes = 16_384

    private let environment: [String: String]
    private let glossaryStore: GlossaryStore
    private let modelReference: String
    private let startupTimeout: Duration
    private let requestTimeout: TimeInterval
    private let session: URLSession
    private var process: Process?
    private var endpoint: URL?
    private var apiKey = ""
    private var recentOutput = Data()
    private var startupTask: Task<Void, Error>?
    private var processGeneration = UUID()
    private var lastError: String?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        glossaryStore: GlossaryStore = GlossaryStore(),
        model: String = TranslationProviderConfiguration.defaultLlamaModel,
        startupTimeoutSeconds: TimeInterval = 600,
        requestTimeoutSeconds: TimeInterval = 120
    ) {
        self.environment = environment
        self.glossaryStore = glossaryStore
        self.modelReference = Self.nonBlank(environment["GLOSS_LLAMA_MODEL"]) ?? model
        self.startupTimeout = .seconds(max(1, startupTimeoutSeconds))
        self.requestTimeout = max(1, requestTimeoutSeconds)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func translate(_ request: TranslationBatchRequest) async throws -> [TranslationOutput] {
        try await translate(request, onOutput: nil)
    }

    public func translate(
        _ request: TranslationBatchRequest,
        onOutput: @escaping @Sendable (TranslationOutput) -> Void
    ) async throws -> [TranslationOutput] {
        try await translate(request, onOutput: Optional(onOutput))
    }

    private func translate(
        _ request: TranslationBatchRequest,
        onOutput: (@Sendable (TranslationOutput) -> Void)?
    ) async throws -> [TranslationOutput] {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        GlossRuntimeLog.shared.write(
            "llama",
            "translation_start items=\(request.items.count) chars=\(request.items.reduce(0) { $0 + $1.text.count })"
        )
        try await ensureReady()
        let glossary =
            (try? await glossaryStore.matchingTerms(in: request.items.map(\.text))) ?? []

        do {
            let outputs = try await withThrowingTaskGroup(of: TranslationOutput.self) { group in
                for item in request.items {
                    group.addTask { [self] in
                        let text = try await translateItem(
                            item,
                            request: request,
                            glossary: glossary
                        )
                        return TranslationOutput(id: item.id, text: text)
                    }
                }

                var outputsByID: [String: TranslationOutput] = [:]
                for try await output in group {
                    outputsByID[output.id] = output
                    onOutput?(output)
                }
                return try request.items.map { item in
                    guard let output = outputsByID[item.id] else {
                        throw TranslationError.invalidResponse("本地模型缺少项目 \(item.id)。")
                    }
                    return output
                }
            }
            GlossRuntimeLog.shared.write(
                "llama",
                "translation_complete items=\(outputs.count) duration_ms=\(Self.elapsedMilliseconds(since: startedAt))"
            )
            return outputs
        } catch {
            lastError = error.localizedDescription
            GlossRuntimeLog.shared.write(
                "llama",
                "translation_failed duration_ms=\(Self.elapsedMilliseconds(since: startedAt)) error=\(error.localizedDescription)"
            )
            throw error
        }
    }

    public func prewarm() async throws {
        try await ensureReady()
    }

    public func status() -> LlamaBackendStatus {
        LlamaBackendStatus(
            isRunning: process?.isRunning == true && endpoint != nil,
            model: modelReference,
            lastError: lastError
        )
    }

    public func stop() {
        startupTask?.cancel()
        startupTask = nil
        endpoint = nil
        apiKey = ""
        recentOutput.removeAll(keepingCapacity: false)
        let runningProcess = process
        process = nil
        processGeneration = UUID()
        if let pipe = runningProcess?.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if let pipe = runningProcess?.standardError as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
        GlossRuntimeLog.shared.write("llama", "stop")
    }

    private func ensureReady() async throws {
        if process?.isRunning == true, endpoint != nil, await isHealthy() {
            return
        }
        if let startupTask {
            return try await startupTask.value
        }

        let task = Task { try await self.launchAndWaitUntilReady() }
        startupTask = task
        do {
            try await task.value
            startupTask = nil
        } catch {
            startupTask = nil
            lastError = error.localizedDescription
            stop()
            throw error
        }
    }

    private func launchAndWaitUntilReady() async throws {
        guard let runtime = Self.resolveRuntime(environment: environment) else {
            throw TranslationError.backendUnavailable(
                "未找到 llama-server。请安装 llama.cpp，或设置 GLOSS_LLAMA_SERVER_BIN。"
            )
        }

        let port = try Self.availableLoopbackPort()
        guard let endpoint = URL(string: "http://127.0.0.1:\(port)") else {
            throw TranslationError.backendUnavailable("无法创建本地模型地址。")
        }
        let apiKey = UUID().uuidString
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let generation = UUID()

        var arguments = [
            "--host", "127.0.0.1",
            "--port", String(port),
            "--api-key", apiKey,
            "--alias", Self.alias,
            "--no-webui",
            "--cache-ram", "256",
            "--ctx-size", "4096",
            "--parallel", "2",
            "--gpu-layers", "99",
        ]
        if FileManager.default.fileExists(atPath: modelReference) {
            arguments += ["--model", modelReference]
        } else {
            arguments += ["--hf-repo", modelReference]
        }

        process.executableURL = URL(fileURLWithPath: runtime.executable)
        process.arguments = arguments
        process.environment = CodexAppServerClient.makeProcessEnvironment(
            environment,
            executable: runtime.executable
        )
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.qualityOfService = .userInitiated
        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receiveProcessOutput(data, generation: generation) }
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receiveProcessOutput(data, generation: generation) }
        }
        process.terminationHandler = { [weak self] process in
            Task {
                await self?.processExited(
                    code: process.terminationStatus,
                    generation: generation
                )
            }
        }

        GlossRuntimeLog.shared.write(
            "llama",
            "launch_start source=\(runtime.source) model=\(modelReference)"
        )
        do {
            try process.run()
        } catch {
            throw TranslationError.backendUnavailable(error.localizedDescription)
        }

        self.process = process
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.processGeneration = generation
        self.recentOutput.removeAll(keepingCapacity: true)
        self.lastError = nil

        let deadline = ContinuousClock.now.advanced(by: startupTimeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw TranslationError.backendUnavailable(processFailureReason())
            }
            if await isHealthy() {
                GlossRuntimeLog.shared.write(
                    "llama",
                    "server_ready pid=\(process.processIdentifier) model=\(modelReference)"
                )
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw TranslationError.timedOut("llama-server startup")
    }

    private func translateItem(
        _ item: TranslationItem,
        request: TranslationBatchRequest,
        glossary: [GlossaryTerm]
    ) async throws -> String {
        guard let endpoint else {
            throw TranslationError.backendUnavailable("llama-server 未运行。")
        }
        let prompt = Self.makePrompt(
            sourceText: item.text,
            request: request,
            glossary: glossary
        )
        let body = ChatRequest(
            model: Self.alias,
            messages: [.init(role: "user", content: prompt)],
            temperature: 0,
            maxTokens: min(4_096, max(128, item.text.count * 2))
        )
        var urlRequest = URLRequest(
            url: endpoint.appendingPathComponent("v1/chat/completions"),
            timeoutInterval: requestTimeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.backendUnavailable("本地模型没有返回 HTTP 状态。")
        }
        guard httpResponse.statusCode == 200 else {
            let reason =
                (try? JSONDecoder().decode(ErrorResponse.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(httpResponse.statusCode)"
            throw TranslationError.backendUnavailable(reason)
        }
        let responseBody = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let result = responseBody.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !result.isEmpty
        else {
            throw TranslationError.invalidResponse("本地模型返回了空译文。")
        }
        return result
    }

    private func isHealthy() async -> Bool {
        guard let endpoint else { return false }
        var request = URLRequest(
            url: endpoint.appendingPathComponent("health"),
            timeoutInterval: 1
        )
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func receiveProcessOutput(_ data: Data, generation: UUID) {
        guard generation == processGeneration, !data.isEmpty else { return }
        recentOutput.append(data)
        if recentOutput.count > Self.maximumRecentOutputBytes {
            recentOutput = Data(recentOutput.suffix(Self.maximumRecentOutputBytes))
        }
    }

    private func processExited(code: Int32, generation: UUID) {
        guard generation == processGeneration else { return }
        endpoint = nil
        if code != 0 {
            lastError = processFailureReason()
        }
    }

    private func processFailureReason() -> String {
        let output = String(data: recentOutput, encoding: .utf8)?
            .split(separator: "\n")
            .suffix(8)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.nonBlank(output) ?? "llama-server 已退出。"
    }

    static func makePrompt(
        sourceText: String,
        request: TranslationBatchRequest,
        glossary: [GlossaryTerm]
    ) -> String {
        var prompt: [String] = []
        if let context = request.context?.trimmingCharacters(in: .whitespacesAndNewlines),
            !context.isEmpty
        {
            prompt += ["[Background Information]", context]
        }
        if !glossary.isEmpty {
            prompt.append("Reference the following translations:")
            prompt += glossary.map { "\($0.source) translates to \($0.target)" }
        }

        var command = "Translate the following text into \(request.targetLanguage)"
        command += Self.profileRequirement(request.profile)
        if request.context?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            command += ", taking the background information above into consideration"
        }
        if request.contentKind == .ocr {
            command += ", correcting only unambiguous OCR artifacts"
        }
        command += ". Preserve names, numbers, URLs, identifiers, commands, code-like tokens, paragraph breaks, and newline structure. Note that you must ONLY output the translated result without any additional explanation:"
        prompt += [command, sourceText]
        return prompt.joined(separator: "\n")
    }

    private static func profileRequirement(_ profile: TranslationProfile) -> String {
        switch profile {
        case .faithful:
            ", staying close to the source meaning and structure"
        case .natural:
            ", in an idiomatic and natural style"
        case .technical:
            ", using established technical terminology"
        case .academic:
            ", in precise formal academic language"
        case .subtitle:
            ", using concise and speakable subtitle phrasing"
        }
    }

    static func resolveRuntime(
        environment: [String: String],
        bundleURL: URL = Bundle.main.bundleURL
    ) -> LlamaRuntimeLaunch? {
        let bundledCandidates = [
            bundleURL.appendingPathComponent("Contents/Helpers/gloss-llama-server").path,
            bundleURL.appendingPathComponent("Contents/Helpers/llama-server").path,
        ]
        if let bundled = bundledCandidates.first(where: FileManager.default.isExecutableFile) {
            return LlamaRuntimeLaunch(executable: bundled, source: "bundled")
        }

        var candidates: [String] = []
        if let configured = Self.nonBlank(environment["GLOSS_LLAMA_SERVER_BIN"]) {
            candidates.append(configured)
        }
        candidates += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/llama-server" }
        candidates += [
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/llama-server").path,
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile) else {
            return nil
        }
        return LlamaRuntimeLaunch(executable: executable, source: "external")
    }

    static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TranslationError.backendUnavailable("无法创建本地模型端口。")
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw TranslationError.backendUnavailable("无法绑定本地模型端口。")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let readResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard readResult == 0 else {
            throw TranslationError.backendUnavailable("无法读取本地模型端口。")
        }
        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private static func elapsedMilliseconds(since startedAt: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}
