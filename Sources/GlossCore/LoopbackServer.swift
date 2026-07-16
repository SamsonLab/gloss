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

    private let queue = DispatchQueue(label: "com.samsoncj.gloss.loopback", qos: .userInitiated)
    private let broker: TranslationBroker
    private let providerStatus: @Sendable () async -> TranslationProviderStatus
    private let runtimeLog: GlossRuntimeLog
    private let token: String
    private let port: NWEndpoint.Port
    private let activeTasksLock = NSLock()
    private var activeTranslationTasks: [String: ActiveTranslationTask] = [:]
    private var listener: NWListener?
    package var onStateChange: (@Sendable (State) -> Void)?

    package init(
        broker: TranslationBroker,
        token: String,
        port: UInt16 = 8787,
        providerStatus: @escaping @Sendable () async -> TranslationProviderStatus = {
            TranslationProviderStatus(
                provider: .codex,
                model: TranslationProviderConfiguration.defaultCodexModel,
                reasoningEffort: .low,
                configurationRevision: "default",
                isWarm: true
            )
        },
        runtimeLog: GlossRuntimeLog = .shared
    ) {
        self.broker = broker
        self.providerStatus = providerStatus
        self.token = token
        self.port = NWEndpoint.Port(rawValue: port)!
        self.runtimeLog = runtimeLog
    }

    package func start() throws {
        guard listener == nil else { return }
        runtimeLog.write("bridge", "start address=127.0.0.1 port=\(port.rawValue)")
        onStateChange?(.starting)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.runtimeLog.write("bridge", "ready address=127.0.0.1 port=\(self.port.rawValue)")
                self.onStateChange?(.ready)
            case .failed(let error):
                self.runtimeLog.write("bridge", "failed error=\(error.localizedDescription)")
                self.onStateChange?(.failed(error.localizedDescription))
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

        let suppliedToken = request.headers["x-gloss-token"] ?? request.headers["x-pit-token"]
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
                        version: "0.1.0",
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
        entries.forEach { $0.task?.cancel() }
        return entries.count
    }

    private func cancelAllTranslationTasks() {
        activeTasksLock.lock()
        let entries = Array(activeTranslationTasks.values)
        activeTranslationTasks.removeAll(keepingCapacity: false)
        activeTasksLock.unlock()
        entries.forEach { $0.task?.cancel() }
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
