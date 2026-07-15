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

actor LlamaRequestScheduler {
    struct Permit: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct Waiter {
        let id: UUID
        let priority: TranslationPriority
        let sequence: Int
        let enqueuedAt: UInt64
        let continuation: CheckedContinuation<Permit, Error>
    }

    private let capacity: Int
    private let nonInteractiveCapacity: Int
    private let agingIntervalNanoseconds: UInt64
    private var active: [UUID: TranslationPriority] = [:]
    private var waiters: [Waiter] = []
    private var nextSequence = 0

    init(
        capacity: Int = 2,
        reservedInteractiveSlots: Int = 1,
        agingIntervalNanoseconds: UInt64 = 2_000_000_000
    ) {
        let capacity = max(1, capacity)
        let reservedInteractiveSlots = min(
            max(0, reservedInteractiveSlots),
            max(0, capacity - 1)
        )
        self.capacity = capacity
        self.nonInteractiveCapacity = capacity - reservedInteractiveSlots
        self.agingIntervalNanoseconds = max(1, agingIntervalNanoseconds)
    }

    func acquire(priority: TranslationPriority) async throws -> Permit {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(
                    id: id,
                    priority: priority,
                    sequence: nextSequence,
                    enqueuedAt: DispatchTime.now().uptimeNanoseconds,
                    continuation: continuation
                )
                nextSequence += 1
                waiters.append(waiter)
                drain()
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    func release(_ permit: Permit) {
        guard active.removeValue(forKey: permit.id) != nil else { return }
        drain()
    }

    func pendingCount() -> Int {
        waiters.count
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func drain() {
        while active.count < capacity {
            guard let index = nextEligibleWaiterIndex() else { return }
            let waiter = waiters.remove(at: index)
            active[waiter.id] = waiter.priority
            waiter.continuation.resume(returning: Permit(id: waiter.id))
        }
    }

    private func nextEligibleWaiterIndex() -> Int? {
        let nonInteractiveActive = active.values.filter { $0 != .interactive }.count
        let now = DispatchTime.now().uptimeNanoseconds
        return waiters.indices
            .filter { index in
                waiters[index].priority == .interactive
                    || nonInteractiveActive < nonInteractiveCapacity
            }
            .max { leftIndex, rightIndex in
                let left = waiters[leftIndex]
                let right = waiters[rightIndex]
                let leftScore = effectiveRank(left, now: now)
                let rightScore = effectiveRank(right, now: now)
                if leftScore == rightScore {
                    return left.sequence > right.sequence
                }
                return leftScore < rightScore
            }
    }

    private func effectiveRank(_ waiter: Waiter, now: UInt64) -> Int {
        let age = now >= waiter.enqueuedAt ? now - waiter.enqueuedAt : 0
        let promotion = min(2, Int(age / agingIntervalNanoseconds))
        return min(TranslationPriority.interactive.rank, waiter.priority.rank + promotion)
    }
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
    static let batchSeparatorMarker = "<|GLOSS_TRANSLATION_SPLIT|>"
    private static let maximumBatchItems = 4
    private static let maximumBatchCharacters = 1_000
    private static let maximumRecentOutputBytes = 16_384

    private let environment: [String: String]
    private let glossaryStore: GlossaryStore
    private let modelReference: String
    private let startupTimeout: Duration
    private let requestTimeout: TimeInterval
    private let session: URLSession
    private let requestScheduler = LlamaRequestScheduler()
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
            let units = Self.translationUnits(for: request.items)
            GlossRuntimeLog.shared.write(
                "llama",
                "translation_plan items=\(request.items.count) units=\(units.count) batched=\(units.filter { $0.count > 1 }.count)"
            )
            var outputs: [TranslationOutput] = []
            outputs.reserveCapacity(request.items.count)

            for unit in units {
                let permit = try await requestScheduler.acquire(priority: request.priority)
                let translatedUnit: [TranslationOutput]
                do {
                    try Task.checkCancellation()
                    translatedUnit = try await translateUnit(
                        unit,
                        request: request,
                        glossary: glossary
                    )
                    await requestScheduler.release(permit)
                } catch {
                    await requestScheduler.release(permit)
                    throw error
                }
                outputs.append(contentsOf: translatedUnit)
                translatedUnit.forEach { onOutput?($0) }
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

    public func stop() async {
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
        let forced = if let runningProcess {
            await Self.terminateProcess(runningProcess)
        } else {
            false
        }
        GlossRuntimeLog.shared.write("llama", "stop forced=\(forced)")
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
            GlossRuntimeLog.shared.write(
                "llama",
                "startup_failed error=\(error.localizedDescription)"
            )
            await stop()
            throw error
        }
    }

    @discardableResult
    static func terminateProcess(
        _ process: Process,
        gracePeriod: Duration = .seconds(1)
    ) async -> Bool {
        guard process.isRunning else { return false }
        process.terminate()
        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard process.isRunning else { return false }
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        return true
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
        let localModelPath = if FileManager.default.fileExists(atPath: modelReference) {
            modelReference
        } else {
            Self.cachedModelPath(for: modelReference, environment: environment)
        }
        if let localModelPath {
            arguments += ["--model", localModelPath]
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
            "launch_start source=\(runtime.source) model_source=\(localModelPath == nil ? "huggingface" : "local") model=\(modelReference)"
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

    private func translateUnit(
        _ items: [TranslationItem],
        request: TranslationBatchRequest,
        glossary: [GlossaryTerm]
    ) async throws -> [TranslationOutput] {
        guard items.count > 1,
            !items.contains(where: { $0.text.contains(Self.batchSeparatorMarker) })
        else {
            return try await translateIndividually(items, request: request, glossary: glossary)
        }

        let sourceText = items.map(\.text).joined(
            separator: "\n\n\(Self.batchSeparatorMarker)\n\n"
        )
        let prompt = Self.makePrompt(
            sourceText: sourceText,
            request: request,
            glossary: glossary,
            batchCount: items.count
        )
        let response = try await translatePrompt(
            prompt,
            sourceCharacterCount: items.reduce(0) { $0 + $1.text.count }
        )

        if let translations = Self.parseBatchTranslation(
            response,
            expectedCount: items.count
        ) {
            return zip(items, translations).map { item, text in
                TranslationOutput(id: item.id, text: text)
            }
        }
        GlossRuntimeLog.shared.write(
            "llama",
            "translation_batch_fallback items=\(items.count) reason=separator_mismatch"
        )
        return try await translateIndividually(items, request: request, glossary: glossary)
    }

    private func translateIndividually(
        _ items: [TranslationItem],
        request: TranslationBatchRequest,
        glossary: [GlossaryTerm]
    ) async throws -> [TranslationOutput] {
        var outputs: [TranslationOutput] = []
        outputs.reserveCapacity(items.count)
        for item in items {
            try Task.checkCancellation()
            let text = try await translateItem(item, request: request, glossary: glossary)
            outputs.append(TranslationOutput(id: item.id, text: text))
        }
        return outputs
    }

    private func translateItem(
        _ item: TranslationItem,
        request: TranslationBatchRequest,
        glossary: [GlossaryTerm]
    ) async throws -> String {
        let prompt = Self.makePrompt(
            sourceText: item.text,
            request: request,
            glossary: glossary
        )
        return try await translatePrompt(prompt, sourceCharacterCount: item.text.count)
    }

    private func translatePrompt(
        _ prompt: String,
        sourceCharacterCount: Int
    ) async throws -> String {
        guard let endpoint else {
            throw TranslationError.backendUnavailable("llama-server 未运行。")
        }
        let body = ChatRequest(
            model: Self.alias,
            messages: [.init(role: "user", content: prompt)],
            temperature: 0,
            maxTokens: min(4_096, max(128, sourceCharacterCount * 2))
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

    static func translationUnits(for items: [TranslationItem]) -> [[TranslationItem]] {
        guard let first = items.first else { return [] }
        var units: [[TranslationItem]] = [[first]]
        var current: [TranslationItem] = []
        var currentCharacters = 0

        for item in items.dropFirst() {
            let itemCharacters = item.text.count
            if !current.isEmpty,
                current.count >= maximumBatchItems
                    || currentCharacters + itemCharacters > maximumBatchCharacters
            {
                units.append(current)
                current = []
                currentCharacters = 0
            }
            current.append(item)
            currentCharacters += itemCharacters
        }
        if !current.isEmpty {
            units.append(current)
        }
        return units
    }

    static func parseBatchTranslation(
        _ response: String,
        expectedCount: Int
    ) -> [String]? {
        guard expectedCount > 1 else { return nil }
        let parts = response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: batchSeparatorMarker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == expectedCount, parts.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return parts
    }

    static func makePrompt(
        sourceText: String,
        request: TranslationBatchRequest,
        glossary: [GlossaryTerm],
        batchCount: Int = 1
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
        if batchCount > 1 {
            command += ". The source contains exactly \(batchCount) independent segments separated by \(batchSeparatorMarker). Translate every segment independently and return exactly \(batchCount) translations in the original order, separated by the exact same marker"
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

    static func cachedModelPath(
        for modelReference: String,
        environment: [String: String]
    ) -> String? {
        let parts = modelReference.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let repositoryParts = parts[0].split(separator: "/")
        guard repositoryParts.count == 2,
            repositoryParts.allSatisfy({ $0 != "." && $0 != ".." }),
            !parts[1].isEmpty
        else { return nil }

        var cacheRoots: [URL] = []
        if let path = nonBlank(environment["HF_HUB_CACHE"]) {
            cacheRoots.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        if let path = nonBlank(environment["HF_HOME"]) {
            cacheRoots.append(
                URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent("hub", isDirectory: true)
            )
        }
        if let path = nonBlank(environment["XDG_CACHE_HOME"]) {
            cacheRoots.append(
                URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent("huggingface/hub", isDirectory: true)
            )
        }
        cacheRoots.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        )

        let repositoryName = "models--" + parts[0].replacingOccurrences(of: "/", with: "--")
        let quantization = parts[1]
        for cacheRoot in cacheRoots {
            let repository = cacheRoot.appendingPathComponent(repositoryName, isDirectory: true)
            let reference = repository.appendingPathComponent("refs/main", isDirectory: false)
            guard let revision = try? String(contentsOf: reference, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !revision.isEmpty,
                revision.allSatisfy({ $0.isHexDigit })
            else { continue }
            let snapshot = repository
                .appendingPathComponent("snapshots", isDirectory: true)
                .appendingPathComponent(revision, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: snapshot,
                includingPropertiesForKeys: nil
            ) else { continue }
            if let model = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .first(where: {
                    $0.pathExtension.lowercased() == "gguf"
                        && $0.lastPathComponent.localizedCaseInsensitiveContains(quantization)
                }),
                FileManager.default.fileExists(atPath: model.path)
            {
                return model.path
            }
        }
        return nil
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
