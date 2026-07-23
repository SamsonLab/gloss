import Foundation
import XCTest

@testable import GlossCore

final class BabelDOCExecutorClientTests: XCTestCase {
    override func tearDown() {
        StubExecutorURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testRuntimeIdentityAndControlRequestsUseBearerAuthentication() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let requestLog = RequestLog()
        StubExecutorURLProtocol.setHandler { request in
            requestLog.append(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/runtime"):
                return .json(
                    Self.runtimePayload(
                        connection: fixture.connection,
                        parentPID: Int32(ProcessInfo.processInfo.processIdentifier)
                    )
                )
            case ("GET", "/v1/executions/current"):
                return .json([
                    "execution": Self.executionSnapshot(
                        executionID: "execution-1",
                        status: "running"
                    )
                ])
            case ("GET", "/v1/executions/latest"):
                return .json([
                    "execution": Self.executionSnapshot(
                        executionID: "execution-1",
                        status: "succeeded"
                    )
                ])
            case ("POST", "/v1/executions/execution-1/cancel"):
                return .json(
                    Self.executionSnapshot(
                        executionID: "execution-1",
                        status: "cancelling"
                    ),
                    status: 202
                )
            case ("POST", "/v1/shutdown"):
                return .json(["status": "stopping"], status: 202)
            default:
                return .json(["code": "not_found", "message": "not found"], status: 404)
            }
        }

        let client = fixture.client()
        let runtime = try await client.runtime()
        let current = try await client.currentExecution()
        let latest = try await client.latestExecution()
        XCTAssertEqual(runtime.runtime.version, "0.6.4+gloss.2")
        XCTAssertEqual(current?.status, "running")
        XCTAssertEqual(latest?.status, "succeeded")
        try await client.cancelCurrent()
        try await client.shutdown()

        let requests = requestLog.snapshot()
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization")
                    == "Bearer fixture-bearer-token-000000000000"
            }
        )
        let shutdown = try XCTUnwrap(
            requests.first { $0.url?.path == "/v1/shutdown" }
        )
        let shutdownBody = try Self.requestBody(shutdown)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: shutdownBody) as? [String: Bool],
            ["cancel_active": true]
        )
    }

    func testCancelledSubmissionPollsUntilMatchingExecutionRegisters() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let requestLog = RequestLog()
        let currentAttempts = LockedValues<Int>()

        StubExecutorURLProtocol.setHandler { request in
            requestLog.append(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/executions/current"):
                currentAttempts.append(1)
                if currentAttempts.snapshot().count < 3 {
                    return .json(["execution": NSNull()])
                }
                return .json([
                    "execution": Self.executionSnapshot(
                        executionID: "execution-delayed",
                        status: "running",
                        taskID: "task-delayed"
                    )
                ])
            case ("POST", "/v1/executions/execution-delayed/cancel"):
                return .json(
                    Self.executionSnapshot(
                        executionID: "execution-delayed",
                        status: "cancelling",
                        taskID: "task-delayed"
                    ),
                    status: 202
                )
            case ("GET", "/v1/executions/execution-delayed"):
                return .json(
                    Self.executionSnapshot(
                        executionID: "execution-delayed",
                        status: "cancelled",
                        taskID: "task-delayed"
                    )
                )
            default:
                return .json(["code": "not_found", "message": "not found"], status: 404)
            }
        }

        let reachedTerminal = await fixture.client().waitForCancelledWorker(
            executionID: nil,
            taskID: "task-delayed",
            registrationTimeout: .seconds(1),
            registrationPollInterval: .milliseconds(1)
        )

        XCTAssertTrue(reachedTerminal)
        XCTAssertEqual(currentAttempts.snapshot().count, 3)
        XCTAssertEqual(
            requestLog.snapshot().filter {
                $0.httpMethod == "POST"
                    && $0.url?.path == "/v1/executions/execution-delayed/cancel"
            }.count,
            1
        )
    }

    func testCancelledSubmissionNeverCancelsUnrelatedCurrentExecution() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let requestLog = RequestLog()

        StubExecutorURLProtocol.setHandler { request in
            requestLog.append(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/executions/current"):
                return .json([
                    "execution": Self.executionSnapshot(
                        executionID: "execution-unrelated",
                        status: "running",
                        taskID: "task-unrelated"
                    )
                ])
            case ("POST", "/v1/executions/execution-unrelated/cancel"):
                return .json(
                    Self.executionSnapshot(
                        executionID: "execution-unrelated",
                        status: "cancelling",
                        taskID: "task-unrelated"
                    ),
                    status: 202
                )
            default:
                return .json(["code": "not_found", "message": "not found"], status: 404)
            }
        }

        let reachedTerminal = await fixture.client().waitForCancelledWorker(
            executionID: nil,
            taskID: "task-cancelled",
            registrationTimeout: .milliseconds(25),
            registrationPollInterval: .milliseconds(5)
        )

        XCTAssertFalse(reachedTerminal)
        let requests = requestLog.snapshot()
        XCTAssertTrue(
            requests.contains {
                $0.httpMethod == "GET" && $0.url?.path == "/v1/executions/current"
            }
        )
        XCTAssertFalse(
            requests.contains {
                $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/cancel") == true
            }
        )
    }

    func testTranslationStreamsProgressAndMaterializesExecutorResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("source.pdf")
        try Data("%PDF-1.7\nfixture".utf8).write(to: input)
        let destination = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let progressValues = LockedValues<Double>()
        let submittedBody = LockedValues<[String: Any]>()
        let requestLog = RequestLog()

        StubExecutorURLProtocol.setHandler { request in
            requestLog.append(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/executions"):
                let body = try Self.requestBody(request)
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                submittedBody.append(object)
                let taskID = try XCTUnwrap(object["task_id"] as? String)
                let paths = try XCTUnwrap(object["paths"] as? [String: Any])
                let relativeOutput = try XCTUnwrap(paths["output_dir"] as? String)
                let output = fixture.root
                    .appendingPathComponent(relativeOutput, isDirectory: true)
                    .appendingPathComponent("translated_mono.pdf")
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("%PDF-1.7\ntranslated".utf8).write(to: output)
                fixture.setResultPath(
                    "\(relativeOutput)/translated_mono.pdf",
                    taskID: taskID
                )
                return .json(
                    [
                        "execution_id": "execution-1",
                        "status": "running",
                        "initial_sequence": 10,
                        "replayed": false,
                    ], status: 201)
            case ("GET", "/v1/executions/execution-1/events"):
                let resultPath = try XCTUnwrap(fixture.resultPath())
                return .ndjson([
                    Self.event(
                        type: "progress",
                        sequence: 11,
                        payload: [
                            "type": "progress_update",
                            "stage": "Translate Paragraphs",
                            "overall_progress": 42,
                            "performance": Self.performance(
                                phase: "translating",
                                elapsed: 750,
                                translating: 400,
                                cache: "hit"
                            ),
                        ],
                        connection: fixture.connection
                    ),
                    Self.event(
                        type: "result",
                        sequence: 12,
                        payload: [
                            "files": [
                                "mono_no_watermark_pdf": resultPath
                            ],
                            "metrics": [:],
                            "performance": Self.performance(
                                phase: "completed",
                                elapsed: 1_500,
                                translating: 800,
                                cache: "hit"
                            ),
                        ],
                        connection: fixture.connection
                    ),
                ])
            default:
                return .json(["code": "not_found", "message": "not found"], status: 404)
            }
        }

        let result = try await fixture.client().translate(
            BabelDOCTranslationRequest(
                inputURL: input,
                outputDirectory: destination,
                sourceLanguageCode: "en",
                targetLanguageCode: "zh-CN",
                bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
                bridgeToken: "bridge-secret",
                qps: 4,
                maximumPagesPerPart: 20,
                skipScannedDetection: true,
                outputMode: .monolingual,
                layoutServiceBaseURL: fixture.connection.layoutServiceBaseURL,
                layoutCacheDirectoryURL: fixture.root.appendingPathComponent("cache")
            ),
            onOutput: nil,
            onProgress: { update in progressValues.append(update.overallProgress) }
        )

        let output = try XCTUnwrap(result.monolingualPDF)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(result.layoutCacheStatus, "hit")
        XCTAssertEqual(result.timings.translatingMilliseconds, 800)
        XCTAssertTrue(progressValues.snapshot().contains(42))
        XCTAssertEqual(progressValues.snapshot().last, 100)
        let eventRequest = try XCTUnwrap(
            requestLog.snapshot().first {
                $0.url?.path == "/v1/executions/execution-1/events"
            }
        )
        XCTAssertEqual(eventRequest.timeoutInterval, 24 * 60 * 60)

        let request = try XCTUnwrap(submittedBody.snapshot().first)
        let translation = try XCTUnwrap(
            request["translation_config"] as? [String: Any]
        )
        XCTAssertEqual(translation["lang_in"] as? String, "en")
        XCTAssertEqual(translation["lang_out"] as? String, "zh-CN")
        XCTAssertEqual(translation["no_dual"] as? Bool, true)
        let assets = try XCTUnwrap(request["assets"] as? [String: Any])
        let cache = try XCTUnwrap(assets["layout_ir_cache"] as? [String: Any])
        XCTAssertEqual(cache["enabled"] as? Bool, true)
        let encodedBody = try JSONSerialization.data(withJSONObject: request)
        XCTAssertTrue(String(decoding: encodedBody, as: UTF8.self).contains("bridge-secret"))
    }

    func testReplayGapRecoversSucceededOutputFromAuthoritativeSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input = fixture.root.appendingPathComponent("source.pdf")
        try Data("%PDF-1.7\nfixture".utf8).write(to: input)
        let destination = fixture.root.appendingPathComponent("destination", isDirectory: true)

        StubExecutorURLProtocol.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/executions"):
                let body = try Self.requestBody(request)
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                let paths = try XCTUnwrap(object["paths"] as? [String: Any])
                let relativeOutput = try XCTUnwrap(paths["output_dir"] as? String)
                let output = fixture.root
                    .appendingPathComponent(relativeOutput, isDirectory: true)
                    .appendingPathComponent("translated_mono.pdf")
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("%PDF-1.7\nrecovered".utf8).write(to: output)
                return .json(
                    [
                        "execution_id": "execution-gap",
                        "status": "running",
                        "initial_sequence": 20,
                        "replayed": false,
                    ], status: 201)
            case ("GET", "/v1/executions/execution-gap/events"):
                return .json(
                    [
                        "code": "replay_gap",
                        "message": "history expired",
                        "snapshot": Self.executionSnapshot(
                            executionID: "execution-gap",
                            status: "succeeded",
                            initialSequence: 20,
                            firstAvailableSequence: 24,
                            lastSequence: 24
                        ),
                    ], status: 410)
            default:
                return .json(["code": "not_found", "message": "not found"], status: 404)
            }
        }

        let result = try await fixture.client().translate(
            BabelDOCTranslationRequest(
                inputURL: input,
                outputDirectory: destination,
                sourceLanguageCode: "en",
                targetLanguageCode: "zh-CN",
                bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
                bridgeToken: "bridge-secret"
            ),
            onOutput: nil,
            onProgress: nil
        )

        XCTAssertNotNil(result.monolingualPDF)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(result.monolingualPDF).path
            )
        )
    }

    func testConfiguredExecutorIsResolvedBesideLegacyRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("babeldoc")
        let executor = root.appendingPathComponent("gloss-babeldoc")
        for file in [legacy, executor] {
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: file.path,
                    contents: Data("#!/bin/sh\n".utf8),
                    attributes: [.posixPermissions: 0o700]
                )
            )
        }

        XCTAssertEqual(
            BabelDOCExternalEngine.resolveRuntime(
                environment: [
                    "GLOSS_BABELDOC_BIN": legacy.path,
                    "PATH": "",
                ]
            ),
            BabelDOCRuntimeLaunch(
                executable: legacy.path,
                source: "configured",
                executorExecutable: executor.path
            )
        )
    }

    func testSupportedExecutorNeverSilentlyFallsBackToPerFileCLI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input.pdf")
        try Data("%PDF-1.7\nfixture".utf8).write(to: input)
        let request = BabelDOCTranslationRequest(
            inputURL: input,
            outputDirectory: root.appendingPathComponent("output"),
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN",
            bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
            bridgeToken: "bridge-token"
        )
        let runtime = BabelDOCRuntimeLaunch(
            executable: "/does/not/run/babeldoc",
            source: "test",
            executorExecutable: "/does/not/run/gloss-babeldoc"
        )

        do {
            _ = try await BabelDOCExternalEngine().translate(
                request,
                runtime: runtime
            )
            XCTFail("Expected the missing executor session to fail")
        } catch let error as BabelDOCExecutorError {
            guard case .unavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testManagedRuntimeDoesNotFallbackWhenManagerReportsUnsupported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input.pdf")
        try Data("%PDF-1.7\nfixture".utf8).write(to: input)
        let request = BabelDOCTranslationRequest(
            inputURL: input,
            outputDirectory: root.appendingPathComponent("output"),
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN",
            bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
            bridgeToken: "bridge-token"
        )

        do {
            _ = try await BabelDOCExternalEngine(
                executorManager: UnsupportedExecutorManager()
            ).translate(
                request,
                runtime: BabelDOCRuntimeLaunch(
                    executable: "/does/not/run/gloss-babeldoc",
                    source: "managed",
                    executorExecutable: "/does/not/run/gloss-babeldoc"
                )
            )
            XCTFail("Expected managed runtime incompatibility")
        } catch let error as BabelDOCExecutorError {
            guard case .incompatibleRuntime = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNeverFallbackPolicyRejectsLegacyOnlyRuntimeBeforeLaunchingCLI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input.pdf")
        try Data("%PDF-1.7\nfixture".utf8).write(to: input)
        let request = BabelDOCTranslationRequest(
            inputURL: input,
            outputDirectory: root.appendingPathComponent("output"),
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN",
            bridgeBaseURL: URL(string: "http://127.0.0.1:8787/v1")!,
            bridgeToken: "bridge-token"
        )

        do {
            _ = try await BabelDOCExternalEngine(
                legacyFallbackPolicy: .never
            ).translate(
                request,
                runtime: BabelDOCRuntimeLaunch(
                    executable: "/does/not/run/babeldoc",
                    source: "legacy"
                )
            )
            XCTFail("Expected the explicit no-fallback policy to fail")
        } catch let error as BabelDOCExecutorError {
            XCTAssertEqual(error, .unsupportedRuntime)
        }
    }

    private static func runtimePayload(
        connection: BabelDOCExecutorConnection,
        parentPID: Int32
    ) -> [String: Any] {
        [
            "schema_version": 1,
            "runtime_api_version": 1,
            "runtime": [
                "name": "gloss-babeldoc",
                "version": "0.6.4+gloss.2",
            ],
            "upstream": [
                "name": "BabelDOC",
                "repository": "https://example.invalid",
                "version": "0.6.4",
                "commit": "fixture",
            ],
            "capabilities": [
                "executor.events.ndjson.v1",
                "executor.http.v1",
                "layout.rpc-doclayout8.v1",
                "runtime-info.v1",
            ],
            "service": [
                "schema_version": 1,
                "protocol_version": 1,
                "service_id": "gloss-babeldoc",
                "instance_id": connection.instanceID,
                "pid": connection.processIdentifier,
                "process_start_time":
                    connection.processStartTime.map { $0 as Any }
                    ?? (NSNull() as Any),
                "endpoint": connection.baseURL.absoluteString,
                "started_at": 1_000.0,
                "runner": "babeldoc",
                "parent_pid": parentPID,
                "parent_start_time": 999.0,
            ],
        ]
    }

    private static func executionSnapshot(
        executionID: String,
        status: String,
        taskID: String = "task-1",
        initialSequence: Int = 10,
        firstAvailableSequence: Int? = 11,
        lastSequence: Int = 12
    ) -> [String: Any] {
        [
            "execution_id": executionID,
            "task_id": taskID,
            "status": status,
            "initial_sequence": initialSequence,
            "first_available_sequence":
                firstAvailableSequence.map { $0 as Any }
                ?? (NSNull() as Any),
            "last_sequence": lastSequence,
            "worker_finished": status != "running" && status != "cancelling",
            "created_at": 1_000.0,
            "finished_at": status == "running" ? NSNull() : 1_001.0,
        ]
    }

    private static func event(
        type: String,
        sequence: Int,
        payload: [String: Any],
        connection: BabelDOCExecutorConnection
    ) -> [String: Any] {
        [
            "schema_version": 1,
            "service_id": "gloss-babeldoc",
            "instance_id": connection.instanceID,
            "type": type,
            "execution_id": "execution-1",
            "sequence": sequence,
            "emitted_at": 1_000.0,
            "payload": payload,
        ]
    }

    private static func performance(
        phase: String,
        elapsed: Int,
        translating: Int,
        cache: String
    ) -> [String: Any] {
        [
            "schema_version": 1,
            "phase": phase,
            "elapsed_milliseconds": elapsed,
            "phase_timings_milliseconds": [
                "launching": 100,
                "parsing": 200,
                "translating": translating,
                "typesetting": 200,
                "saving": 100,
                "finalizing": 100,
            ],
            "layout_ir_cache_status": cache,
        ]
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw try XCTUnwrap(stream.streamError)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private actor UnsupportedExecutorManager: BabelDOCExecutorManaging {
    func executorConnection(
        runtime: BabelDOCRuntimeLaunch,
        timeout: Duration
    ) async throws -> BabelDOCExecutorConnection {
        throw BabelDOCExecutorError.unsupportedRuntime
    }
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let connection: BabelDOCExecutorConnection
    private let lock = NSLock()
    private var storedResultPath: String?

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        connection = BabelDOCExecutorConnection(
            baseURL: URL(string: "http://127.0.0.1:49231")!,
            bearerToken: "fixture-bearer-token-000000000000",
            workrootURL: root,
            layoutServiceBaseURL: URL(string: "http://127.0.0.1:49232")!,
            instanceID: "fixture-instance",
            processIdentifier: 42,
            processStartTime: 900,
            runtimeVersion: "0.6.4+gloss.2"
        )
    }

    func client() -> BabelDOCExecutorClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubExecutorURLProtocol.self]
        return BabelDOCExecutorClient(
            connection: connection,
            sessionConfiguration: configuration
        )
    }

    func setResultPath(_ path: String, taskID _: String) {
        lock.lock()
        storedResultPath = path
        lock.unlock()
    }

    func resultPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedResultPath
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class StubExecutorURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> StubResponse

    nonisolated(unsafe) private static var handler: Handler?
    private static let lock = NSLock()

    static func setHandler(_ value: Handler?) {
        lock.lock()
        handler = value
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        do {
            let result = try XCTUnwrap(handler)(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: result.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": result.contentType,
                        "Content-Length": "\(result.data.count)",
                    ]
                )
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct StubResponse: Sendable {
    let status: Int
    let contentType: String
    let data: Data

    static func json(_ object: [String: Any], status: Int = 200) -> Self {
        Self(
            status: status,
            contentType: "application/json",
            data: try! JSONSerialization.data(withJSONObject: object)
        )
    }

    static func ndjson(_ objects: [[String: Any]]) -> Self {
        let lines =
            objects.map {
                String(
                    decoding: try! JSONSerialization.data(withJSONObject: $0),
                    as: UTF8.self
                )
            }.joined(separator: "\n") + "\n"
        return Self(
            status: 200,
            contentType: "application/x-ndjson",
            data: Data(lines.utf8)
        )
    }
}
