import Darwin
import Foundation

public enum BabelDOCServiceError: LocalizedError, Equatable, Sendable {
    case pythonUnavailable
    case executorUnavailable
    case launchFailed(String)
    case startupTimedOut(String)
    case terminationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pythonUnavailable:
            "BabelDOC 的 Python 运行环境不可用。"
        case .executorUnavailable:
            "当前 BabelDOC 运行时不支持常驻执行服务。"
        case .launchFailed(let reason):
            "无法启动 PDF 版面服务：\(reason)"
        case .startupTimedOut(let log):
            "PDF 版面服务启动超时。\(log.isEmpty ? "" : "\n\(log)")"
        case .terminationFailed(let reason):
            "无法安全停止 PDF 服务：\(reason)"
        }
    }
}

/// Owns the persistent DocLayout gateway and authenticated BabelDOC executor used
/// by a PDF module session. The two processes share one private workroot and are
/// tied to the Gloss process identity.
public actor BabelDOCServiceSession: BabelDOCExecutorManaging {
    public static let shared = BabelDOCServiceSession()
    /// A cold packaged runtime can spend close to two minutes loading the
    /// DocLayout model on first launch.
    public static let defaultStartupTimeout: Duration = .seconds(180)

    static let readyPrefix = "__GLOSS_BABELDOC_LAYOUT_READY__"
    static let executorReadyPrefix = "__GLOSS_BABELDOC_SERVICE_READY__"
    static let workingDirectoryPrefix = "Gloss-BabelDOC-Layout-"
    static let ownerPIDFileName = ".owner-pid"
    static let executorReadyFileName = ".executor-workroot-ready"
    static let executorTokenFileName = ".executor-token"
    static let persistedSessionFileName = "executor-session.json"
    static let legacyCleanupGraceInterval: TimeInterval = 24 * 60 * 60
    private static let layoutCacheDirectoryName = "layout-ir-cache"

    private final class OutputBuffer: @unchecked Sendable {
        private static let maximumBytes = 256 * 1_024
        private let lock = NSLock()
        private var data = Data()

        func append(_ value: Data) {
            lock.lock()
            if value.count >= Self.maximumBytes {
                data = Data(value.suffix(Self.maximumBytes))
            } else {
                data.append(value)
                if data.count > Self.maximumBytes {
                    data.removeFirst(data.count - Self.maximumBytes)
                }
            }
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return String(decoding: snapshot, as: UTF8.self)
        }
    }

    private final class ClientStateForwarder: @unchecked Sendable {
        typealias Handler =
            @Sendable (UInt64, BabelDOCExecutorClientState) async -> Void

        private let lock = NSLock()
        private let handler: Handler
        private var tail: Task<Void, Never>?
        private var nextOrdinal: UInt64 = 0

        init(handler: @escaping Handler) {
            self.handler = handler
        }

        func submit(_ state: BabelDOCExecutorClientState) {
            lock.lock()
            nextOrdinal &+= 1
            let ordinal = nextOrdinal
            let previous = tail
            let handler = handler
            let task = Task {
                await previous?.value
                await handler(ordinal, state)
            }
            tail = task
            lock.unlock()
        }
    }

    private var process: Process?
    private var outputPipe: Pipe?
    private var executorProcess: Process?
    private var executorOutputPipe: Pipe?
    private var adoptedLayoutProcessID: Int32?
    private var adoptedLayoutProcessStartTime: Double?
    private var workingDirectory: URL?
    private var serviceBaseURL: URL?
    private var executorConnectionValue: BabelDOCExecutorConnection?
    private var activeRuntimeExecutorPath: String?
    private var serviceSnapshotValue = BabelDOCExecutorServiceSnapshot(
        installed: false,
        lifecycleState: .stopped
    )
    private var shutdownInProgress = false
    private var clientStateGeneration: UInt64 = 0
    private var lastClientStateOrdinal: UInt64 = 0
    private var retiredExecutionIDs: Set<String> = []
    private var snapshotContinuations: [UUID: AsyncStream<BabelDOCExecutorServiceSnapshot>.Continuation] = [:]
    private var lifecycleOperationActive = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private let persistedStateDirectoryURL: URL

    private struct PersistedSession: Codable {
        let endpoint: URL
        let tokenFile: URL
        let workroot: URL
        let layoutEndpoint: URL
        let layoutPID: Int32?
        let layoutProcessStartTime: Double?
        let instanceID: String
        let pid: Int32
        let processStartTime: Double?
        let parentPID: Int32?
        let runtimeVersion: String
        let executorExecutable: String?
    }

    private struct PersistedSessionRecord {
        let session: PersistedSession
        let workrootIsMissing: Bool
    }

    private struct ExecutorReady: Decodable {
        let serviceID: String
        let instanceID: String
        let pid: Int32
        let processStartTime: Double?
        let endpoint: URL
        let parentPID: Int32?

        enum CodingKeys: String, CodingKey {
            case serviceID = "service_id"
            case instanceID = "instance_id"
            case pid
            case processStartTime = "process_start_time"
            case endpoint
            case parentPID = "parent_pid"
        }
    }

    public init(persistedStateDirectoryURL: URL? = nil) {
        self.persistedStateDirectoryURL =
            persistedStateDirectoryURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            .appendingPathComponent("Gloss/BabelDOC", isDirectory: true)
    }

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        executorOutputPipe?.fileHandleForReading.readabilityHandler = nil
        if executorProcess?.isRunning == true {
            executorProcess?.terminate()
        }
    }

    public var isRunning: Bool {
        (process?.isRunning == true || adoptedLayoutProcessID != nil)
            && serviceBaseURL != nil
            && (executorConnectionValue == nil
                || executorProcess?.isRunning == true
                || executorConnectionValue.map {
                    Self.processExists($0.processIdentifier)
                } == true)
    }

    public var layoutCacheDirectoryURL: URL? {
        guard isRunning, let workingDirectory else { return nil }
        return workingDirectory.appendingPathComponent(
            Self.layoutCacheDirectoryName,
            isDirectory: true
        )
    }

    public func snapshot() -> BabelDOCExecutorServiceSnapshot {
        serviceSnapshotValue
    }

    public func stateChanges() -> AsyncStream<BabelDOCExecutorServiceSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(serviceSnapshotValue)
            snapshotContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeSnapshotContinuation(id) }
            }
        }
    }

    public func currentExecution() async throws -> BabelDOCExecutorExecutionSnapshot? {
        guard let executorConnectionValue else { return nil }
        return try await BabelDOCExecutorClient(
            connection: executorConnectionValue
        ).currentExecution()
    }

    public func latestExecution() async throws -> BabelDOCExecutorExecutionSnapshot? {
        guard let executorConnectionValue else { return nil }
        return try await BabelDOCExecutorClient(
            connection: executorConnectionValue
        ).latestExecution()
    }

    public func cancelCurrent() async throws {
        guard let executorConnectionValue else { return }
        try await BabelDOCExecutorClient(
            connection: executorConnectionValue
        ).cancelCurrent()
    }

    public func start(
        runtime: BabelDOCRuntimeLaunch,
        timeout: Duration = defaultStartupTimeout
    ) async throws -> URL {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        try Task.checkCancellation()
        return try await startLocked(runtime: runtime, timeout: timeout)
    }

    private func startLocked(
        runtime: BabelDOCRuntimeLaunch,
        timeout: Duration
    ) async throws -> URL {
        if let process, process.isRunning, let serviceBaseURL {
            if runtime.executorExecutable == nil {
                return serviceBaseURL
            }
            if let connection = executorConnectionValue,
                serviceSnapshotValue.lifecycleState == .ready,
                activeRuntimeExecutorPath
                    == Self.normalizedExecutablePath(runtime.executorExecutable),
                executorProcess?.isRunning == true
                    || Self.processExists(connection.processIdentifier),
                (try? await BabelDOCExecutorClient(connection: connection).health())
                    == true,
                (try? await BabelDOCExecutorClient(connection: connection).runtime())
                    != nil
            {
                return serviceBaseURL
            }
            try await requireShutdownLocked()
        }
        if process == nil, executorProcess == nil,
            let restored = try? await restorePersistedConnection(
                expectedRuntime: runtime
            )
        {
            executorConnectionValue = restored
            serviceBaseURL = restored.layoutServiceBaseURL
            workingDirectory = restored.workrootURL
            if let persisted = try? Self.readPersistedSession(
                at: persistedSessionURL
            ) {
                adoptedLayoutProcessID = persisted.layoutPID
                adoptedLayoutProcessStartTime =
                    persisted.layoutProcessStartTime
                activeRuntimeExecutorPath = persisted.executorExecutable
            }
            await BabelDOCExecutorConnectionRegistry.shared.register(restored)
            updateSnapshot(connection: restored, lifecycle: .ready, error: nil)
            return restored.layoutServiceBaseURL
        }
        try await cleanupPersistedServiceLocked()
        try Task.checkCancellation()
        updateSnapshot(
            installed: runtime.executorExecutable != nil,
            lifecycle: .starting,
            error: nil
        )
        try await requireShutdownLocked()
        updateSnapshot(
            installed: runtime.executorExecutable != nil,
            lifecycle: .starting,
            error: nil
        )
        Self.cleanupStaleWorkingDirectories()

        let legacyInterpreter =
            runtime.executorExecutable == nil
            ? BabelDOCExternalEngine.pythonInterpreter(for: runtime.executable)
            : nil
        if runtime.executorExecutable == nil, legacyInterpreter == nil {
            throw BabelDOCServiceError.pythonUnavailable
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
        let directory =
            temporaryRoot.appendingPathComponent(
                "\(Self.workingDirectoryPrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        var shouldRemoveDirectory = true
        defer {
            if shouldRemoveDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for (name, contents) in [
            (Self.executorReadyFileName, UUID().uuidString + "\n"),
            (Self.executorTokenFileName, Self.makeBearerToken() + "\n"),
        ] {
            let url = directory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        let ownerPIDURL = directory.appendingPathComponent(Self.ownerPIDFileName)
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(
            to: ownerPIDURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: ownerPIDURL.path
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(
                Self.layoutCacheDirectoryName,
                isDirectory: true
            ),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let scriptURL = directory.appendingPathComponent("layout_service.py")
        if runtime.executorExecutable == nil {
            try Data(Self.layoutServiceScript.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: scriptURL.path
            )
        }

        let serviceProcess = Process()
        let pipe = Pipe()
        let output = OutputBuffer()
        let layoutLaunch = try Self.layoutLaunch(
            runtime: runtime,
            legacyInterpreter: legacyInterpreter,
            scriptURL: scriptURL,
            parentPID: Int32(ProcessInfo.processInfo.processIdentifier),
            layoutModel: ProcessInfo.processInfo.environment[
                "GLOSS_BABELDOC_LAYOUT_MODEL"
            ]
        )
        serviceProcess.executableURL = URL(fileURLWithPath: layoutLaunch.executable)
        serviceProcess.arguments = layoutLaunch.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        serviceProcess.environment = environment
        serviceProcess.standardOutput = pipe
        serviceProcess.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.append(data)
        }
        serviceProcess.terminationHandler = { [weak self] terminated in
            Task {
                await self?.layoutExited(
                    processIdentifier: terminated.processIdentifier,
                    status: terminated.terminationStatus
                )
            }
        }

        do {
            try serviceProcess.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw BabelDOCServiceError.launchFailed(error.localizedDescription)
        }

        process = serviceProcess
        outputPipe = pipe
        workingDirectory = directory
        shouldRemoveDirectory = false

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            while clock.now < deadline {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if let port = Self.readyPort(in: output.string()) {
                    let baseURL = URL(string: "http://127.0.0.1:\(port)")!
                    serviceBaseURL = baseURL
                    if runtime.executorExecutable != nil {
                        do {
                            _ = try await launchExecutor(
                                runtime: runtime,
                                layoutServiceBaseURL: baseURL,
                                workroot: directory,
                                deadline: deadline
                            )
                        } catch {
                            updateSnapshot(
                                installed: true,
                                lifecycle: .failed,
                                error: error.localizedDescription
                            )
                            _ = await shutdownLocked(cancelActive: true)
                            throw error
                        }
                    } else {
                        updateSnapshot(
                            installed: false,
                            lifecycle: .ready,
                            error: nil
                        )
                    }
                    return baseURL
                }
                if !serviceProcess.isRunning {
                    let message = Self.tail(of: output.string())
                    _ = await shutdownLocked(cancelActive: true)
                    throw BabelDOCServiceError.launchFailed(
                        message.isEmpty ? "进程已退出" : message
                    )
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch is CancellationError {
            _ = await shutdownLocked(cancelActive: true)
            throw CancellationError()
        }

        let message = Self.tail(of: output.string())
        _ = await shutdownLocked(cancelActive: true)
        updateSnapshot(
            installed: runtime.executorExecutable != nil,
            lifecycle: .failed,
            error: message
        )
        throw BabelDOCServiceError.startupTimedOut(message)
    }

    @discardableResult
    public func stop() async -> Bool {
        await shutdown(cancelActive: true)
    }

    @discardableResult
    public func shutdown(cancelActive: Bool = true) async -> Bool {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        return await shutdownLocked(cancelActive: cancelActive)
    }

    private func requireShutdownLocked() async throws {
        guard await shutdownLocked(cancelActive: true) else {
            throw BabelDOCServiceError.terminationFailed(
                serviceSnapshotValue.lastError ?? "子进程仍在运行"
            )
        }
    }

    private func shutdownLocked(cancelActive: Bool) async -> Bool {
        let previousInstalled = serviceSnapshotValue.installed
        updateSnapshot(
            installed: previousInstalled,
            lifecycle: .stopping,
            error: serviceSnapshotValue.lastError
        )
        let connection = executorConnectionValue
        let runningProcess = process
        let pipe = outputPipe
        let runningExecutor = executorProcess
        let executorPipe = executorOutputPipe
        let adoptedLayoutPID = adoptedLayoutProcessID
        let adoptedLayoutStartTime = adoptedLayoutProcessStartTime
        let directory = workingDirectory
        let ownsSession =
            connection != nil || runningProcess != nil || runningExecutor != nil
            || adoptedLayoutPID != nil || directory != nil
        guard ownsSession else {
            updateSnapshot(
                installed: previousInstalled,
                lifecycle: .stopped,
                error: nil
            )
            return true
        }

        shutdownInProgress = true
        invalidateClientStateHandler()
        defer { shutdownInProgress = false }
        if let connection {
            await BabelDOCExecutorConnectionRegistry.shared.unregister(
                layoutServiceBaseURL: connection.layoutServiceBaseURL
            )
            try? await BabelDOCExecutorClient(connection: connection).shutdown(
                cancelActive: cancelActive
            )
        }

        let executorExited: Bool
        if let runningExecutor, runningExecutor.isRunning {
            executorExited = await Self.terminateChildProcess(
                runningExecutor,
                allowGracefulExit: true
            )
        } else if let connection,
            Self.processExists(connection.processIdentifier)
        {
            executorExited = await Self.terminateVerifiedProcess(
                connection.processIdentifier,
                expectedStartTime: connection.processStartTime,
                allowGracefulExit: true
            )
        } else {
            executorExited = true
        }

        let layoutExited: Bool
        if let runningProcess, runningProcess.isRunning {
            layoutExited = await Self.terminateChildProcess(
                runningProcess,
                allowGracefulExit: false
            )
        } else if let adoptedLayoutPID,
            Self.processMatches(
                adoptedLayoutPID,
                expectedStartTime: adoptedLayoutStartTime
            )
        {
            layoutExited = await Self.terminateVerifiedProcess(
                adoptedLayoutPID,
                expectedStartTime: adoptedLayoutStartTime,
                allowGracefulExit: false
            )
        } else {
            layoutExited =
                adoptedLayoutPID.map { !Self.processExists($0) } ?? true
        }

        guard executorExited, layoutExited else {
            let livePIDs = [
                connection?.processIdentifier,
                runningExecutor?.processIdentifier,
                runningProcess?.processIdentifier,
                adoptedLayoutPID,
            ]
            .compactMap { $0 }
            .filter(Self.processExists)
            .map(String.init)
            .joined(separator: ", ")
            let message =
                livePIDs.isEmpty
                ? "无法确认子进程已经退出"
                : "子进程仍在运行（PID \(livePIDs)）"
            updateSnapshot(
                installed: previousInstalled,
                lifecycle: .failed,
                error: message
            )
            return false
        }

        pipe?.fileHandleForReading.readabilityHandler = nil
        executorPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outputPipe = nil
        executorProcess = nil
        executorOutputPipe = nil
        adoptedLayoutProcessID = nil
        adoptedLayoutProcessStartTime = nil
        executorConnectionValue = nil
        activeRuntimeExecutorPath = nil
        workingDirectory = nil
        serviceBaseURL = nil
        removePersistedSessionIfOwned(
            connection: connection,
            directory: directory
        )
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        updateSnapshot(
            installed: previousInstalled,
            lifecycle: .stopped,
            error: nil
        )
        return true
    }

    public func executorConnection(
        runtime: BabelDOCRuntimeLaunch,
        timeout: Duration
    ) async throws -> BabelDOCExecutorConnection {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        try Task.checkCancellation()
        if let executorConnectionValue,
            serviceSnapshotValue.lifecycleState == .ready,
            activeRuntimeExecutorPath
                == Self.normalizedExecutablePath(runtime.executorExecutable),
            executorProcess?.isRunning == true
                || Self.processExists(executorConnectionValue.processIdentifier)
        {
            return executorConnectionValue
        }
        _ = try await startLocked(runtime: runtime, timeout: timeout)
        guard let executorConnectionValue else {
            throw BabelDOCExecutorError.unsupportedRuntime
        }
        return executorConnectionValue
    }

    public func reconnect(
        runtime: BabelDOCRuntimeLaunch,
        force: Bool = false,
        timeout: Duration = defaultStartupTimeout
    ) async throws -> URL {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        try Task.checkCancellation()
        updateSnapshot(
            installed: runtime.executorExecutable != nil,
            lifecycle: .reconnecting,
            error: nil
        )
        if force {
            try await requireShutdownLocked()
            try await cleanupPersistedServiceLocked()
        } else if let restored = try await restorePersistedConnection(
            expectedRuntime: runtime
        ) {
            executorConnectionValue = restored
            if let persisted = try? Self.readPersistedSession(
                at: persistedSessionURL
            ) {
                activeRuntimeExecutorPath = persisted.executorExecutable
            }
            await BabelDOCExecutorConnectionRegistry.shared.register(restored)
            updateSnapshot(
                connection: restored,
                lifecycle: .ready,
                error: nil
            )
            return restored.layoutServiceBaseURL
        }
        return try await startLocked(runtime: runtime, timeout: timeout)
    }

    /// Removes a service left by an earlier app session without starting a new
    /// one. A live process is only signalled after its authenticated runtime
    /// identity (and the layout health identity) match the private marker.
    public func cleanupPersistedService() async throws {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        try await cleanupPersistedServiceLocked()
    }

    private func cleanupPersistedServiceLocked() async throws {
        guard
            let record = try Self.readPersistedSessionRecord(
                at: persistedSessionURL,
                allowMissingWorkroot: true
            )
        else { return }
        let persisted = record.session
        if record.workrootIsMissing {
            guard Self.processIsDefinitelyAbsent(persisted.pid),
                persisted.layoutPID.map(Self.processIsDefinitelyAbsent) ?? true
            else {
                throw BabelDOCExecutorError.incompatibleRuntime(
                    "旧 PDF 服务进程仍存活或状态无法确认，已保留会话 marker"
                )
            }
            try FileManager.default.removeItem(at: persistedSessionURL)
            return
        }
        if executorConnectionValue?.processIdentifier == persisted.pid {
            guard await shutdownLocked(cancelActive: true) else {
                throw BabelDOCExecutorError.unavailable(
                    serviceSnapshotValue.lastError ?? "当前 PDF 服务仍在运行"
                )
            }
            return
        }

        if Self.processExists(persisted.pid) {
            try await terminatePersistedServiceIfVerified()
        }
        if let layoutPID = persisted.layoutPID,
            Self.processExists(layoutPID)
        {
            guard
                Self.processMatches(
                    layoutPID,
                    expectedStartTime: persisted.layoutProcessStartTime
                )
            else {
                throw BabelDOCExecutorError.incompatibleRuntime(
                    "旧 DocLayout 进程身份无法验证，已拒绝终止"
                )
            }
            try await Self.verifyLayoutService(persisted.layoutEndpoint)
            let exited = await Self.terminateVerifiedProcess(
                layoutPID,
                expectedStartTime: persisted.layoutProcessStartTime,
                allowGracefulExit: false
            )
            if !exited {
                throw BabelDOCExecutorError.unavailable(
                    "旧 DocLayout 服务未在超时前退出"
                )
            }
        }
        guard !Self.processExists(persisted.pid),
            persisted.layoutPID.map({ !Self.processExists($0) }) ?? true
        else {
            throw BabelDOCExecutorError.unavailable("旧 PDF 服务仍在运行")
        }
        try Self.removePrivateWorkroot(persisted.workroot)
        try? FileManager.default.removeItem(at: persistedSessionURL)
    }

    static func readyPort(in output: String) -> Int? {
        guard let range = output.range(of: readyPrefix) else { return nil }
        let suffix = output[range.upperBound...]
        let digits = suffix.prefix(while: { $0.isNumber })
        guard let port = Int(digits), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    static func layoutLaunch(
        runtime: BabelDOCRuntimeLaunch,
        legacyInterpreter: String?,
        scriptURL: URL,
        parentPID: Int32,
        layoutModel: String? = nil
    ) throws -> (executable: String, arguments: [String]) {
        var commonArguments = [
            "--host", "127.0.0.1",
            "--port", "0",
            "--parent-pid", String(parentPID),
        ]
        if let layoutModel, !layoutModel.isEmpty {
            commonArguments.append(contentsOf: ["--model", layoutModel])
        }
        if let executor = runtime.executorExecutable {
            return (executor, ["layout-serve"] + commonArguments)
        }
        guard let legacyInterpreter else {
            throw BabelDOCServiceError.pythonUnavailable
        }
        return (legacyInterpreter, [scriptURL.path] + commonArguments)
    }

    private static func executorReady(in output: String) -> ExecutorReady? {
        guard let prefix = output.range(of: executorReadyPrefix) else { return nil }
        let suffix = output[prefix.upperBound...]
        let line = suffix.prefix { !$0.isNewline }
        guard let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExecutorReady.self, from: data)
    }

    private func launchExecutor(
        runtime: BabelDOCRuntimeLaunch,
        layoutServiceBaseURL: URL,
        workroot: URL,
        deadline: ContinuousClock.Instant
    ) async throws -> BabelDOCExecutorConnection {
        guard let executable = runtime.executorExecutable else {
            throw BabelDOCExecutorError.unsupportedRuntime
        }
        let tokenFile = workroot.appendingPathComponent(Self.executorTokenFileName)
        let token = try Self.readPrivateToken(at: tokenFile)
        let instanceID = UUID().uuidString.lowercased()
        let serviceProcess = Process()
        let pipe = Pipe()
        let output = OutputBuffer()
        serviceProcess.executableURL = URL(fileURLWithPath: executable)
        serviceProcess.arguments = [
            "serve",
            "--host", "127.0.0.1",
            "--port", "0",
            "--runner", "babeldoc",
            "--token-file", tokenFile.path,
            "--work-dir", workroot.path,
            "--instance-id", instanceID,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        serviceProcess.environment = environment
        serviceProcess.standardOutput = pipe
        serviceProcess.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.append(data)
        }
        do {
            try serviceProcess.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw BabelDOCServiceError.launchFailed(error.localizedDescription)
        }
        executorProcess = serviceProcess
        executorOutputPipe = pipe

        let clock = ContinuousClock()
        while clock.now < deadline {
            try Task.checkCancellation()
            if let ready = Self.executorReady(in: output.string()) {
                guard ready.serviceID == "gloss-babeldoc",
                    ready.instanceID == instanceID,
                    ready.pid == serviceProcess.processIdentifier,
                    ready.parentPID == Int32(ProcessInfo.processInfo.processIdentifier),
                    ready.endpoint.host == "127.0.0.1",
                    ready.endpoint.scheme == "http",
                    ready.endpoint.port != nil
                else {
                    throw BabelDOCExecutorError.incompatibleRuntime(
                        "ready handshake 身份不一致"
                    )
                }
                let stateHandler = makeClientStateHandler()
                var connection = BabelDOCExecutorConnection(
                    baseURL: ready.endpoint,
                    bearerToken: token,
                    workrootURL: workroot,
                    layoutServiceBaseURL: layoutServiceBaseURL,
                    instanceID: instanceID,
                    processIdentifier: ready.pid,
                    processStartTime: ready.processStartTime,
                    runtimeVersion: "unknown",
                    _stateHandler: stateHandler
                )
                let runtimeInfo = try await BabelDOCExecutorClient(
                    connection: connection
                ).runtime()
                connection = BabelDOCExecutorConnection(
                    baseURL: connection.baseURL,
                    bearerToken: connection.bearerToken,
                    workrootURL: connection.workrootURL,
                    layoutServiceBaseURL: connection.layoutServiceBaseURL,
                    instanceID: connection.instanceID,
                    processIdentifier: connection.processIdentifier,
                    processStartTime: connection.processStartTime,
                    runtimeVersion: runtimeInfo.runtime.version,
                    _stateHandler: stateHandler
                )
                executorConnectionValue = connection
                await BabelDOCExecutorConnectionRegistry.shared.register(connection)
                activeRuntimeExecutorPath = Self.normalizedExecutablePath(
                    runtime.executorExecutable
                )
                try persist(
                    connection: connection,
                    tokenFile: tokenFile,
                    executorExecutable: activeRuntimeExecutorPath
                )
                updateSnapshot(connection: connection, lifecycle: .ready, error: nil)
                serviceProcess.terminationHandler = { [weak self] terminated in
                    Task {
                        await self?.executorExited(
                            processIdentifier: terminated.processIdentifier,
                            status: terminated.terminationStatus
                        )
                    }
                }
                return connection
            }
            if !serviceProcess.isRunning {
                throw BabelDOCServiceError.launchFailed(
                    Self.tail(of: output.string())
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BabelDOCServiceError.startupTimedOut(Self.tail(of: output.string()))
    }

    private func persist(
        connection: BabelDOCExecutorConnection,
        tokenFile: URL,
        executorExecutable: String?
    ) throws {
        try FileManager.default.createDirectory(
            at: persistedStateDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: persistedStateDirectoryURL.path
        )
        let persisted = PersistedSession(
            endpoint: connection.baseURL,
            tokenFile: tokenFile,
            workroot: connection.workrootURL,
            layoutEndpoint: connection.layoutServiceBaseURL,
            layoutPID: process?.processIdentifier ?? adoptedLayoutProcessID,
            layoutProcessStartTime:
                process.flatMap {
                    Self.processStartTime($0.processIdentifier)
                } ?? adoptedLayoutProcessStartTime,
            instanceID: connection.instanceID,
            pid: connection.processIdentifier,
            processStartTime: connection.processStartTime,
            parentPID: connection.parentProcessIdentifier,
            runtimeVersion: connection.runtimeVersion,
            executorExecutable: executorExecutable
        )
        try Self.writePrivateAtomicFile(
            JSONEncoder().encode(persisted),
            to: persistedSessionURL
        )
    }

    private func restorePersistedConnection(
        expectedRuntime: BabelDOCRuntimeLaunch
    ) async throws -> BabelDOCExecutorConnection? {
        guard let persisted = try Self.readPersistedSession(at: persistedSessionURL),
            persisted.parentPID == Int32(ProcessInfo.processInfo.processIdentifier),
            persisted.executorExecutable
                == Self.normalizedExecutablePath(expectedRuntime.executorExecutable)
        else { return nil }
        let token = try Self.readPrivateToken(at: persisted.tokenFile)
        let connection = connection(from: persisted, token: token)
        do {
            _ = try await BabelDOCExecutorClient(connection: connection).health()
            _ = try await BabelDOCExecutorClient(connection: connection).runtime()
            try await Self.verifyLayoutService(persisted.layoutEndpoint)
            return connection
        } catch {
            return nil
        }
    }

    private func terminatePersistedServiceIfVerified() async throws {
        guard let persisted = try Self.readPersistedSession(at: persistedSessionURL)
        else { return }
        let token = try Self.readPrivateToken(at: persisted.tokenFile)
        let connection = connection(from: persisted, token: token)
        let client = BabelDOCExecutorClient(connection: connection)
        do {
            _ = try await client.health(requireCurrentParent: false)
            _ = try await client.runtime(requireCurrentParent: false)
        } catch {
            throw BabelDOCExecutorError.incompatibleRuntime(
                "无法验证旧服务身份，已拒绝终止该进程"
            )
        }
        try await client.shutdown(cancelActive: true)
        let exited = await Self.terminateVerifiedProcess(
            persisted.pid,
            expectedStartTime: persisted.processStartTime,
            allowGracefulExit: true
        )
        guard exited else {
            throw BabelDOCExecutorError.unavailable(
                "已验证的旧 executor 未在强制清理后退出"
            )
        }
    }

    private func connection(
        from persisted: PersistedSession,
        token: String
    ) -> BabelDOCExecutorConnection {
        let stateHandler = makeClientStateHandler()
        return BabelDOCExecutorConnection(
            baseURL: persisted.endpoint,
            bearerToken: token,
            workrootURL: persisted.workroot,
            layoutServiceBaseURL: persisted.layoutEndpoint,
            instanceID: persisted.instanceID,
            processIdentifier: persisted.pid,
            processStartTime: persisted.processStartTime,
            parentProcessIdentifier: persisted.parentPID,
            runtimeVersion: persisted.runtimeVersion,
            _stateHandler: stateHandler
        )
    }

    private var persistedSessionURL: URL {
        persistedStateDirectoryURL.appendingPathComponent(
            Self.persistedSessionFileName
        )
    }

    private func makeClientStateHandler()
        -> @Sendable (BabelDOCExecutorClientState) -> Void
    {
        clientStateGeneration &+= 1
        lastClientStateOrdinal = 0
        retiredExecutionIDs.removeAll(keepingCapacity: true)
        let generation = clientStateGeneration
        let forwarder = ClientStateForwarder { [weak self] ordinal, state in
            await self?.receiveClientState(
                state,
                generation: generation,
                ordinal: ordinal
            )
        }
        return { state in
            forwarder.submit(state)
        }
    }

    private func invalidateClientStateHandler() {
        clientStateGeneration &+= 1
        lastClientStateOrdinal = 0
        retiredExecutionIDs.removeAll(keepingCapacity: true)
    }

    private func receiveClientState(
        _ state: BabelDOCExecutorClientState,
        generation: UInt64,
        ordinal: UInt64
    ) {
        guard generation == clientStateGeneration,
            ordinal > lastClientStateOrdinal,
            serviceSnapshotValue.lifecycleState == .ready
        else { return }
        lastClientStateOrdinal = ordinal

        let isSubmitting = state.status == "submitting"
        if isSubmitting, let taskID = state.taskID {
            if let activeExecutionID = serviceSnapshotValue.activeExecutionID {
                retiredExecutionIDs.insert(activeExecutionID)
            }
            serviceSnapshotValue = BabelDOCExecutorServiceSnapshot(
                installed: serviceSnapshotValue.installed,
                runtimeVersion: serviceSnapshotValue.runtimeVersion,
                endpoint: serviceSnapshotValue.endpoint,
                processIdentifier: serviceSnapshotValue.processIdentifier,
                processStartTime: serviceSnapshotValue.processStartTime,
                instanceID: serviceSnapshotValue.instanceID,
                lifecycleState: serviceSnapshotValue.lifecycleState,
                activeTaskID: taskID,
                activeExecutionID: state.executionID,
                activeStatus: state.status,
                activeProgress: state.progress,
                lastError: nil
            )
            publishSnapshot()
            return
        }

        if let taskID = state.taskID,
            let activeTaskID = serviceSnapshotValue.activeTaskID,
            taskID != activeTaskID
        {
            return
        }
        if let executionID = state.executionID {
            guard !retiredExecutionIDs.contains(executionID) else { return }
            if let activeExecutionID = serviceSnapshotValue.activeExecutionID,
                executionID != activeExecutionID
            {
                return
            }
        }
        serviceSnapshotValue = BabelDOCExecutorServiceSnapshot(
            installed: serviceSnapshotValue.installed,
            runtimeVersion: serviceSnapshotValue.runtimeVersion,
            endpoint: serviceSnapshotValue.endpoint,
            processIdentifier: serviceSnapshotValue.processIdentifier,
            processStartTime: serviceSnapshotValue.processStartTime,
            instanceID: serviceSnapshotValue.instanceID,
            lifecycleState: serviceSnapshotValue.lifecycleState,
            activeTaskID: state.taskID ?? serviceSnapshotValue.activeTaskID,
            activeExecutionID:
                state.executionID ?? serviceSnapshotValue.activeExecutionID,
            activeStatus: state.status,
            activeProgress: state.progress,
            lastError: state.error
        )
        publishSnapshot()
    }

    private func executorExited(
        processIdentifier: Int32,
        status: Int32
    ) async {
        guard !shutdownInProgress else { return }
        guard let connection = executorConnectionValue,
            connection.processIdentifier == processIdentifier
        else {
            return
        }
        invalidateClientStateHandler()
        await BabelDOCExecutorConnectionRegistry.shared.unregister(
            layoutServiceBaseURL: connection.layoutServiceBaseURL
        )
        executorConnectionValue = nil
        executorProcess = nil
        executorOutputPipe?.fileHandleForReading.readabilityHandler = nil
        executorOutputPipe = nil
        updateSnapshot(
            installed: serviceSnapshotValue.installed,
            lifecycle: serviceSnapshotValue.lifecycleState == .stopping
                ? .stopped
                : .failed,
            error: serviceSnapshotValue.lifecycleState == .stopping
                ? nil
                : "executor 进程已退出（状态 \(status)）"
        )
    }

    private func layoutExited(
        processIdentifier: Int32,
        status: Int32
    ) async {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        guard !shutdownInProgress,
            process?.processIdentifier == processIdentifier
        else { return }
        let message = "DocLayout 进程已退出（状态 \(status)）"
        invalidateClientStateHandler()
        updateSnapshot(
            installed: serviceSnapshotValue.installed,
            lifecycle: .failed,
            error: message
        )
        let stopped = await shutdownLocked(cancelActive: true)
        if stopped {
            updateSnapshot(
                installed: serviceSnapshotValue.installed,
                lifecycle: .failed,
                error: message
            )
        }
    }

    private func updateSnapshot(
        connection: BabelDOCExecutorConnection? = nil,
        installed: Bool? = nil,
        lifecycle: BabelDOCExecutorLifecycleState,
        error: String?
    ) {
        let connection = connection ?? executorConnectionValue
        serviceSnapshotValue = BabelDOCExecutorServiceSnapshot(
            installed: installed ?? serviceSnapshotValue.installed,
            runtimeVersion:
                connection?.runtimeVersion ?? serviceSnapshotValue.runtimeVersion,
            endpoint: connection?.baseURL,
            processIdentifier: connection?.processIdentifier,
            processStartTime: connection?.processStartTime,
            instanceID: connection?.instanceID,
            lifecycleState: lifecycle,
            activeTaskID:
                lifecycle == .stopped ? nil : serviceSnapshotValue.activeTaskID,
            activeExecutionID:
                lifecycle == .stopped ? nil : serviceSnapshotValue.activeExecutionID,
            activeStatus:
                lifecycle == .stopped ? nil : serviceSnapshotValue.activeStatus,
            activeProgress:
                lifecycle == .stopped ? nil : serviceSnapshotValue.activeProgress,
            lastError: error
        )
        publishSnapshot()
    }

    private func publishSnapshot() {
        for continuation in snapshotContinuations.values {
            continuation.yield(serviceSnapshotValue)
        }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func acquireLifecycleOperation() async {
        if !lifecycleOperationActive {
            lifecycleOperationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleWaiters.append(continuation)
        }
    }

    private func releaseLifecycleOperation() {
        guard !lifecycleWaiters.isEmpty else {
            lifecycleOperationActive = false
            return
        }
        lifecycleWaiters.removeFirst().resume()
    }

    private func removePersistedSessionIfOwned(
        connection: BabelDOCExecutorConnection?,
        directory: URL?
    ) {
        guard
            let persisted = try? Self.readPersistedSession(
                at: persistedSessionURL
            )
        else { return }
        let connectionMatches =
            connection.map {
                persisted.instanceID == $0.instanceID
                    && persisted.pid == $0.processIdentifier
            } ?? false
        let directoryMatches =
            directory.map {
                persisted.workroot.resolvingSymlinksInPath().standardizedFileURL
                    == $0.resolvingSymlinksInPath().standardizedFileURL
            } ?? false
        guard connectionMatches || directoryMatches,
            !Self.processExists(persisted.pid),
            persisted.layoutPID.map({ !Self.processExists($0) }) ?? true
        else { return }
        try? FileManager.default.removeItem(at: persistedSessionURL)
    }

    private static func makeBearerToken() -> String {
        (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func normalizedExecutablePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    private static func readPrivateToken(at url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid(),
            info.st_mode & 0o077 == 0
        else {
            throw BabelDOCExecutorError.incompatibleRuntime(
                "executor token 文件权限不安全"
            )
        }
        let token = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...256).contains(token.count),
            token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else {
            throw BabelDOCExecutorError.incompatibleRuntime("executor token 无效")
        }
        return token
    }

    private static func readPersistedSession(at url: URL) throws -> PersistedSession? {
        try readPersistedSessionRecord(
            at: url,
            allowMissingWorkroot: false
        )?.session
    }

    private static func readPersistedSessionRecord(
        at url: URL,
        allowMissingWorkroot: Bool
    ) throws -> PersistedSessionRecord? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid()
        else {
            throw BabelDOCExecutorError.incompatibleRuntime("会话 marker 权限不安全")
        }
        if info.st_mode & 0o077 != 0 {
            let permissions = info.st_mode & 0o777
            guard permissions & 0o700 == 0o600,
                permissions & 0o111 == 0
            else {
                throw BabelDOCExecutorError.incompatibleRuntime(
                    "会话 marker 权限不安全"
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            guard lstat(url.path, &info) == 0,
                info.st_mode & S_IFMT == S_IFREG,
                info.st_uid == getuid(),
                info.st_mode & 0o777 == 0o600
            else {
                throw BabelDOCExecutorError.incompatibleRuntime(
                    "无法修复会话 marker 权限"
                )
            }
        }
        let persisted = try JSONDecoder().decode(
            PersistedSession.self,
            from: Data(contentsOf: url)
        )
        let canonicalWorkroot = persisted.workroot.resolvingSymlinksInPath()
            .standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL
        let temporaryPrefix =
            temporaryRoot.path.hasSuffix("/")
            ? temporaryRoot.path
            : temporaryRoot.path + "/"
        var workrootInfo = stat()
        guard canonicalWorkroot.path.hasPrefix(temporaryPrefix),
            canonicalWorkroot.lastPathComponent.hasPrefix(workingDirectoryPrefix),
            persisted.tokenFile.resolvingSymlinksInPath().standardizedFileURL
                == canonicalWorkroot.appendingPathComponent(executorTokenFileName),
            persisted.endpoint.scheme == "http",
            persisted.endpoint.host == "127.0.0.1",
            persisted.endpoint.port != nil,
            persisted.layoutEndpoint.scheme == "http",
            persisted.layoutEndpoint.host == "127.0.0.1",
            persisted.layoutEndpoint.port != nil,
            persisted.layoutPID.map({ $0 > 0 }) ?? true,
            persisted.layoutProcessStartTime.map({ $0 > 0 }) ?? true,
            persisted.executorExecutable.map({
                $0.hasPrefix("/")
                    && Self.normalizedExecutablePath($0) == $0
            }) ?? true,
            persisted.pid > 0
        else {
            throw BabelDOCExecutorError.incompatibleRuntime("会话 marker 内容无效")
        }
        let workrootIsMissing: Bool
        if lstat(canonicalWorkroot.path, &workrootInfo) == 0 {
            guard workrootInfo.st_mode & S_IFMT == S_IFDIR,
                workrootInfo.st_uid == getuid(),
                workrootInfo.st_mode & 0o077 == 0
            else {
                throw BabelDOCExecutorError.incompatibleRuntime(
                    "会话 workroot 权限不安全"
                )
            }
            workrootIsMissing = false
        } else {
            guard allowMissingWorkroot, errno == ENOENT else {
                throw BabelDOCExecutorError.incompatibleRuntime(
                    "会话 workroot 不可用"
                )
            }
            workrootIsMissing = true
        }
        return PersistedSessionRecord(
            session: persisted,
            workrootIsMissing: workrootIsMissing
        )
    }

    static func writePrivateAtomicFile(
        _ data: Data,
        to destination: URL
    ) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
            )
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporary)
            }
        }
        try data.write(to: temporary, options: .withoutOverwriting)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: destination.path]
            )
        }
        shouldRemoveTemporary = false
        let directoryDescriptor = open(
            destination.deletingLastPathComponent().path,
            O_RDONLY
        )
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            _ = close(directoryDescriptor)
        }
    }

    private static func verifyLayoutService(_ baseURL: URL) async throws {
        struct LayoutHealth: Decodable {
            let status: String
            let service: String
            let schemaVersion: Int

            enum CodingKeys: String, CodingKey {
                case status
                case service
                case schemaVersion = "schema_version"
            }
        }
        let url = baseURL.appendingPathComponent("healthz")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
            response.statusCode == 200,
            let health = try? JSONDecoder().decode(LayoutHealth.self, from: data),
            health.status == "ok",
            health.service == "gloss-babeldoc-layout",
            health.schemaVersion == 1
        else {
            throw BabelDOCExecutorError.incompatibleRuntime(
                "旧 DocLayout 服务身份验证失败"
            )
        }
    }

    private static func removePrivateWorkroot(_ url: URL) throws {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL
        let prefix =
            temporary.path.hasSuffix("/")
            ? temporary.path
            : temporary.path + "/"
        var info = stat()
        guard canonical.path.hasPrefix(prefix),
            canonical.lastPathComponent.hasPrefix(workingDirectoryPrefix),
            lstat(canonical.path, &info) == 0,
            info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == getuid(),
            info.st_mode & 0o077 == 0
        else {
            throw BabelDOCExecutorError.incompatibleRuntime(
                "拒绝清理不安全的旧 workroot"
            )
        }
        try FileManager.default.removeItem(at: canonical)
    }

    private static func waitForExit(
        _ process: Process,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }

    private static func waitForProcessExit(
        _ processIdentifier: Int32,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while processExists(processIdentifier) && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !processExists(processIdentifier)
    }

    static func terminateChildProcess(
        _ process: Process,
        allowGracefulExit: Bool
    ) async -> Bool {
        guard process.isRunning else { return true }
        if allowGracefulExit,
            await waitForExit(process, timeout: .seconds(3))
        {
            return true
        }
        process.terminate()
        if await waitForExit(process, timeout: .seconds(3)) {
            return true
        }
        guard
            kill(pid_t(process.processIdentifier), SIGKILL) == 0
                || errno == ESRCH
        else {
            return false
        }
        return await waitForExit(process, timeout: .seconds(3))
    }

    private static func terminateVerifiedProcess(
        _ processIdentifier: Int32,
        expectedStartTime: Double?,
        allowGracefulExit: Bool
    ) async -> Bool {
        guard processExists(processIdentifier) else { return true }
        if allowGracefulExit,
            await waitForVerifiedProcessExit(
                processIdentifier,
                expectedStartTime: expectedStartTime,
                timeout: .seconds(3)
            )
        {
            return true
        }
        guard
            verifiedProcessStillMatches(
                processIdentifier,
                expectedStartTime: expectedStartTime
            )
        else {
            return !processExists(processIdentifier)
                || processWasReplaced(
                    processIdentifier,
                    expectedStartTime: expectedStartTime
                )
        }
        guard kill(pid_t(processIdentifier), SIGTERM) == 0 || errno == ESRCH else {
            return false
        }
        if await waitForVerifiedProcessExit(
            processIdentifier,
            expectedStartTime: expectedStartTime,
            timeout: .seconds(3)
        ) {
            return true
        }
        guard
            verifiedProcessStillMatches(
                processIdentifier,
                expectedStartTime: expectedStartTime
            )
        else {
            return !processExists(processIdentifier)
                || processWasReplaced(
                    processIdentifier,
                    expectedStartTime: expectedStartTime
                )
        }
        guard kill(pid_t(processIdentifier), SIGKILL) == 0 || errno == ESRCH else {
            return false
        }
        return await waitForVerifiedProcessExit(
            processIdentifier,
            expectedStartTime: expectedStartTime,
            timeout: .seconds(3)
        )
    }

    private static func waitForVerifiedProcessExit(
        _ processIdentifier: Int32,
        expectedStartTime: Double?,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while verifiedProcessStillMatches(
            processIdentifier,
            expectedStartTime: expectedStartTime
        ) && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !processExists(processIdentifier)
            || processWasReplaced(
                processIdentifier,
                expectedStartTime: expectedStartTime
            )
    }

    private static func verifiedProcessStillMatches(
        _ processIdentifier: Int32,
        expectedStartTime: Double?
    ) -> Bool {
        guard processExists(processIdentifier),
            let expectedStartTime,
            let actualStartTime = processStartTime(processIdentifier)
        else {
            return false
        }
        return abs(actualStartTime - expectedStartTime) < 0.01
    }

    private static func processWasReplaced(
        _ processIdentifier: Int32,
        expectedStartTime: Double?
    ) -> Bool {
        guard processExists(processIdentifier),
            let expectedStartTime,
            let actualStartTime = processStartTime(processIdentifier)
        else {
            return false
        }
        return abs(actualStartTime - expectedStartTime) >= 0.01
    }

    public static func cleanupStaleWorkingDirectories() {
        cleanupStaleWorkingDirectories(in: FileManager.default.temporaryDirectory)
    }

    static func cleanupStaleWorkingDirectories(
        in root: URL,
        now: Date = Date(),
        legacyGraceInterval: TimeInterval = legacyCleanupGraceInterval
    ) {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        guard
            let candidates = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else { return }

        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.hasPrefix(workingDirectoryPrefix) else { continue }
            let suffix = String(name.dropFirst(workingDirectoryPrefix.count))
            var fileInfo = stat()
            guard UUID(uuidString: suffix) != nil,
                lstat(candidate.path, &fileInfo) == 0,
                fileInfo.st_mode & S_IFMT == S_IFDIR,
                fileInfo.st_uid == getuid(),
                fileInfo.st_mode & 0o077 == 0,
                let values = try? candidate.resourceValues(forKeys: keys),
                values.isDirectory == true,
                values.isSymbolicLink != true
            else { continue }

            let ownerPIDURL = candidate.appendingPathComponent(ownerPIDFileName)
            var ownerPIDInfo = stat()
            if lstat(ownerPIDURL.path, &ownerPIDInfo) == 0,
                ownerPIDInfo.st_mode & S_IFMT == S_IFREG,
                ownerPIDInfo.st_uid == getuid(),
                ownerPIDInfo.st_mode & 0o077 == 0,
                (1...32).contains(ownerPIDInfo.st_size),
                let value = try? String(contentsOf: ownerPIDURL, encoding: .utf8),
                let ownerPID = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                ownerPID > 0
            {
                guard !processExists(ownerPID) else { continue }
            } else {
                guard let modificationDate = values.contentModificationDate,
                    now.timeIntervalSince(modificationDate) >= legacyGraceInterval
                else { continue }
            }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private static func processExists(_ processIdentifier: Int32) -> Bool {
        if kill(pid_t(processIdentifier), 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func processIsDefinitelyAbsent(
        _ processIdentifier: Int32
    ) -> Bool {
        guard processIdentifier > 0 else { return false }
        if kill(pid_t(processIdentifier), 0) == 0 {
            return false
        }
        return errno == ESRCH
    }

    static func processStartTime(_ processIdentifier: Int32) -> Double? {
        guard processIdentifier > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                &info,
                expectedSize
            ) == expectedSize
        else {
            return nil
        }
        return
            Double(info.pbi_start_tvsec)
            + Double(info.pbi_start_tvusec) / 1_000_000
    }

    static func processMatches(
        _ processIdentifier: Int32,
        expectedStartTime: Double?
    ) -> Bool {
        guard let expectedStartTime,
            let actualStartTime = processStartTime(processIdentifier)
        else {
            return false
        }
        return abs(actualStartTime - expectedStartTime) < 0.01
    }

    private static func tail(of output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(12)
            .joined(separator: "\n")
    }

    static let layoutServiceScript = #"""
        import argparse
        import base64
        import json
        import os
        import threading
        import time
        from http import HTTPStatus
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        import cv2
        import msgpack
        import numpy as np
        from babeldoc.docvision.doclayout import OnnxModel

        READY_PREFIX = "__GLOSS_BABELDOC_LAYOUT_READY__"
        MODEL = OnnxModel.from_pretrained()
        MODEL_LOCK = threading.Lock()

        def monitor_parent(expected_parent_pid):
            while True:
                if os.getppid() != expected_parent_pid:
                    os._exit(0)
                time.sleep(1)

        def result_payload(result):
            names = {
                str(key): str(value)
                for key, value in dict(result.names).items()
            }
            boxes = []
            for box in result.boxes:
                boxes.append({
                    "xyxy": [float(value) for value in box.xyxy],
                    "conf": float(box.conf),
                    "cls": int(box.cls),
                })
            return {"boxes": boxes, "names": names}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != "/healthz":
                    self.send_error(HTTPStatus.NOT_FOUND)
                    return
                body = json.dumps({
                    "status": "ok",
                    "service": "gloss-babeldoc-layout",
                    "schema_version": 1,
                }).encode("utf-8")
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                if self.path != "/inference":
                    self.send_error(HTTPStatus.NOT_FOUND)
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    raw = self.rfile.read(length)
                    is_json = self.headers.get("Content-Type", "").split(";", 1)[0] == "application/json"
                    request = json.loads(raw) if is_json else msgpack.unpackb(raw, raw=False)
                    encoded_images = (
                        [base64.b64decode(request["image"])]
                        if is_json and isinstance(request.get("image"), str)
                        else request.get("image", [])
                    )
                    images = []
                    for encoded in encoded_images:
                        image = cv2.imdecode(
                            np.frombuffer(encoded, dtype=np.uint8),
                            cv2.IMREAD_COLOR,
                        )
                        if image is None:
                            raise ValueError("invalid image")
                        images.append(image)
                    if not images:
                        raise ValueError("image is required")
                    with MODEL_LOCK:
                        results = MODEL.predict(
                            images,
                            imgsz=int(request.get("imgsz", 1024)),
                        )
                    if is_json:
                        if len(results) != 1:
                            raise ValueError("rpc_doclayout8 requires one image")
                        converted = result_payload(results[0])
                        boxes = []
                        for box in converted["boxes"]:
                            class_id = int(box["cls"])
                            boxes.append({
                                "class_id": class_id,
                                "label": converted["names"].get(str(class_id), str(class_id)),
                                "score": float(box["conf"]),
                                "box": [float(value) for value in box["xyxy"]],
                            })
                        body = json.dumps({
                            "schema_version": 1,
                            "boxes": boxes,
                        }).encode("utf-8")
                    else:
                        body = msgpack.packb(
                            [result_payload(result) for result in results],
                            use_bin_type=True,
                        )
                    self.send_response(HTTPStatus.OK)
                    self.send_header(
                        "Content-Type",
                        "application/json" if is_json else "application/msgpack",
                    )
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except Exception as error:
                    body = json.dumps({"error": str(error)}).encode("utf-8")
                    self.send_response(HTTPStatus.BAD_REQUEST)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            def log_message(self, _format, *_args):
                return

        def main():
            parser = argparse.ArgumentParser()
            parser.add_argument("--host", default="127.0.0.1")
            parser.add_argument("--port", type=int, default=0)
            parser.add_argument("--parent-pid", type=int, required=True)
            args = parser.parse_args()
            threading.Thread(
                target=monitor_parent,
                args=(args.parent_pid,),
                daemon=True,
            ).start()
            server = ThreadingHTTPServer((args.host, args.port), Handler)
            print(f"{READY_PREFIX}{server.server_address[1]}", flush=True)
            server.serve_forever()

        if __name__ == "__main__":
            main()
        """#
}
