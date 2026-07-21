import Foundation
import Network

package final class LoopbackServer: @unchecked Sendable {
    package enum State: Sendable, Equatable {
        case starting
        case ready
        case failed(String)
        case stopped
    }

    private struct HTTPRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private enum ParseResult {
        case incomplete
        case complete(HTTPRequest)
        case invalid(String)
    }

    private struct TranslationBody: Decodable {
        struct Item: Decodable {
            let id: String
            let text: String
        }

        let items: [Item]?
        let texts: [String]?
        let targetLanguage: String?
        let profile: String?
        let contentKind: String?
        let sourceUrl: String?
        let priority: String?
        let requestId: String?
    }

    private struct BrowserMetricBody: Decodable {
        let event: String
        let requestId: String?
        let durationMs: Int
    }

    private struct CancellationBody: Decodable {
        let requestIds: [String]
    }

    private struct TranslationResponse: Encodable {
        struct Item: Encodable {
            let id: String
            let text: String
        }

        let translations: [Item]
    }

    private struct OpenAIChatCompletionBody: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }

        let model: String?
        let messages: [Message]
    }

    private struct BabelDOCBatchInput: Decodable {
        let id: JSONValue
        let input: String
    }

    private struct BabelDOCBatchOutput: Encodable {
        let id: JSONValue
        let output: String
    }

    private struct BabelDOCCompatiblePrompt: Sendable {
        enum OutputMode: Sendable {
            case plainText
            case jsonArray
        }

        struct Item: Sendable {
            let responseID: JSONValue?
            let text: String
        }

        let targetLanguage: String
        let items: [Item]
        let outputMode: OutputMode
    }

    private struct BabelDOCTranslationChunk: Sendable {
        let id: String
        let originalIndex: Int
        let chunkIndex: Int
        let separatorBefore: String
        let text: String
    }

    private struct OpenAIChatCompletionResponse: Encodable {
        struct Choice: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }

            let index: Int
            let message: Message
            let finishReason: String

            enum CodingKeys: String, CodingKey {
                case index
                case message
                case finishReason = "finish_reason"
            }
        }

        struct Usage: Encodable {
            let promptTokens: Int
            let completionTokens: Int
            let totalTokens: Int

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
            }
        }

        let id: String
        let object: String
        let created: Int
        let model: String
        let choices: [Choice]
        let usage: Usage
    }

    private struct HealthResponse: Encodable {
        let ok: Bool
        let name: String
        let version: String
        let backend: String
        let provider: String
        let model: String
        let reasoning: String?
        let configRevision: String
        let warm: Bool
        let cacheSize: Int
    }

    private struct ErrorResponse: Encodable {
        let error: String
    }

    private struct CancellationResponse: Encodable {
        let cancelled: Int
    }

    private struct ActiveTranslationTask {
        let token: UUID
        var task: Task<Void, Never>?
    }

    private struct StreamEvent: Encodable {
        let type: String
        let id: String?
        let text: String?
        let count: Int?
        let error: String?

        init(
            type: String,
            id: String? = nil,
            text: String? = nil,
            count: Int? = nil,
            error: String? = nil
        ) {
            self.type = type
            self.id = id
            self.text = text
            self.count = count
            self.error = error
        }
    }

    private static let maximumRequestSize = 1_100_000
    private static let maximumItems = 40
    private static let maximumTotalCharacters = 100_000
    private static let maximumBabelDOCChunkCharacters = 900
    private static let defaultBabelDOCBatchConfiguration =
        BabelDOCBatchCoordinator.Configuration(
            maximumBatchItems: 12,
            maximumBatchCharacters: 1_800,
            maximumConcurrentBatches: 2,
            fillDelayNanoseconds: 25_000_000,
            refillDelayNanoseconds: 0
        )

    private let queue = DispatchQueue(label: "com.samsoncj.gloss.loopback", qos: .userInitiated)
    private let broker: TranslationBroker
    private let babelDOCBatchConfiguration: BabelDOCBatchCoordinator.Configuration
    private let babelDOCBatchCoordinator: BabelDOCBatchCoordinator
    private let providerStatus: @Sendable () async -> TranslationProviderStatus
    private let runtimeLog: GlossRuntimeLog
    private let token: String
    private let version: String
    private let port: NWEndpoint.Port
    private let activeTasksLock = NSLock()
    private var activeTranslationTasks: [String: ActiveTranslationTask] = [:]
    private var listener: NWListener?
    package var onStateChange: (@Sendable (State) -> Void)?

    package init(
        broker: TranslationBroker,
        token: String,
        version: String = "development",
        port: UInt16 = 8787,
        dispatchState: TranslationDispatchState? = nil,
        providerStatus: @escaping @Sendable () async -> TranslationProviderStatus = {
            TranslationProviderStatus(
                provider: .codex,
                model: TranslationProviderConfiguration.defaultCodexModel,
                reasoningEffort: .low,
                configurationRevision: "default",
                isWarm: true
            )
        },
        runtimeLog: GlossRuntimeLog = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.broker = broker
        let babelDOCConfiguration = BabelDOCBatchCoordinator.Configuration(
            environment: environment,
            defaults: Self.defaultBabelDOCBatchConfiguration
        )
        self.babelDOCBatchConfiguration = babelDOCConfiguration
        self.babelDOCBatchCoordinator = BabelDOCBatchCoordinator(
            broker: broker,
            configuration: babelDOCConfiguration,
            runtimeLog: runtimeLog,
            dispatchState: dispatchState
        )
        self.providerStatus = providerStatus
        self.token = token
        self.version = version
        self.port = NWEndpoint.Port(rawValue: port)!
        self.runtimeLog = runtimeLog
        runtimeLog.write(
            "bridge",
            "babeldoc_batch_configuration max_items=\(babelDOCConfiguration.maximumBatchItems) max_chars=\(babelDOCConfiguration.maximumBatchCharacters) concurrency=\(babelDOCConfiguration.maximumConcurrentBatches) fill_delay_ms=\(babelDOCConfiguration.fillDelayNanoseconds / 1_000_000) refill_delay_ms=\(babelDOCConfiguration.refillDelayNanoseconds / 1_000_000)"
        )
    }

    package func start() throws {
        guard listener == nil else { return }
        runtimeLog.write("bridge", "start address=127.0.0.1 port=\(port.rawValue)")
        onStateChange?(.starting)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.runtimeLog.write("bridge", "ready address=127.0.0.1 port=\(self.port.rawValue)")
                self.onStateChange?(.ready)
            case .failed(let error):
                self.runtimeLog.write("bridge", "failed error=\(error.localizedDescription)")
                self.onStateChange?(.failed(error.localizedDescription))
                listener?.stateUpdateHandler = nil
                self.stop()
            case .cancelled:
                self.onStateChange?(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    package func stop() {
        runtimeLog.write("bridge", "stop")
        cancelAllTranslationTasks()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        let endpoint = connection.endpoint
        guard case .hostPort(let host, _) = endpoint,
            host == "127.0.0.1" || host == "::1"
        else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            guard nextBuffer.count <= Self.maximumRequestSize else {
                self.sendJSON(ErrorResponse(error: "Request too large."), status: 413, to: connection)
                return
            }

            switch self.parse(nextBuffer) {
            case .incomplete where !isComplete:
                self.receive(on: connection, buffer: nextBuffer)
            case .incomplete:
                self.sendJSON(ErrorResponse(error: "Incomplete request."), status: 400, to: connection)
            case .invalid(let message):
                self.sendJSON(ErrorResponse(error: message), status: 400, to: connection)
            case .complete(let request):
                self.route(request, connection: connection)
            }
        }
    }

    private func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return .incomplete }
        guard let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .invalid("Invalid HTTP headers.")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid("Missing request line.") }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return .invalid("Invalid request line.") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("Invalid header.") }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        guard contentLength >= 0, contentLength <= Self.maximumRequestSize else {
            return .invalid("Invalid Content-Length.")
        }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        return .complete(
            HTTPRequest(
                method: String(parts[0]).uppercased(),
                path: path,
                headers: headers,
                body: body
            )
        )
    }

    private func route(_ request: HTTPRequest, connection: NWConnection) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let origin = request.headers["origin"]
        if let origin, !isAllowedOrigin(origin) {
            runtimeLog.write("bridge", "request_rejected reason=origin path=\(request.path)")
            sendJSON(ErrorResponse(error: "Origin not allowed."), status: 403, to: connection)
            return
        }

        if request.method == "OPTIONS" {
            send(data: Data(), status: 204, origin: origin, to: connection)
            return
        }

        let suppliedToken =
            request.headers["x-gloss-token"]
            ?? request.headers["x-pit-token"]
            ?? bearerToken(from: request.headers["authorization"])
        guard suppliedToken == token else {
            runtimeLog.write("bridge", "request_rejected reason=auth path=\(request.path)")
            sendJSON(
                ErrorResponse(error: "Gloss browser pairing required."),
                status: 401,
                origin: origin,
                to: connection
            )
            return
        }

        if request.method == "POST", request.path == "/cancel" {
            cancelTranslations(request, origin: origin, connection: connection)
            return
        }

        if request.method == "GET", request.path == "/health" {
            Task {
                let cacheSize = await broker.cacheCount()
                let providerStatus = await providerStatus()
                runtimeLog.write(
                    "bridge",
                    "health status=200 duration_ms=\(Self.elapsedMilliseconds(since: startedAt)) provider=\(providerStatus.provider.rawValue) model=\(providerStatus.model) revision=\(providerStatus.configurationRevision) cache=\(cacheSize)"
                )
                sendJSON(
                    HealthResponse(
                        ok: true,
                        name: "Gloss",
                        version: version,
                        backend: providerStatus.backendName,
                        provider: providerStatus.provider.rawValue,
                        model: providerStatus.model,
                        reasoning: providerStatus.reasoningEffort?.rawValue,
                        configRevision: providerStatus.configurationRevision,
                        warm: providerStatus.isWarm,
                        cacheSize: cacheSize
                    ),
                    status: 200,
                    origin: origin,
                    to: connection
                )
            }
            return
        }

        if request.method == "POST", request.path == "/metrics" {
            recordBrowserMetric(request, origin: origin, connection: connection)
            return
        }

        if request.method == "POST", request.path == "/v1/chat/completions" {
            completeOpenAITranslation(
                request,
                startedAt: startedAt,
                origin: origin,
                connection: connection
            )
            return
        }

        guard request.method == "POST",
            request.path == "/translate" || request.path == "/translate/stream"
        else {
            sendJSON(ErrorResponse(error: "Not found."), status: 404, origin: origin, to: connection)
            return
        }

        let body: TranslationBody
        do {
            body = try JSONDecoder().decode(TranslationBody.self, from: request.body)
        } catch {
            sendJSON(
                ErrorResponse(error: "Invalid JSON: \(error.localizedDescription)"), status: 400, origin: origin,
                to: connection)
            return
        }

        let items: [TranslationItem]
        if let suppliedItems = body.items {
            items = suppliedItems.map { TranslationItem(id: $0.id, text: $0.text) }
        } else {
            items = (body.texts ?? []).enumerated().map {
                TranslationItem(id: "gloss-\($0.offset)", text: $0.element)
            }
        }
        let totalCharacters = items.reduce(0) { $0 + $1.text.count }
        var itemIDs: Set<String> = []
        let validItems = items.allSatisfy {
            !$0.id.isEmpty
                && $0.id.count <= 256
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.text.count <= 20_000
                && itemIDs.insert($0.id).inserted
        }
        let targetLanguage = (body.targetLanguage ?? "Chinese (Simplified)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !items.isEmpty,
            items.count <= Self.maximumItems,
            totalCharacters <= Self.maximumTotalCharacters,
            validItems,
            TranslationLanguages.isValidTargetName(targetLanguage)
        else {
            sendJSON(
                ErrorResponse(error: "Translation payload is invalid or too large."), status: 422, origin: origin,
                to: connection)
            return
        }

        let profile: TranslationProfile
        if let rawProfile = body.profile {
            guard let parsedProfile = TranslationProfile(rawValue: rawProfile) else {
                sendJSON(
                    ErrorResponse(error: "Unknown translation profile."), status: 422, origin: origin, to: connection)
                return
            }
            profile = parsedProfile
        } else {
            profile = .natural
        }
        let contentKind: TranslationContentKind
        if let rawContentKind = body.contentKind {
            guard let parsedContentKind = TranslationContentKind(rawValue: rawContentKind) else {
                sendJSON(
                    ErrorResponse(error: "Unknown translation content kind."), status: 422, origin: origin,
                    to: connection)
                return
            }
            contentKind = parsedContentKind
        } else {
            contentKind = .webpage
        }
        let priority: TranslationPriority
        if let rawPriority = body.priority {
            guard let parsed = TranslationPriority(rawValue: rawPriority) else {
                sendJSON(
                    ErrorResponse(error: "Unknown translation priority."), status: 422, origin: origin,
                    to: connection)
                return
            }
            priority = parsed
        } else {
            priority = .visible
        }
        let translationRequest = TranslationBatchRequest(
            items: items,
            targetLanguage: targetLanguage,
            profile: profile,
            contentKind: contentKind,
            context: sourceContext(from: body.sourceUrl),
            priority: priority
        )
        let requestID = safeRequestID(body.requestId)
        runtimeLog.write(
            "bridge",
            "translation_start items=\(items.count) chars=\(totalCharacters) profile=\(profile.rawValue) content_kind=\(contentKind.rawValue) priority=\(priority.rawValue) request_id=\(requestID)"
        )

        if request.path == "/translate/stream" {
            streamTranslation(
                translationRequest,
                requestID: requestID,
                startedAt: startedAt,
                origin: origin,
                connection: connection
            )
            return
        }

        startTranslationTask(requestID: requestID) { [weak self] in
            guard let self else { return }
            do {
                let outputs = try await broker.translate(translationRequest)
                runtimeLog.write(
                    "bridge",
                    "translation_complete items=\(outputs.count) duration_ms=\(Self.elapsedMilliseconds(since: startedAt))"
                )
                sendJSON(
                    TranslationResponse(
                        translations: outputs.map { TranslationResponse.Item(id: $0.id, text: $0.text) }
                    ),
                    status: 200,
                    origin: origin,
                    to: connection
                )
            } catch {
                runtimeLog.write(
                    "bridge",
                    "translation_failed duration_ms=\(Self.elapsedMilliseconds(since: startedAt)) error_type=\(String(reflecting: type(of: error)))"
                )
                sendJSON(
                    ErrorResponse(error: error.localizedDescription),
                    status: 500,
                    origin: origin,
                    to: connection
                )
            }
        }
    }

    private func streamTranslation(
        _ request: TranslationBatchRequest,
        requestID: String,
        startedAt: UInt64,
        origin: String?,
        connection: NWConnection
    ) {
        startTranslationTask(requestID: requestID) { [weak self] in
            guard let self else { return }
            var headersSent = false
            var count = 0
            var firstItemMilliseconds: Int?
            do {
                try await sendStreamHeaders(origin: origin, to: connection)
                headersSent = true
                for try await output in broker.translationStream(request) {
                    let elapsed = Self.elapsedMilliseconds(since: startedAt)
                    if firstItemMilliseconds == nil {
                        firstItemMilliseconds = elapsed
                        runtimeLog.write(
                            "bridge",
                            "translation_first_item request_id=\(requestID) first_item_complete_ms=\(elapsed)"
                        )
                    }
                    try await sendStreamEvent(
                        StreamEvent(type: "translation", id: output.id, text: output.text),
                        to: connection
                    )
                    count += 1
                }
                try Task.checkCancellation()
                try await sendStreamEvent(StreamEvent(type: "done", count: count), to: connection)
                try await finishStream(connection)
                runtimeLog.write(
                    "bridge",
                    "translation_complete items=\(count) duration_ms=\(Self.elapsedMilliseconds(since: startedAt)) first_item_complete_ms=\(firstItemMilliseconds ?? -1) request_id=\(requestID)"
                )
            } catch is CancellationError {
                runtimeLog.write(
                    "bridge",
                    "translation_cancelled duration_ms=\(Self.elapsedMilliseconds(since: startedAt)) request_id=\(requestID)"
                )
                connection.cancel()
            } catch {
                runtimeLog.write(
                    "bridge",
                    "translation_failed duration_ms=\(Self.elapsedMilliseconds(since: startedAt)) error_type=\(String(reflecting: type(of: error))) reason=\(error.localizedDescription) request_id=\(requestID)"
                )
                if headersSent {
                    try? await sendStreamEvent(
                        StreamEvent(type: "error", error: error.localizedDescription),
                        to: connection
                    )
                    try? await finishStream(connection)
                } else {
                    sendJSON(
                        ErrorResponse(error: error.localizedDescription),
                        status: 500,
                        origin: origin,
                        to: connection
                    )
                }
            }
        }
    }

    private func completeOpenAITranslation(
        _ request: HTTPRequest,
        startedAt: UInt64,
        origin: String?,
        connection: NWConnection
    ) {
        let body: OpenAIChatCompletionBody
        do {
            body = try JSONDecoder().decode(
                OpenAIChatCompletionBody.self,
                from: request.body
            )
        } catch {
            sendJSON(
                ErrorResponse(error: "Invalid OpenAI chat completion payload."),
                status: 400,
                origin: origin,
                to: connection
            )
            return
        }
        guard let prompt = body.messages.last(where: { $0.role == "user" })?.content,
            let parsed = Self.parseBabelDOCCompatiblePrompt(prompt)
        else {
            sendJSON(
                ErrorResponse(error: "Unsupported local OpenAI-compatible prompt."),
                status: 422,
                origin: origin,
                to: connection
            )
            return
        }

        let requestID = "babeldoc-\(UUID().uuidString)"
        runtimeLog.write(
            "bridge",
            "babeldoc_translation_start items=\(parsed.items.count) chars=\(parsed.items.reduce(0) { $0 + $1.text.count }) target=\(parsed.targetLanguage)"
        )
        startTranslationTask(requestID: requestID) { [weak self] in
            guard let self else { return }
            do {
                let outputs = try await translateBabelDOCItems(
                    parsed,
                    requestID: requestID
                )
                guard outputs.count == parsed.items.count else {
                    throw TranslationError.invalidResponse(
                        "BabelDOC compatibility request returned an incomplete translation."
                    )
                }
                let translated = try Self.babelDOCResponseContent(
                    for: parsed,
                    outputs: outputs
                )
                let model = body.model ?? "gloss-provider"
                sendJSON(
                    OpenAIChatCompletionResponse(
                        id: "chatcmpl-\(UUID().uuidString)",
                        object: "chat.completion",
                        created: Int(Date().timeIntervalSince1970),
                        model: model,
                        choices: [
                            OpenAIChatCompletionResponse.Choice(
                                index: 0,
                                message: .init(
                                    role: "assistant",
                                    content: translated
                                ),
                                finishReason: "stop"
                            )
                        ],
                        usage: .init(
                            promptTokens: 0,
                            completionTokens: 0,
                            totalTokens: 0
                        )
                    ),
                    status: 200,
                    origin: origin,
                    to: connection
                )
                runtimeLog.write(
                    "bridge",
                    "babeldoc_translation_complete duration_ms=\(Self.elapsedMilliseconds(since: startedAt))"
                )
            } catch {
                runtimeLog.write(
                    "bridge",
                    "babeldoc_translation_failed duration_ms=\(Self.elapsedMilliseconds(since: startedAt)) error_type=\(String(reflecting: type(of: error)))"
                )
                sendJSON(
                    ErrorResponse(error: error.localizedDescription),
                    status: 500,
                    origin: origin,
                    to: connection
                )
            }
        }
    }

    private func translateBabelDOCItems(
        _ prompt: BabelDOCCompatiblePrompt,
        requestID: String
    ) async throws -> [TranslationOutput] {
        let chunks = Self.makeBabelDOCTranslationChunks(
            prompt.items,
            requestID: requestID
        )
        runtimeLog.write(
            "bridge",
            "babeldoc_translation_plan source_items=\(prompt.items.count) chunks=\(chunks.count) max_chunk_chars=\(Self.maximumBabelDOCChunkCharacters) max_batch_items=\(babelDOCBatchConfiguration.maximumBatchItems) max_batch_chars=\(babelDOCBatchConfiguration.maximumBatchCharacters)"
        )

        let targetLanguage = prompt.targetLanguage
        let translated = try await babelDOCBatchCoordinator.translate(
            items: chunks.map { TranslationItem(id: $0.id, text: $0.text) },
            targetLanguage: targetLanguage,
            context:
                "Layout-preserving PDF translation via BabelDOC. Translate every bounded chunk completely and preserve continuity."
        )
        let translatedByID = Dictionary(
            translated.map { ($0.id, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )

        return try prompt.items.indices.map { originalIndex in
            let originalChunks =
                chunks
                .filter { $0.originalIndex == originalIndex }
                .sorted { $0.chunkIndex < $1.chunkIndex }
            guard !originalChunks.isEmpty else {
                throw TranslationError.invalidResponse(
                    "BabelDOC compatibility request lost a source paragraph."
                )
            }
            var translated = ""
            for chunk in originalChunks {
                guard
                    let value = translatedByID[chunk.id]?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty
                else {
                    throw TranslationError.invalidResponse(
                        "BabelDOC compatibility request returned an incomplete chunk."
                    )
                }
                translated += chunk.separatorBefore + value
            }
            return TranslationOutput(
                id: "\(requestID)-\(originalIndex)",
                text: translated
            )
        }
    }

    private func cancelTranslations(
        _ request: HTTPRequest,
        origin: String?,
        connection: NWConnection
    ) {
        guard let body = try? JSONDecoder().decode(CancellationBody.self, from: request.body) else {
            sendJSON(ErrorResponse(error: "Invalid cancellation payload."), status: 400, origin: origin, to: connection)
            return
        }
        let requestIDs = Array(Set(body.requestIds.map(safeRequestID).filter { $0 != "none" }))
        guard !requestIDs.isEmpty, requestIDs.count <= Self.maximumItems else {
            sendJSON(ErrorResponse(error: "Invalid cancellation payload."), status: 422, origin: origin, to: connection)
            return
        }
        let cancelled = cancelTranslationTasks(requestIDs)
        runtimeLog.write("bridge", "translation_cancel requested=\(requestIDs.count) cancelled=\(cancelled)")
        sendJSON(
            CancellationResponse(cancelled: cancelled),
            status: 200,
            origin: origin,
            to: connection
        )
    }

    private func startTranslationTask(
        requestID: String,
        operation: @escaping @Sendable () async -> Void
    ) {
        let taskID = requestID == "none" ? "anonymous-\(UUID().uuidString)" : requestID
        let token = UUID()
        activeTasksLock.lock()
        let previousTask = activeTranslationTasks.updateValue(
            ActiveTranslationTask(token: token, task: nil),
            forKey: taskID
        )?.task
        activeTasksLock.unlock()
        previousTask?.cancel()

        let task = Task { [weak self] in
            await operation()
            self?.finishTranslationTask(taskID, token: token)
        }
        activeTasksLock.lock()
        if activeTranslationTasks[taskID]?.token == token {
            activeTranslationTasks[taskID]?.task = task
            activeTasksLock.unlock()
        } else {
            activeTasksLock.unlock()
            task.cancel()
        }
    }

    private func finishTranslationTask(_ requestID: String, token: UUID) {
        activeTasksLock.lock()
        if activeTranslationTasks[requestID]?.token == token {
            activeTranslationTasks.removeValue(forKey: requestID)
        }
        activeTasksLock.unlock()
    }

    private func cancelTranslationTasks(_ requestIDs: [String]) -> Int {
        activeTasksLock.lock()
        let entries = requestIDs.compactMap { activeTranslationTasks.removeValue(forKey: $0) }
        activeTasksLock.unlock()
        for entry in entries {
            entry.task?.cancel()
        }
        return entries.count
    }

    private func cancelAllTranslationTasks() {
        activeTasksLock.lock()
        let entries = Array(activeTranslationTasks.values)
        activeTranslationTasks.removeAll(keepingCapacity: false)
        activeTasksLock.unlock()
        for entry in entries {
            entry.task?.cancel()
        }
    }

    private func recordBrowserMetric(
        _ request: HTTPRequest,
        origin: String?,
        connection: NWConnection
    ) {
        guard let metric = try? JSONDecoder().decode(BrowserMetricBody.self, from: request.body),
            metric.event == "item_rendered",
            (0...300_000).contains(metric.durationMs)
        else {
            sendJSON(ErrorResponse(error: "Invalid metric."), status: 422, origin: origin, to: connection)
            return
        }
        runtimeLog.write(
            "bridge",
            "item_rendered request_id=\(safeRequestID(metric.requestId)) item_rendered_ms=\(metric.durationMs)"
        )
        send(data: Data(), status: 204, origin: origin, to: connection)
    }

    private func safeRequestID(_ value: String?) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = String((value ?? "none").unicodeScalars.filter(allowed.contains).prefix(100))
        return filtered.isEmpty ? "none" : filtered
    }

    private func bearerToken(from authorization: String?) -> String? {
        guard let authorization else { return nil }
        let components = authorization.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard components.count == 2,
            components[0].caseInsensitiveCompare("Bearer") == .orderedSame
        else { return nil }
        return String(components[1])
    }

    static func parseBabelDOCPrompt(
        _ prompt: String
    ) -> (text: String, targetLanguage: String)? {
        guard
            let inputRange = prompt.range(
                of: "Input:\n\n",
                options: [.backwards, .caseInsensitive]
            )
        else { return nil }
        let text = prompt[inputRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000 else { return nil }

        let expression = try? NSRegularExpression(
            pattern: #"translate\s+it\s+into\s+([^,\n]+),\s*output\s+translation\s+ONLY"#,
            options: [.caseInsensitive]
        )
        let fullRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        guard let match = expression?.firstMatch(in: prompt, range: fullRange),
            let languageRange = Range(match.range(at: 1), in: prompt)
        else { return nil }
        let languageCode = prompt[languageRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let targetLanguage =
                TranslationLanguages.targetName(forLanguageCode: languageCode)
                ?? (TranslationLanguages.isValidTargetName(languageCode)
                    ? languageCode
                    : nil)
        else { return nil }
        return (text, targetLanguage)
    }

    private static func parseBabelDOCCompatiblePrompt(
        _ prompt: String
    ) -> BabelDOCCompatiblePrompt? {
        if let plain = parseBabelDOCPrompt(prompt) {
            return BabelDOCCompatiblePrompt(
                targetLanguage: plain.targetLanguage,
                items: [.init(responseID: nil, text: plain.text)],
                outputMode: .plainText
            )
        }

        if let structured = parseBabelDOCStructuredPrompt(prompt) {
            return BabelDOCCompatiblePrompt(
                targetLanguage: structured.targetLanguage,
                items: [.init(responseID: nil, text: structured.text)],
                outputMode: .plainText
            )
        }

        guard
            let inputRange = prompt.range(
                of: "## Here is the input:",
                options: [.backwards, .caseInsensitive]
            ),
            let targetLanguage = babelDOCTargetLanguage(inBatchPrompt: prompt)
        else { return nil }
        let json = prompt[inputRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !json.isEmpty,
            json.count <= Self.maximumRequestSize,
            let data = json.data(using: .utf8),
            let inputs = try? JSONDecoder().decode(
                [BabelDOCBatchInput].self,
                from: data
            ),
            !inputs.isEmpty,
            inputs.count <= Self.maximumItems,
            inputs.allSatisfy({
                !$0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }),
            inputs.reduce(0, { $0 + $1.input.count })
                <= Self.maximumTotalCharacters
        else { return nil }

        return BabelDOCCompatiblePrompt(
            targetLanguage: targetLanguage,
            items: inputs.map {
                .init(responseID: $0.id, text: $0.input)
            },
            outputMode: .jsonArray
        )
    }

    private static func parseBabelDOCStructuredPrompt(
        _ prompt: String
    ) -> (text: String, targetLanguage: String)? {
        guard
            let inputRange = prompt.range(
                of: "Now translate the following text:",
                options: [.backwards, .caseInsensitive]
            )
        else { return nil }
        let text = prompt[inputRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000 else { return nil }

        let expression = try? NSRegularExpression(
            pattern:
                #"Translate\s+ALL\s+human-readable\s+content\s+into\s+([A-Za-z][A-Za-z0-9_-]*)\."#,
            options: [.caseInsensitive]
        )
        let fullRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        guard let match = expression?.firstMatch(in: prompt, range: fullRange),
            let languageRange = Range(match.range(at: 1), in: prompt)
        else { return nil }
        let languageCode = String(prompt[languageRange])
        guard
            let targetLanguage =
                TranslationLanguages.targetName(
                    forLanguageCode: languageCode
                )
                ?? (TranslationLanguages.isValidTargetName(languageCode)
                    ? languageCode
                    : nil)
        else { return nil }
        return (text, targetLanguage)
    }

    private static func babelDOCTargetLanguage(
        inBatchPrompt prompt: String
    ) -> String? {
        let expression = try? NSRegularExpression(
            pattern: #"translate\s+text\s+into\s+([A-Za-z][A-Za-z0-9_-]*)"#,
            options: [.caseInsensitive]
        )
        let fullRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        guard let match = expression?.firstMatch(in: prompt, range: fullRange),
            let languageRange = Range(match.range(at: 1), in: prompt)
        else { return nil }
        let languageCode = String(prompt[languageRange])
        return TranslationLanguages.targetName(forLanguageCode: languageCode)
            ?? (TranslationLanguages.isValidTargetName(languageCode)
                ? languageCode
                : nil)
    }

    private static func makeBabelDOCTranslationChunks(
        _ items: [BabelDOCCompatiblePrompt.Item],
        requestID: String
    ) -> [BabelDOCTranslationChunk] {
        items.enumerated().flatMap { originalIndex, item in
            splitBabelDOCText(item.text).enumerated().map {
                chunkIndex, piece in
                BabelDOCTranslationChunk(
                    id: "\(requestID)-\(originalIndex)-\(chunkIndex)",
                    originalIndex: originalIndex,
                    chunkIndex: chunkIndex,
                    separatorBefore: piece.separatorBefore,
                    text: piece.text
                )
            }
        }
    }

    private static func splitBabelDOCText(
        _ text: String
    ) -> [(separatorBefore: String, text: String)] {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.count > maximumBabelDOCChunkCharacters else {
            return source.isEmpty ? [] : [("", source)]
        }

        var pieces: [(separatorBefore: String, text: String)] = []
        var remaining = source[...]
        var separatorBefore = ""

        while remaining.count > maximumBabelDOCChunkCharacters {
            let hardEnd = remaining.index(
                remaining.startIndex,
                offsetBy: maximumBabelDOCChunkCharacters
            )
            let prefix = remaining[..<hardEnd]
            let minimumOffset = maximumBabelDOCChunkCharacters / 2
            let splitIndex =
                preferredBabelDOCSplitIndex(
                    in: prefix,
                    minimumOffset: minimumOffset
                )
                ?? hardEnd
            let rawPiece = remaining[..<splitIndex]
            let piece = rawPiece.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !piece.isEmpty {
                pieces.append((separatorBefore, piece))
            }

            var nextStart = splitIndex
            var consumedWhitespace = ""
            while nextStart < remaining.endIndex,
                remaining[nextStart].isWhitespace
            {
                consumedWhitespace.append(remaining[nextStart])
                nextStart = remaining.index(after: nextStart)
            }
            separatorBefore = normalizedBabelDOCSeparator(
                consumedWhitespace,
                hardSplit: nextStart == splitIndex
            )
            remaining = remaining[nextStart...]
        }

        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            pieces.append((separatorBefore, tail))
        }
        return pieces
    }

    private static func preferredBabelDOCSplitIndex(
        in text: Substring,
        minimumOffset: Int
    ) -> String.Index? {
        let punctuation = CharacterSet(charactersIn: ".!?。！？;；")
        var whitespaceFallback: String.Index?
        for index in text.indices.reversed() {
            let offset = text.distance(from: text.startIndex, to: index)
            guard offset >= minimumOffset else { break }
            let character = text[index]
            if character.unicodeScalars.allSatisfy({
                punctuation.contains($0)
            }) {
                return text.index(after: index)
            }
            if character.isWhitespace, whitespaceFallback == nil {
                whitespaceFallback = index
            }
        }
        return whitespaceFallback
    }

    private static func normalizedBabelDOCSeparator(
        _ whitespace: String,
        hardSplit: Bool
    ) -> String {
        if whitespace.contains("\n\n") {
            return "\n\n"
        }
        if whitespace.contains("\n") {
            return "\n"
        }
        return hardSplit ? "" : " "
    }

    private static func babelDOCResponseContent(
        for prompt: BabelDOCCompatiblePrompt,
        outputs: [TranslationOutput]
    ) throws -> String {
        switch prompt.outputMode {
        case .plainText:
            guard let output = outputs.first else {
                throw TranslationError.invalidResponse(
                    "BabelDOC compatibility request returned no translation."
                )
            }
            return output.text
        case .jsonArray:
            let response = zip(prompt.items, outputs).compactMap {
                item, output -> BabelDOCBatchOutput? in
                guard let responseID = item.responseID else { return nil }
                return BabelDOCBatchOutput(
                    id: responseID,
                    output: output.text
                )
            }
            guard response.count == prompt.items.count else {
                throw TranslationError.invalidResponse(
                    "BabelDOC compatibility response lost paragraph identifiers."
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(response)
            guard let value = String(data: data, encoding: .utf8) else {
                throw TranslationError.invalidResponse(
                    "BabelDOC compatibility response could not be encoded."
                )
            }
            return value
        }
    }

    private func sourceContext(from sourceURL: String?) -> String? {
        guard let sourceURL,
            let components = URLComponents(string: sourceURL),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            let host = components.host,
            !host.isEmpty
        else { return nil }
        return "Website: \(host.lowercased())"
    }

    private static func elapsedMilliseconds(since startedAt: UInt64) -> Int {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        return Int(elapsed / 1_000_000)
    }

    private func isAllowedOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin) else { return false }
        let allowedSchemes = Set(["chrome-extension", "safari-web-extension"])
        return allowedSchemes.contains(components.scheme ?? "") && !(components.host ?? "").isEmpty
    }

    private func sendJSON<T: Encodable>(
        _ value: T,
        status: Int,
        origin: String? = nil,
        to connection: NWConnection
    ) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            send(data: try encoder.encode(value), status: status, origin: origin, to: connection)
        } catch {
            send(data: Data("{\"error\":\"Encoding failed.\"}".utf8), status: 500, origin: origin, to: connection)
        }
    }

    private func sendStreamHeaders(origin: String?, to connection: NWConnection) async throws {
        var headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/x-ndjson; charset=utf-8",
            "Transfer-Encoding: chunked",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
        ]
        if let origin {
            headers.append("Access-Control-Allow-Origin: \(origin)")
            headers.append("Vary: Origin")
        }
        headers.append("Access-Control-Allow-Methods: GET,POST,OPTIONS")
        headers.append("Access-Control-Allow-Headers: Content-Type,X-Gloss-Token,X-PIT-Token")
        headers.append("Access-Control-Allow-Private-Network: true")
        try await sendContent(
            Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8),
            to: connection
        )
    }

    private func sendStreamEvent(_ event: StreamEvent, to connection: NWConnection) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(event)
        line.append(0x0A)
        var chunk = Data(String(line.count, radix: 16).utf8)
        chunk.append(Data("\r\n".utf8))
        chunk.append(line)
        chunk.append(Data("\r\n".utf8))
        try await sendContent(chunk, to: connection)
    }

    private func finishStream(_ connection: NWConnection) async throws {
        try await sendContent(Data("0\r\n\r\n".utf8), to: connection)
        connection.cancel()
    }

    private func sendContent(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func send(
        data: Data,
        status: Int,
        origin: String?,
        to connection: NWConnection
    ) {
        let reason: String =
            switch status {
            case 200: "OK"
            case 204: "No Content"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 403: "Forbidden"
            case 404: "Not Found"
            case 413: "Payload Too Large"
            case 422: "Unprocessable Content"
            default: "Internal Server Error"
            }
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(data.count)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
        ]
        if let origin {
            headers.append("Access-Control-Allow-Origin: \(origin)")
            headers.append("Vary: Origin")
        }
        headers.append("Access-Control-Allow-Methods: GET,POST,OPTIONS")
        headers.append("Access-Control-Allow-Headers: Content-Type,X-Gloss-Token,X-PIT-Token")
        headers.append("Access-Control-Allow-Private-Network: true")
        headers.append("Access-Control-Max-Age: 600")

        var response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(data)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }
}
