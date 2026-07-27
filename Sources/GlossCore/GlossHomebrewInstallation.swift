import Darwin
import Foundation

public struct GlossCommandOutput: Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(
        terminationStatus: Int32,
        standardOutput: Data,
        standardError: Data = Data()
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum GlossCommandRunnerError: LocalizedError, Equatable, Sendable {
    case outputLimitExceeded(
        executablePath: String,
        maximumByteCount: Int
    )
    case timedOut(executablePath: String)

    public var errorDescription: String? {
        switch self {
        case .outputLimitExceeded(
            let executablePath,
            let maximumByteCount
        ):
            "命令输出超过限制（\(maximumByteCount) 字节）：\(executablePath)"
        case .timedOut(let executablePath):
            "命令执行超时：\(executablePath)"
        }
    }
}

public struct GlossCommandRunner: Sendable {
    public static let maximumCapturedOutputByteCount = 16 * 1024 * 1024

    public typealias Run =
        @Sendable (URL, [String], [String: String], Duration?) async throws
        -> GlossCommandOutput

    private let runImplementation: Run

    public init(
        run:
            @escaping @Sendable (URL, [String]) async throws
            -> GlossCommandOutput
    ) {
        runImplementation = { executableURL, arguments, _, _ in
            try await run(executableURL, arguments)
        }
    }

    public init(runWithTimeout: @escaping Run) {
        runImplementation = runWithTimeout
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> GlossCommandOutput {
        try await runImplementation(
            executableURL,
            arguments,
            environment,
            timeout
        )
    }

    public static let live = Self(runWithTimeout: {
        executableURL,
        arguments,
        environment,
        timeout in
        let state = GlossCommandProcessState()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try GlossSpawnedCommand.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environment,
                    timeout: timeout,
                    state: state
                )
            }.value
        } onCancel: {
            state.cancel()
        }
    })
}

private final class GlossCommandProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false

    func cancel() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
}

private enum GlossSpawnedCommand {
    private enum CompletionReason {
        case cancelled
        case failed(Int32)
        case leaderExited
        case outputLimitExceeded
        case timedOut

        var checksOutputLimit: Bool {
            if case .leaderExited = self {
                return true
            }
            return false
        }

        var requiresImmediateKill: Bool {
            switch self {
            case .failed, .outputLimitExceeded:
                return true
            case .cancelled, .leaderExited, .timedOut:
                return false
            }
        }
    }

    private enum LeaderState {
        case exited
        case failed(Int32)
        case running
    }

    private struct CaptureFiles {
        let directoryPath: String
        let standardOutputPath: String
        let standardErrorPath: String
        let standardOutputDescriptor: Int32
        let standardErrorDescriptor: Int32

        static func create() throws -> Self {
            var template = Array(
                (FileManager.default.temporaryDirectory.path
                    + "/gloss-command.XXXXXX").utf8CString
            )
            let directoryPath = try template.withUnsafeMutableBufferPointer {
                buffer in
                guard let path = mkdtemp(buffer.baseAddress) else {
                    throw posixError(errno)
                }
                return String(cString: path)
            }
            let standardOutputPath =
                directoryPath + "/standard-output"
            let standardErrorPath =
                directoryPath + "/standard-error"
            do {
                let standardOutputDescriptor = try openCaptureFile(
                    at: standardOutputPath
                )
                do {
                    let standardErrorDescriptor = try openCaptureFile(
                        at: standardErrorPath
                    )
                    return Self(
                        directoryPath: directoryPath,
                        standardOutputPath: standardOutputPath,
                        standardErrorPath: standardErrorPath,
                        standardOutputDescriptor: standardOutputDescriptor,
                        standardErrorDescriptor: standardErrorDescriptor
                    )
                } catch {
                    Darwin.close(standardOutputDescriptor)
                    unlink(standardOutputPath)
                    throw error
                }
            } catch {
                rmdir(directoryPath)
                throw error
            }
        }

        func cleanup() {
            Darwin.close(standardOutputDescriptor)
            Darwin.close(standardErrorDescriptor)
            unlink(standardOutputPath)
            unlink(standardErrorPath)
            rmdir(directoryPath)
        }

        private static func openCaptureFile(
            at path: String
        ) throws -> Int32 {
            let openedDescriptor = Darwin.open(
                path,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
            guard openedDescriptor >= 0 else {
                throw posixError(errno)
            }
            guard openedDescriptor <= STDERR_FILENO else {
                return openedDescriptor
            }

            let duplicatedDescriptor = fcntl(
                openedDescriptor,
                F_DUPFD_CLOEXEC,
                STDERR_FILENO + 1
            )
            let duplicationError = errno
            Darwin.close(openedDescriptor)
            guard duplicatedDescriptor >= 0 else {
                throw posixError(duplicationError)
            }
            return duplicatedDescriptor
        }

        private static func posixError(_ code: Int32) -> Error {
            NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: nil
            )
        }
    }

    private static let supervisionIntervalMicroseconds: UInt32 = 10_000
    private static let terminationGrace: Duration = .milliseconds(250)
    private static let forcedCompletionGrace: Duration = .milliseconds(500)

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration?,
        state: GlossCommandProcessState
    ) throws -> GlossCommandOutput {
        guard !state.isCancellationRequested else {
            throw CancellationError()
        }
        let captureFiles = try CaptureFiles.create()
        defer { captureFiles.cleanup() }
        guard !state.isCancellationRequested else {
            throw CancellationError()
        }
        let processIdentifier = try spawn(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardOutputDescriptor:
                captureFiles.standardOutputDescriptor,
            standardErrorDescriptor:
                captureFiles.standardErrorDescriptor
        )
        return try supervise(
            processIdentifier: processIdentifier,
            executableURL: executableURL,
            captureFiles: captureFiles,
            timeout: timeout,
            state: state
        )
    }

    private static func signalProcessGroup(
        _ identifier: pid_t,
        signal: Int32
    ) {
        guard identifier > 0 else {
            return
        }
        _ = Darwin.kill(-identifier, signal)
    }

    private static func supervise(
        processIdentifier: pid_t,
        executableURL: URL,
        captureFiles: CaptureFiles,
        timeout: Duration?,
        state: GlossCommandProcessState
    ) throws -> GlossCommandOutput {
        let clock = ContinuousClock()
        let timeoutDeadline = timeout.map { clock.now.advanced(by: $0) }
        var leaderExited = false
        var completionReason: CompletionReason?
        var terminationStartedAt: ContinuousClock.Instant?
        var forcedCompletionDeadline: ContinuousClock.Instant?
        var sentKill = false
        var exceededOutputLimit = false

        while true {
            let now = clock.now
            if completionReason == nil {
                if state.isCancellationRequested {
                    completionReason = .cancelled
                } else if let timeoutDeadline, now >= timeoutDeadline {
                    completionReason = .timedOut
                }
            }

            if captureSizeExceedsLimit(captureFiles) {
                exceededOutputLimit = true
                if completionReason == nil
                    || completionReason!.checksOutputLimit
                {
                    completionReason = .outputLimitExceeded
                }
            }

            if !leaderExited {
                switch observeLeader(processIdentifier) {
                case .exited:
                    leaderExited = true
                case .failed(let code):
                    guard code != ECHILD else {
                        // The child may already have been reaped, so its PID no
                        // longer anchors the process group. Never signal a
                        // potentially reused numeric PGID.
                        throw posixError(code)
                    }
                    completionReason = .failed(code)
                case .running:
                    break
                }
            }

            if leaderExited {
                let hasDescendants = processGroupHasDescendants(
                    processIdentifier
                )
                if completionReason == nil {
                    if !hasDescendants {
                        return try completeNormally(
                            processIdentifier: processIdentifier,
                            executableURL: executableURL,
                            captureFiles: captureFiles
                        )
                    }
                    completionReason = .leaderExited
                } else if !hasDescendants {
                    if case .leaderExited = completionReason! {
                        return try completeNormally(
                            processIdentifier: processIdentifier,
                            executableURL: executableURL,
                            captureFiles: captureFiles
                        )
                    }
                    _ = try reapLeader(processIdentifier)
                    try finish(
                        reason: completionReason!,
                        executableURL: executableURL
                    )
                }
            }

            if let completionReason, terminationStartedAt == nil {
                let requiresImmediateKill =
                    completionReason.requiresImmediateKill
                    || exceededOutputLimit
                terminationStartedAt = now
                forcedCompletionDeadline = now.advanced(
                    by: terminationGrace + forcedCompletionGrace
                )
                signalProcessGroup(
                    processIdentifier,
                    signal: requiresImmediateKill ? SIGKILL : SIGTERM
                )
                sentKill = requiresImmediateKill
            } else if exceededOutputLimit, !sentKill {
                signalProcessGroup(processIdentifier, signal: SIGKILL)
                sentKill = true
            }

            if let terminationStartedAt,
                !sentKill,
                now
                    >= terminationStartedAt.advanced(
                        by: terminationGrace
                    )
            {
                signalProcessGroup(processIdentifier, signal: SIGKILL)
                sentKill = true
            }

            if sentKill, let completionReason {
                if let forcedCompletionDeadline,
                    now >= forcedCompletionDeadline
                {
                    signalProcessGroup(processIdentifier, signal: SIGKILL)
                    if case .leaderExited = completionReason,
                        leaderExited
                    {
                        return try completeNormally(
                            processIdentifier: processIdentifier,
                            executableURL: executableURL,
                            captureFiles: captureFiles
                        )
                    }
                    if leaderExited {
                        do {
                            _ = try reapLeader(processIdentifier)
                        } catch {
                            reapEventually(processIdentifier)
                        }
                    } else {
                        reapEventually(processIdentifier)
                    }
                    try finish(
                        reason: completionReason,
                        executableURL: executableURL
                    )
                }
            }

            usleep(supervisionIntervalMicroseconds)
        }
    }

    private static func completeNormally(
        processIdentifier: pid_t,
        executableURL: URL,
        captureFiles: CaptureFiles
    ) throws -> GlossCommandOutput {
        guard !captureSizeExceedsLimit(captureFiles) else {
            _ = try reapLeader(processIdentifier)
            throw GlossCommandRunnerError.outputLimitExceeded(
                executablePath: executableURL.path,
                maximumByteCount:
                    GlossCommandRunner.maximumCapturedOutputByteCount
            )
        }
        let sizes = try captureSizes(captureFiles)
        let rawWaitStatus = try reapLeader(processIdentifier)
        return makeOutput(
            rawWaitStatus: rawWaitStatus,
            standardOutput: try readCapture(
                descriptor: captureFiles.standardOutputDescriptor,
                byteCount: sizes.standardOutput
            ),
            standardError: try readCapture(
                descriptor: captureFiles.standardErrorDescriptor,
                byteCount: sizes.standardError
            )
        )
    }

    private static func finish(
        reason: CompletionReason,
        executableURL: URL
    ) throws -> Never {
        switch reason {
        case .cancelled:
            throw CancellationError()
        case .failed(let code):
            throw posixError(code)
        case .leaderExited:
            preconditionFailure("Leader exit completes normally.")
        case .outputLimitExceeded:
            throw GlossCommandRunnerError.outputLimitExceeded(
                executablePath: executableURL.path,
                maximumByteCount:
                    GlossCommandRunner.maximumCapturedOutputByteCount
            )
        case .timedOut:
            throw GlossCommandRunnerError.timedOut(
                executablePath: executableURL.path
            )
        }
    }

    private static func observeLeader(
        _ processIdentifier: pid_t
    ) -> LeaderState {
        var information = siginfo_t()
        while true {
            let result = Darwin.waitid(
                P_PID,
                id_t(processIdentifier),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0 {
                return information.si_pid == processIdentifier
                    ? .exited : .running
            }
            if errno == EINTR {
                continue
            }
            return .failed(errno)
        }
    }

    private static func processGroupHasDescendants(
        _ processIdentifier: pid_t
    ) -> Bool {
        var managementInformation = [
            Int32(CTL_KERN),
            Int32(KERN_PROC),
            Int32(KERN_PROC_PGRP),
            processIdentifier,
        ]
        var byteCount: size_t = 0
        guard
            managementInformation.withUnsafeMutableBufferPointer({
                sysctl(
                    $0.baseAddress,
                    u_int($0.count),
                    nil,
                    &byteCount,
                    nil,
                    0
                )
            }) == 0
        else {
            return true
        }

        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](
            repeating: kinfo_proc(),
            count: max(1, byteCount / stride + 8)
        )
        byteCount = processes.count * stride
        let result = managementInformation.withUnsafeMutableBufferPointer {
            managementBuffer in
            processes.withUnsafeMutableBytes { processBuffer in
                sysctl(
                    managementBuffer.baseAddress,
                    u_int(managementBuffer.count),
                    processBuffer.baseAddress,
                    &byteCount,
                    nil,
                    0
                )
            }
        }
        guard result == 0 else {
            return true
        }

        let processCount = byteCount / stride
        var foundLeader = false
        for process in processes.prefix(processCount) {
            if process.kp_proc.p_pid == processIdentifier {
                foundLeader = true
            } else {
                return true
            }
        }
        return !foundLeader
    }

    private static func reapLeader(
        _ processIdentifier: pid_t
    ) throws -> Int32 {
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(
                processIdentifier,
                &status,
                0
            )
            if result == processIdentifier {
                return status
            }
            if errno == EINTR {
                continue
            }
            throw posixError(errno)
        }
    }

    private static func reapEventually(_ processIdentifier: pid_t) {
        Task.detached(priority: .utility) {
            var status: Int32 = 0
            while Darwin.waitpid(processIdentifier, &status, 0) == -1,
                errno == EINTR
            {}
        }
    }

    private static func captureSizeExceedsLimit(
        _ captureFiles: CaptureFiles
    ) -> Bool {
        guard let sizes = try? captureSizes(captureFiles) else {
            return true
        }
        let limit = GlossCommandRunner.maximumCapturedOutputByteCount
        return sizes.standardOutput > limit
            || sizes.standardError > limit
            || sizes.standardOutput > limit - sizes.standardError
    }

    private static func captureSizes(
        _ captureFiles: CaptureFiles
    ) throws -> (standardOutput: Int, standardError: Int) {
        var standardOutputStatus = stat()
        var standardErrorStatus = stat()
        guard
            fstat(
                captureFiles.standardOutputDescriptor,
                &standardOutputStatus
            ) == 0,
            fstat(
                captureFiles.standardErrorDescriptor,
                &standardErrorStatus
            ) == 0,
            standardOutputStatus.st_size >= 0,
            standardErrorStatus.st_size >= 0,
            standardOutputStatus.st_size <= off_t(Int.max),
            standardErrorStatus.st_size <= off_t(Int.max)
        else {
            throw posixError(errno == 0 ? EOVERFLOW : errno)
        }
        return (
            Int(standardOutputStatus.st_size),
            Int(standardErrorStatus.st_size)
        )
    }

    private static func readCapture(
        descriptor: Int32,
        byteCount: Int
    ) throws -> Data {
        var data = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
            }
            if count > 0 {
                offset += count
            } else if count == 0 {
                data.removeSubrange(offset..<data.count)
                return data
            } else if errno != EINTR {
                throw posixError(errno)
            }
        }
        return data
    }

    private static func makeOutput(
        rawWaitStatus: Int32,
        standardOutput: Data,
        standardError: Data
    ) -> GlossCommandOutput {
        let signal = rawWaitStatus & 0x7f
        let terminationStatus =
            signal == 0
            ? (rawWaitStatus >> 8) & 0xff
            : signal
        return GlossCommandOutput(
            terminationStatus: terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    private static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardOutputDescriptor: Int32,
        standardErrorDescriptor: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        try "/dev/null".withCString { path in
            try check(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    path,
                    O_RDONLY,
                    0
                )
            )
        }
        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardOutputDescriptor,
                STDOUT_FILENO
            )
        )
        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardErrorDescriptor,
                STDERR_FILENO
            )
        )
        for descriptor in [
            standardOutputDescriptor,
            standardErrorDescriptor,
        ] {
            try check(
                posix_spawn_file_actions_addclose(
                    &fileActions,
                    descriptor
                )
            )
        }

        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let flags =
            Int16(POSIX_SPAWN_SETPGROUP)
            | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        try check(posix_spawnattr_setflags(&attributes, flags))

        let executablePath = executableURL.path
        let argumentStrings = [executablePath] + arguments
        let mergedEnvironment = ProcessInfo.processInfo.environment
            .merging(environment) { _, newValue in newValue }
        let environmentStrings =
            mergedEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var argumentPointers = try makeCStringArray(argumentStrings)
        defer { freeCStringArray(&argumentPointers) }
        var environmentPointers = try makeCStringArray(
            environmentStrings
        )
        defer { freeCStringArray(&environmentPointers) }

        var processIdentifier: pid_t = 0
        let spawnResult = argumentPointers.withUnsafeMutableBufferPointer {
            argumentBuffer in
            environmentPointers.withUnsafeMutableBufferPointer {
                environmentBuffer in
                executablePath.withCString { path in
                    posix_spawn(
                        &processIdentifier,
                        path,
                        &fileActions,
                        &attributes,
                        argumentBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        try check(spawnResult)
        return processIdentifier
    }

    private static func makeCStringArray(
        _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = strdup(string) else {
                freeCStringArray(&result)
                throw posixError(ENOMEM)
            }
            result.append(pointer)
        }
        result.append(nil)
        return result
    }

    private static func freeCStringArray(
        _ pointers: inout [UnsafeMutablePointer<CChar>?]
    ) {
        for pointer in pointers {
            free(pointer)
        }
        pointers.removeAll(keepingCapacity: false)
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw posixError(result)
        }
    }

    private static func posixError(_ code: Int32) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: nil
        )
    }
}

public struct GlossHomebrewCaskRelease: Equatable, Sendable {
    public let version: String
    public let url: URL
    public let sha256: String

    public init(version: String, url: URL, sha256: String) {
        self.version = version
        self.url = url
        self.sha256 = sha256
    }
}

public struct GlossPathInspector: Sendable {
    public typealias IsExecutable = @Sendable (URL) -> Bool
    public typealias FileExists = @Sendable (URL) -> Bool
    public typealias PathsReferToSameItem = @Sendable (URL, URL) -> Bool

    private let isExecutableImplementation: IsExecutable
    private let fileExistsImplementation: FileExists
    private let pathsReferToSameItemImplementation: PathsReferToSameItem

    public init(
        isExecutable: @escaping IsExecutable,
        fileExists: @escaping FileExists,
        pathsReferToSameItem: @escaping PathsReferToSameItem
    ) {
        isExecutableImplementation = isExecutable
        fileExistsImplementation = fileExists
        pathsReferToSameItemImplementation = pathsReferToSameItem
    }

    public func isExecutable(_ url: URL) -> Bool {
        isExecutableImplementation(url)
    }

    public func fileExists(_ url: URL) -> Bool {
        fileExistsImplementation(url)
    }

    public func pathsReferToSameItem(_ first: URL, _ second: URL) -> Bool {
        pathsReferToSameItemImplementation(first, second)
    }

    public static let live = Self(
        isExecutable: { url in
            FileManager.default.isExecutableFile(atPath: url.path)
        },
        fileExists: { url in
            FileManager.default.fileExists(atPath: url.path)
        },
        pathsReferToSameItem: { first, second in
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: first.path),
                fileManager.fileExists(atPath: second.path)
            else {
                return false
            }
            return first.resolvingSymlinksInPath().standardizedFileURL
                == second.resolvingSymlinksInPath().standardizedFileURL
        }
    )
}

public struct GlossHomebrewInstallation: Equatable, Sendable {
    public let brewExecutableURL: URL
    public let caskToken: String
    public let installedVersion: String
    public let availableVersion: String
    public let managedAppURL: URL
    public let installedAppTargetURL: URL

    public init(
        brewExecutableURL: URL,
        caskToken: String,
        installedVersion: String,
        availableVersion: String,
        managedAppURL: URL,
        installedAppTargetURL: URL
    ) {
        self.brewExecutableURL = brewExecutableURL
        self.caskToken = caskToken
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.managedAppURL = managedAppURL
        self.installedAppTargetURL = installedAppTargetURL
    }
}

public enum GlossHomebrewDetectionError: LocalizedError, Equatable, Sendable {
    case malformedInfo
    case invalidCaskIdentity
    case invalidCaskVersion

    public var errorDescription: String? {
        switch self {
        case .malformedInfo:
            "Homebrew 返回了无法解析的 Gloss cask 信息。"
        case .invalidCaskIdentity:
            "Homebrew 返回的 cask 不是 sunchj/tap/gloss。"
        case .invalidCaskVersion:
            "Homebrew 返回了无效的 Gloss 版本。"
        }
    }
}

public struct GlossHomebrewInstallationDetector: Sendable {
    public static let caskToken = "sunchj/tap/gloss"
    public static let brewExecutableURLs = [
        URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
        URL(fileURLWithPath: "/usr/local/bin/brew"),
    ]
    public static let infoArguments = [
        "info",
        "--cask",
        "--json=v2",
        caskToken,
    ]

    private struct InfoResponse: Decodable {
        let casks: [Cask]
    }

    private struct Cask: Decodable {
        let token: String
        let fullToken: String
        let tap: String
        let version: String
        let installed: String?
        let url: URL?
        let sha256: String?
        let artifacts: [JSONValue]

        enum CodingKeys: String, CodingKey {
            case token
            case fullToken = "full_token"
            case tap
            case version
            case installed
            case url
            case sha256
            case artifacts
        }
    }

    public static func parseCaskRelease(
        _ data: Data
    ) throws -> GlossHomebrewCaskRelease {
        let cask = try decodeCask(from: data)
        try validateIdentity(cask)
        guard GlossSemanticVersion(cask.version) != nil else {
            throw GlossHomebrewDetectionError.invalidCaskVersion
        }
        guard let url = cask.url,
            url.scheme == "https",
            let sha256 = cask.sha256,
            sha256.range(
                of: "^[0-9a-fA-F]{64}$",
                options: .regularExpression
            ) != nil
        else {
            throw GlossHomebrewDetectionError.malformedInfo
        }
        return GlossHomebrewCaskRelease(
            version: cask.version,
            url: url,
            sha256: sha256.lowercased()
        )
    }

    private let commandRunner: GlossCommandRunner
    private let pathInspector: GlossPathInspector

    public init(
        commandRunner: GlossCommandRunner,
        pathInspector: GlossPathInspector = .live
    ) {
        self.commandRunner = commandRunner
        self.pathInspector = pathInspector
    }

    public func detect(
        currentBundleURL: URL
    ) async throws -> GlossHomebrewInstallation? {
        for brewURL in Self.brewExecutableURLs
        where pathInspector.isExecutable(brewURL) {
            if let installation = try await detect(
                brewExecutableURL: brewURL,
                currentBundleURL: currentBundleURL
            ) {
                return installation
            }
        }
        return nil
    }

    public func detect(
        brewExecutableURL: URL,
        currentBundleURL: URL
    ) async throws -> GlossHomebrewInstallation? {
        guard Self.brewExecutableURLs.contains(brewExecutableURL),
            pathInspector.isExecutable(brewExecutableURL)
        else {
            return nil
        }
        let output = try await commandRunner.run(
            executableURL: brewExecutableURL,
            arguments: Self.infoArguments
        )
        guard output.terminationStatus == 0 else {
            return nil
        }
        return try parseManagedInstallation(
            output.standardOutput,
            brewURL: brewExecutableURL,
            currentBundleURL: currentBundleURL
        )
    }

    private func parseManagedInstallation(
        _ data: Data,
        brewURL: URL,
        currentBundleURL: URL
    ) throws -> GlossHomebrewInstallation? {
        let cask = try Self.decodeCask(from: data)
        try Self.validateIdentity(cask)
        guard let installedVersion = cask.installed else {
            return nil
        }
        guard GlossSemanticVersion(installedVersion) != nil,
            GlossSemanticVersion(cask.version) != nil
        else {
            throw GlossHomebrewDetectionError.invalidCaskVersion
        }

        guard
            let targetPath = cask.artifacts.compactMap({ artifact -> String? in
                guard artifact["app"] != nil else {
                    return nil
                }
                return artifact["target"]?.stringValue
            }).first
        else {
            throw GlossHomebrewDetectionError.malformedInfo
        }
        let targetURL = URL(fileURLWithPath: targetPath)
        let prefixURL =
            brewURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managedAppURL =
            prefixURL
            .appendingPathComponent("Caskroom", isDirectory: true)
            .appendingPathComponent("gloss", isDirectory: true)
            .appendingPathComponent(installedVersion, isDirectory: true)
            .appendingPathComponent("Gloss.app", isDirectory: true)

        guard pathInspector.fileExists(managedAppURL),
            pathInspector.fileExists(targetURL),
            pathInspector.fileExists(currentBundleURL),
            pathInspector.pathsReferToSameItem(targetURL, currentBundleURL),
            pathInspector.pathsReferToSameItem(managedAppURL, currentBundleURL)
        else {
            return nil
        }

        return GlossHomebrewInstallation(
            brewExecutableURL: brewURL,
            caskToken: Self.caskToken,
            installedVersion: installedVersion,
            availableVersion: cask.version,
            managedAppURL: managedAppURL,
            installedAppTargetURL: targetURL
        )
    }

    private static func decodeCask(from data: Data) throws -> Cask {
        let response: InfoResponse
        do {
            response = try JSONDecoder().decode(InfoResponse.self, from: data)
        } catch {
            throw GlossHomebrewDetectionError.malformedInfo
        }

        guard response.casks.count == 1, let cask = response.casks.first
        else {
            throw GlossHomebrewDetectionError.malformedInfo
        }
        return cask
    }

    private static func validateIdentity(_ cask: Cask) throws {
        guard cask.token == "gloss",
            cask.fullToken == Self.caskToken,
            cask.tap == "sunchj/tap"
        else {
            throw GlossHomebrewDetectionError.invalidCaskIdentity
        }
    }
}
