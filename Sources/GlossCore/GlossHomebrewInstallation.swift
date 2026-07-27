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
    case timedOut(executablePath: String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let executablePath):
            "命令执行超时：\(executablePath)"
        }
    }
}

public struct GlossCommandRunner: Sendable {
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
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, newValue in newValue }
        }
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let outputTask = Task.detached(priority: .utility) {
            standardOutput.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached(priority: .utility) {
            standardError.fileHandleForReading.readDataToEndOfFile()
        }
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now.advanced(by: $0) }

        do {
            while process.isRunning {
                try Task.checkCancellation()
                if let deadline, clock.now >= deadline {
                    process.terminate()
                    try? await Task<Never, Never>.sleep(
                        for: .milliseconds(500)
                    )
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    standardOutput.fileHandleForReading.closeFile()
                    standardError.fileHandleForReading.closeFile()
                    outputTask.cancel()
                    errorTask.cancel()
                    throw GlossCommandRunnerError.timedOut(
                        executablePath: executableURL.path
                    )
                }
                try await Task<Never, Never>.sleep(for: .milliseconds(50))
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }

        return GlossCommandOutput(
            terminationStatus: process.terminationStatus,
            standardOutput: await outputTask.value,
            standardError: await errorTask.value
        )
    })
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
