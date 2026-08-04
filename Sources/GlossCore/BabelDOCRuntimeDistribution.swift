import CryptoKit
import Darwin
import Foundation

public enum BabelDOCRuntimeChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case beta
    case nightly

    // The downstream release workflow currently publishes only stable.
    // Keep the reserved cases decodable so future manifests remain source
    // compatible, but do not expose dead update controls in the app.
    public static let allCases: [Self] = [.stable]
}

public enum BabelDOCRuntimeArchiveFormat: String, Codable, Sendable {
    case raw
    case tarGzip = "tar.gz"
    case zip
}

public struct BabelDOCRuntimePlatform: Codable, Equatable, Hashable, Sendable {
    public let operatingSystem: String
    public let architecture: String

    public init(operatingSystem: String, architecture: String) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    public static var current: Self {
        #if os(macOS)
            let operatingSystem = "macos"
        #elseif os(Linux)
            let operatingSystem = "linux"
        #else
            let operatingSystem = "unsupported"
        #endif

        #if arch(arm64)
            let architecture = "arm64"
        #elseif arch(x86_64)
            let architecture = "x86_64"
        #else
            let architecture = "unsupported"
        #endif

        return Self(operatingSystem: operatingSystem, architecture: architecture)
    }
}

public struct BabelDOCRuntimeManifest: Codable, Equatable, Sendable {
    public struct Asset: Codable, Equatable, Sendable {
        public let operatingSystem: String
        public let architecture: String
        public let url: URL
        public let sha256: String
        public let size: Int64?
        public let archiveFormat: BabelDOCRuntimeArchiveFormat
        public let executablePath: String

        public init(
            operatingSystem: String,
            architecture: String,
            url: URL,
            sha256: String,
            size: Int64? = nil,
            archiveFormat: BabelDOCRuntimeArchiveFormat,
            executablePath: String = "gloss-babeldoc"
        ) {
            self.operatingSystem = operatingSystem
            self.architecture = architecture
            self.url = url
            self.sha256 = sha256
            self.size = size
            self.archiveFormat = archiveFormat
            self.executablePath = executablePath
        }

        public var platform: BabelDOCRuntimePlatform {
            BabelDOCRuntimePlatform(
                operatingSystem: operatingSystem,
                architecture: architecture
            )
        }
    }

    public let schemaVersion: Int
    public let channel: BabelDOCRuntimeChannel
    public let version: String
    public let releaseTag: String
    public let publishedAt: String
    public let minimumGlossVersion: String?
    public let releaseNotesURL: URL?
    public let assets: [Asset]

    public init(
        schemaVersion: Int = 1,
        channel: BabelDOCRuntimeChannel,
        version: String,
        releaseTag: String,
        publishedAt: String,
        minimumGlossVersion: String? = nil,
        releaseNotesURL: URL? = nil,
        assets: [Asset]
    ) {
        self.schemaVersion = schemaVersion
        self.channel = channel
        self.version = version
        self.releaseTag = releaseTag
        self.publishedAt = publishedAt
        self.minimumGlossVersion = minimumGlossVersion
        self.releaseNotesURL = releaseNotesURL
        self.assets = assets
    }

    public func asset(for platform: BabelDOCRuntimePlatform) -> Asset? {
        assets.first { $0.platform == platform }
    }
}

public struct BabelDOCRuntimeReleaseEndpoint: Equatable, Sendable {
    public let repositoryURL: URL
    public let manifestAssetName: String

    public init(
        repositoryURL: URL = URL(string: "https://github.com/SunChJ/BabelDOC")!,
        manifestAssetName: String = "gloss-runtime-manifest.json"
    ) {
        self.repositoryURL = repositoryURL
        self.manifestAssetName = manifestAssetName
    }

    public func manifestURL(for channel: BabelDOCRuntimeChannel) -> URL {
        if channel == .stable {
            return
                repositoryURL
                .appendingPathComponent("releases")
                .appendingPathComponent("latest")
                .appendingPathComponent("download")
                .appendingPathComponent(manifestAssetName)
        }
        return
            repositoryURL
            .appendingPathComponent("releases")
            .appendingPathComponent("download")
            .appendingPathComponent(channel.rawValue)
            .appendingPathComponent(manifestAssetName)
    }

    public func signatureURL(forManifestURL manifestURL: URL) -> URL {
        guard
            var components = URLComponents(
                url: manifestURL,
                resolvingAgainstBaseURL: false
            )
        else {
            return manifestURL.appendingPathExtension("sig")
        }
        components.path += ".sig"
        return components.url ?? manifestURL.appendingPathExtension("sig")
    }
}

public struct BabelDOCRuntimeTransport: Sendable {
    public typealias FetchData = @Sendable (URL) async throws -> Data
    public typealias Download = @Sendable (URL, URL) async throws -> Void

    private let fetchDataImplementation: FetchData
    private let downloadImplementation: Download

    public init(
        fetchData: @escaping FetchData,
        download: @escaping Download
    ) {
        fetchDataImplementation = fetchData
        downloadImplementation = download
    }

    public func fetchData(from url: URL) async throws -> Data {
        try await fetchDataImplementation(url)
    }

    public func download(from url: URL, to destination: URL) async throws {
        try await downloadImplementation(url, destination)
    }

    public static let live = ephemeral()

    public static func ephemeral(
        policy: BabelDOCRuntimeNetworkPolicy
    ) -> Self {
        ephemeral(
            metadataPolicy: policy,
            downloadPolicy: policy
        )
    }

    public static func ephemeral(
        metadataPolicy: BabelDOCRuntimeNetworkPolicy = .metadata,
        downloadPolicy: BabelDOCRuntimeNetworkPolicy = .runtimeArchive
    ) -> Self {
        let metadataSession = URLSession(
            configuration: sessionConfiguration(for: metadataPolicy)
        )
        let downloadSession = URLSession(
            configuration: sessionConfiguration(for: downloadPolicy)
        )

        return Self(
            fetchData: { url in
                let (data, response) = try await metadataSession.data(from: url)
                try validateHTTPResponse(response, for: url)
                return data
            },
            download: { url, destination in
                let (temporaryURL, response) = try await downloadSession.download(from: url)
                try validateHTTPResponse(response, for: url)

                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: temporaryURL, to: destination)
            }
        )
    }

    static func sessionConfiguration(
        for policy: BabelDOCRuntimeNetworkPolicy
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = policy.requestTimeout
        configuration.timeoutIntervalForResource = policy.resourceTimeout
        configuration.waitsForConnectivity = policy.waitsForConnectivity
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    private static func validateHTTPResponse(_ response: URLResponse, for url: URL) throws {
        guard let response = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            throw BabelDOCRuntimeDistributionError.httpFailure(
                url: url,
                statusCode: response.statusCode
            )
        }
    }
}

public struct BabelDOCRuntimeNetworkPolicy: Equatable, Sendable {
    public static let metadata = Self()
    public static let runtimeArchive = Self(
        requestTimeout: 60,
        resourceTimeout: 60 * 60
    )

    public let requestTimeout: TimeInterval
    public let resourceTimeout: TimeInterval
    public let waitsForConnectivity: Bool

    public init(
        requestTimeout: TimeInterval = 12,
        resourceTimeout: TimeInterval = 60,
        waitsForConnectivity: Bool = false
    ) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.waitsForConnectivity = waitsForConnectivity
    }
}

public enum BabelDOCRuntimeDistributionError: LocalizedError, Equatable, Sendable {
    case httpFailure(url: URL, statusCode: Int)
    case invalidManifest(String)
    case invalidManifestSigningKey
    case manifestSignatureInvalid
    case currentGlossVersionUnavailable(minimum: String)
    case minimumGlossVersionNotMet(current: String, minimum: String)
    case unsupportedPlatform(BabelDOCRuntimePlatform)
    case channelUnavailable(BabelDOCRuntimeChannel)
    case channelMismatch(expected: BabelDOCRuntimeChannel, actual: BabelDOCRuntimeChannel)
    case pinnedVersionMismatch(expected: String, actual: String)
    case payloadSizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case invalidArchiveEntry(String)
    case archiveContainsLink(String)
    case archiveExtractionFailed(String)
    case executableMissing(String)
    case executableIsLink(String)
    case executablePermissionFailed(String)
    case noUpdateAvailable
    case rollbackUnavailable
    case corruptInstallationState

    public var errorDescription: String? {
        switch self {
        case .httpFailure(let url, let statusCode):
            "下载 \(url.absoluteString) 失败（HTTP \(statusCode)）。"
        case .invalidManifest(let reason):
            "BabelDOC runtime manifest 无效：\(reason)"
        case .invalidManifestSigningKey:
            "Gloss 内置的 BabelDOC manifest 签名公钥无效。"
        case .manifestSignatureInvalid:
            "BabelDOC runtime manifest 的 Ed25519 签名无效。"
        case .currentGlossVersionUnavailable(let minimum):
            "无法确认 Gloss 版本，不能安装要求 Gloss \(minimum) 或更高版本的 runtime。"
        case .minimumGlossVersionNotMet(let current, let minimum):
            "BabelDOC runtime 要求 Gloss \(minimum) 或更高版本，当前是 \(current)。"
        case .unsupportedPlatform(let platform):
            "当前平台没有可用的 BabelDOC runtime：\(platform.operatingSystem)/\(platform.architecture)"
        case .channelUnavailable(let channel):
            "BabelDOC runtime 更新通道尚未发布：\(channel.rawValue)。"
        case .channelMismatch(let expected, let actual):
            "Runtime 更新通道不匹配：需要 \(expected.rawValue)，收到 \(actual.rawValue)。"
        case .pinnedVersionMismatch(let expected, let actual):
            "Runtime 已固定为 \(expected)，manifest 提供的是 \(actual)。"
        case .payloadSizeMismatch(let expected, let actual):
            "BabelDOC runtime 文件大小不匹配：需要 \(expected) bytes，实际 \(actual) bytes。"
        case .checksumMismatch(let expected, let actual):
            "BabelDOC runtime SHA-256 校验失败：需要 \(expected)，实际 \(actual)。"
        case .invalidArchiveEntry(let entry):
            "BabelDOC runtime 压缩包包含不安全路径：\(entry)"
        case .archiveContainsLink(let entry):
            "BabelDOC runtime 压缩包包含不允许的链接：\(entry)"
        case .archiveExtractionFailed(let message):
            "无法解压 BabelDOC runtime：\(message)"
        case .executableMissing(let path):
            "BabelDOC runtime 中没有 gloss-babeldoc：\(path)"
        case .executableIsLink(let path):
            "BabelDOC runtime 的可执行文件不能是符号链接：\(path)"
        case .executablePermissionFailed(let path):
            "无法验证 BabelDOC runtime 的执行权限：\(path)"
        case .noUpdateAvailable:
            "当前没有可安装的 BabelDOC runtime 更新。"
        case .rollbackUnavailable:
            "没有可回滚的 BabelDOC runtime 版本。"
        case .corruptInstallationState:
            "BabelDOC runtime 安装状态已损坏。"
        }
    }
}

public enum BabelDOCRuntimeOperation: String, Codable, Sendable {
    case idle
    case checking
    case downloading
    case verifying
    case extracting
    case installing
    case rollingBack
    case removing
    case ready
    case failed
}

public struct BabelDOCRuntimeProgress: Equatable, Sendable {
    public let operation: BabelDOCRuntimeOperation
    public let version: String?
    public let detail: String?

    public init(
        operation: BabelDOCRuntimeOperation,
        version: String? = nil,
        detail: String? = nil
    ) {
        self.operation = operation
        self.version = version
        self.detail = detail
    }
}

public struct BabelDOCRuntimeSnapshot: Equatable, Sendable {
    public let channel: BabelDOCRuntimeChannel
    public let pinnedVersion: String?
    public let currentVersion: String?
    public let previousVersion: String?
    public let availableVersion: String?
    public let currentExecutableURL: URL?
    public let updateAvailable: Bool
    public let operation: BabelDOCRuntimeOperation
    public let lastError: String?

    public init(
        channel: BabelDOCRuntimeChannel,
        pinnedVersion: String?,
        currentVersion: String?,
        previousVersion: String?,
        availableVersion: String?,
        currentExecutableURL: URL?,
        updateAvailable: Bool,
        operation: BabelDOCRuntimeOperation,
        lastError: String?
    ) {
        self.channel = channel
        self.pinnedVersion = pinnedVersion
        self.currentVersion = currentVersion
        self.previousVersion = previousVersion
        self.availableVersion = availableVersion
        self.currentExecutableURL = currentExecutableURL
        self.updateAvailable = updateAvailable
        self.operation = operation
        self.lastError = lastError
    }
}

public actor BabelDOCRuntimeManager {
    public typealias ProgressHandler = @Sendable (BabelDOCRuntimeProgress) -> Void

    private struct Installation: Codable, Equatable, Sendable {
        let version: String
        let directoryName: String
        let executablePath: String
        let sha256: String
    }

    private struct PersistedState: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var channel: BabelDOCRuntimeChannel
        var pinnedVersion: String?
        var current: Installation?
        var previous: Installation?
    }

    public static let defaultDirectoryURL =
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Gloss", isDirectory: true)
        .appendingPathComponent("BabelDOCRuntime", isDirectory: true)

    public static let pinnedManifestSigningPublicKey = Data(
        base64Encoded: "0lgbX+CkmBjf4BnH9JO66I7Krd1DYM8lTOjIt+7zWEE="
    )!

    public static var detectedGlossVersion: String? {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
    }

    private let rootDirectory: URL
    private let versionsDirectory: URL
    private let stateURL: URL
    private let endpoint: BabelDOCRuntimeReleaseEndpoint
    private let transport: BabelDOCRuntimeTransport
    private let platform: BabelDOCRuntimePlatform
    private let fileManager: FileManager
    private let manifestSigningPublicKey: Curve25519.Signing.PublicKey
    private let currentGlossVersion: String?

    private var persistedState: PersistedState
    private var availableManifest: BabelDOCRuntimeManifest?
    private var operation: BabelDOCRuntimeOperation = .idle
    private var lastError: String?
    private var observers: [UUID: AsyncStream<BabelDOCRuntimeSnapshot>.Continuation] = [:]

    public init(
        rootDirectory: URL = BabelDOCRuntimeManager.defaultDirectoryURL,
        endpoint: BabelDOCRuntimeReleaseEndpoint = BabelDOCRuntimeReleaseEndpoint(),
        channel: BabelDOCRuntimeChannel = .stable,
        platform: BabelDOCRuntimePlatform = .current,
        transport: BabelDOCRuntimeTransport = .live,
        manifestSigningPublicKey: Data = BabelDOCRuntimeManager.pinnedManifestSigningPublicKey,
        currentGlossVersion: String? = BabelDOCRuntimeManager.detectedGlossVersion,
        fileManager: FileManager = .default
    ) throws {
        self.rootDirectory = rootDirectory
        versionsDirectory = rootDirectory.appendingPathComponent("versions", isDirectory: true)
        stateURL = rootDirectory.appendingPathComponent("state.json")
        self.endpoint = endpoint
        self.transport = transport
        self.platform = platform
        self.fileManager = fileManager
        self.currentGlossVersion = currentGlossVersion
        do {
            self.manifestSigningPublicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: manifestSigningPublicKey
            )
        } catch {
            throw BabelDOCRuntimeDistributionError.invalidManifestSigningKey
        }

        try Self.prepareDirectory(rootDirectory, fileManager: fileManager)
        try Self.prepareDirectory(versionsDirectory, fileManager: fileManager)
        let loadedState = try Self.loadState(
            from: stateURL,
            defaultChannel: channel,
            fileManager: fileManager
        )
        let restoredState = try Self.validate(
            loadedState,
            versionsDirectory: versionsDirectory,
            fileManager: fileManager
        )
        persistedState = restoredState
    }

    public func snapshot() -> BabelDOCRuntimeSnapshot {
        makeSnapshot()
    }

    public var currentVersion: String? {
        persistedState.current?.version
    }

    public var currentExecutableURL: URL? {
        persistedState.current.map(executableURL(for:))
    }

    public var availableVersion: String? {
        availableManifest?.version
    }

    public var updateAvailable: Bool {
        makeSnapshot().updateAvailable
    }

    public func reclaimableBytes() -> Int64 {
        Self.directorySize(at: rootDirectory, fileManager: fileManager)
    }

    public func snapshots() -> AsyncStream<BabelDOCRuntimeSnapshot> {
        let identifier = UUID()
        return AsyncStream { continuation in
            observers[identifier] = continuation
            continuation.yield(makeSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeObserver(identifier)
                }
            }
        }
    }

    @discardableResult
    public func setChannel(_ channel: BabelDOCRuntimeChannel) throws -> BabelDOCRuntimeSnapshot {
        guard BabelDOCRuntimeChannel.allCases.contains(channel) else {
            throw BabelDOCRuntimeDistributionError.channelUnavailable(channel)
        }
        let previousState = persistedState
        persistedState.channel = channel
        persistedState.pinnedVersion = nil
        availableManifest = nil
        lastError = nil
        do {
            try persist()
        } catch {
            persistedState = previousState
            throw error
        }
        return publishSnapshot()
    }

    @discardableResult
    public func pin(version: String?) throws -> BabelDOCRuntimeSnapshot {
        if let version {
            try Self.validateVersion(version)
        }
        let previousState = persistedState
        persistedState.pinnedVersion = version
        availableManifest = nil
        lastError = nil
        do {
            try persist()
        } catch {
            persistedState = previousState
            throw error
        }
        return publishSnapshot()
    }

    @discardableResult
    public func checkForUpdates(
        manifestURL: URL? = nil,
        signatureURL: URL? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> BabelDOCRuntimeSnapshot {
        let url = manifestURL ?? endpoint.manifestURL(for: persistedState.channel)
        let detachedSignatureURL =
            signatureURL ?? endpoint.signatureURL(forManifestURL: url)
        emit(.init(operation: .checking, detail: url.absoluteString), progress: progress)

        do {
            async let manifestDownload = transport.fetchData(from: url)
            async let signatureDownload = transport.fetchData(from: detachedSignatureURL)
            let (data, encodedSignature) = try await (
                manifestDownload,
                signatureDownload
            )
            let signature = try Self.decodeSignature(encodedSignature)
            guard manifestSigningPublicKey.isValidSignature(signature, for: data) else {
                throw BabelDOCRuntimeDistributionError.manifestSignatureInvalid
            }
            let manifest = try JSONDecoder().decode(BabelDOCRuntimeManifest.self, from: data)
            try validate(manifest)
            guard manifest.asset(for: platform) != nil else {
                throw BabelDOCRuntimeDistributionError.unsupportedPlatform(platform)
            }
            availableManifest = manifest
            operation = .ready
            lastError = nil
            return publishSnapshot()
        } catch {
            record(error, progress: progress)
            throw error
        }
    }

    @discardableResult
    public func update(
        manifestURL: URL? = nil,
        signatureURL: URL? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> BabelDOCRuntimeSnapshot {
        _ = try await checkForUpdates(
            manifestURL: manifestURL,
            signatureURL: signatureURL,
            progress: progress
        )
        return try await installAvailableUpdate(progress: progress)
    }

    /// Installs the manifest most recently accepted by `checkForUpdates`.
    ///
    /// The cached manifest has already passed the detached-signature and policy
    /// checks. Keeping this operation separate lets launch-time callers wait for
    /// their in-flight check and install that exact result without fetching
    /// mutable "latest" metadata a second time.
    @discardableResult
    public func installAvailableUpdate(
        progress: ProgressHandler? = nil
    ) async throws -> BabelDOCRuntimeSnapshot {
        guard makeSnapshot().updateAvailable, let manifest = availableManifest else {
            throw BabelDOCRuntimeDistributionError.noUpdateAvailable
        }
        return try await install(manifest, progress: progress)
    }

    @discardableResult
    public func install(
        _ manifest: BabelDOCRuntimeManifest,
        progress: ProgressHandler? = nil
    ) async throws -> BabelDOCRuntimeSnapshot {
        let stateBeforeInstall = persistedState
        let manifestBeforeInstall = availableManifest
        do {
            try validate(manifest)
            guard let asset = manifest.asset(for: platform) else {
                throw BabelDOCRuntimeDistributionError.unsupportedPlatform(platform)
            }
            try Self.validate(asset)

            let stagingDirectory = rootDirectory.appendingPathComponent(
                ".staging-\(UUID().uuidString)",
                isDirectory: true
            )
            try Self.prepareDirectory(stagingDirectory, fileManager: fileManager)
            defer {
                try? fileManager.removeItem(at: stagingDirectory)
            }

            let archiveURL = stagingDirectory.appendingPathComponent("payload")
            emit(
                .init(
                    operation: .downloading,
                    version: manifest.version,
                    detail: asset.url.absoluteString
                ),
                progress: progress
            )
            try await transport.download(from: asset.url, to: archiveURL)

            emit(
                .init(operation: .verifying, version: manifest.version),
                progress: progress
            )
            if let expectedSize = asset.size {
                let attributes = try fileManager.attributesOfItem(
                    atPath: archiveURL.path
                )
                let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard actualSize == expectedSize else {
                    throw BabelDOCRuntimeDistributionError.payloadSizeMismatch(
                        expected: expectedSize,
                        actual: actualSize
                    )
                }
            }
            let actualSHA256 = try Self.sha256(of: archiveURL)
            guard Self.normalizedSHA256(actualSHA256) == Self.normalizedSHA256(asset.sha256) else {
                throw BabelDOCRuntimeDistributionError.checksumMismatch(
                    expected: asset.sha256,
                    actual: actualSHA256
                )
            }

            let contentDirectory = stagingDirectory.appendingPathComponent(
                "content",
                isDirectory: true
            )
            try Self.prepareDirectory(contentDirectory, fileManager: fileManager)
            emit(
                .init(operation: .extracting, version: manifest.version),
                progress: progress
            )
            try await extract(
                archiveURL,
                format: asset.archiveFormat,
                executablePath: asset.executablePath,
                into: contentDirectory
            )

            let executableURL = contentDirectory.appendingPathComponent(asset.executablePath)
            try Self.validateExecutable(
                executableURL,
                inside: contentDirectory,
                fileManager: fileManager
            )

            emit(
                .init(operation: .installing, version: manifest.version),
                progress: progress
            )
            let directoryName = Self.installationDirectoryName(
                version: manifest.version,
                sha256: actualSHA256
            )
            let installedDirectory = versionsDirectory.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: installedDirectory.path) {
                try Self.validateExecutable(
                    installedDirectory.appendingPathComponent(asset.executablePath),
                    inside: installedDirectory,
                    fileManager: fileManager
                )
            } else {
                try fileManager.moveItem(at: contentDirectory, to: installedDirectory)
            }

            let installation = Installation(
                version: manifest.version,
                directoryName: directoryName,
                executablePath: asset.executablePath,
                sha256: actualSHA256
            )
            if persistedState.current != installation {
                persistedState.previous = persistedState.current
                persistedState.current = installation
            }
            availableManifest = manifest
            operation = .ready
            lastError = nil
            try persist()
            removeUnreferencedInstallations()
            emit(.init(operation: .ready, version: manifest.version), progress: progress)
            return publishSnapshot()
        } catch {
            persistedState = stateBeforeInstall
            availableManifest = manifestBeforeInstall
            record(error, progress: progress)
            throw error
        }
    }

    @discardableResult
    public func rollback(
        progress: ProgressHandler? = nil
    ) throws -> BabelDOCRuntimeSnapshot {
        guard let previous = persistedState.previous else {
            throw BabelDOCRuntimeDistributionError.rollbackUnavailable
        }
        let previousExecutable = executableURL(for: previous)
        try Self.validateExecutable(
            previousExecutable,
            inside: versionsDirectory.appendingPathComponent(
                previous.directoryName,
                isDirectory: true
            ),
            repairPermissions: false,
            fileManager: fileManager
        )

        emit(.init(operation: .rollingBack, version: previous.version), progress: progress)
        let previousState = persistedState
        let current = persistedState.current
        persistedState.current = previous
        persistedState.previous = current
        availableManifest = nil
        operation = .ready
        lastError = nil
        do {
            try persist()
        } catch {
            persistedState = previousState
            record(error, progress: progress)
            throw error
        }
        emit(.init(operation: .ready, version: previous.version), progress: progress)
        return publishSnapshot()
    }

    @discardableResult
    public func uninstall(
        progress: ProgressHandler? = nil
    ) throws -> BabelDOCRuntimeSnapshot {
        let stateBeforeRemoval = persistedState
        let manifestBeforeRemoval = availableManifest
        let quarantineDirectory = rootDirectory.appendingPathComponent(
            ".removing-\(UUID().uuidString)",
            isDirectory: true
        )
        var movedItems: [(source: URL, destination: URL)] = []
        var createdReplacementVersionsDirectory = false

        do {
            emit(.init(operation: .removing, version: persistedState.current?.version), progress: progress)
            try Self.prepareDirectory(quarantineDirectory, fileManager: fileManager)
            let contents = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            let preservedNames = Set([
                stateURL.lastPathComponent,
                quarantineDirectory.lastPathComponent,
            ])
            for source in contents {
                guard !preservedNames.contains(source.lastPathComponent) else { continue }
                let destination = quarantineDirectory.appendingPathComponent(
                    source.lastPathComponent,
                    isDirectory: source.hasDirectoryPath
                )
                try fileManager.moveItem(at: source, to: destination)
                movedItems.append((source, destination))
            }
            try Self.prepareDirectory(versionsDirectory, fileManager: fileManager)
            createdReplacementVersionsDirectory = true

            persistedState.current = nil
            persistedState.previous = nil
            availableManifest = nil
            lastError = nil
            operation = .idle
            try persist()

            // State is already committed as uninstalled. Cleanup is best-effort:
            // a quarantined remainder is inert and will be included in the next
            // reclaimable-size calculation instead of risking a half-restored
            // executable after a partial filesystem deletion.
            try? fileManager.removeItem(at: quarantineDirectory)
            emit(.init(operation: .idle), progress: progress)
            return publishSnapshot()
        } catch {
            if createdReplacementVersionsDirectory {
                try? fileManager.removeItem(at: versionsDirectory)
            }
            for item in movedItems.reversed()
            where fileManager.fileExists(atPath: item.destination.path) {
                try? fileManager.moveItem(at: item.destination, to: item.source)
            }
            try? fileManager.removeItem(at: quarantineDirectory)
            persistedState = stateBeforeRemoval
            availableManifest = manifestBeforeRemoval
            try? persist()
            record(error, progress: progress)
            throw error
        }
    }

    private func validate(_ manifest: BabelDOCRuntimeManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw BabelDOCRuntimeDistributionError.invalidManifest(
                "不支持 schemaVersion \(manifest.schemaVersion)"
            )
        }
        try Self.validateVersion(manifest.version)
        guard !manifest.releaseTag.isEmpty else {
            throw BabelDOCRuntimeDistributionError.invalidManifest("releaseTag 不能为空")
        }
        guard ISO8601DateFormatter().date(from: manifest.publishedAt) != nil else {
            throw BabelDOCRuntimeDistributionError.invalidManifest(
                "publishedAt 必须是 ISO-8601 时间"
            )
        }
        guard manifest.channel == persistedState.channel else {
            throw BabelDOCRuntimeDistributionError.channelMismatch(
                expected: persistedState.channel,
                actual: manifest.channel
            )
        }
        if let pinnedVersion = persistedState.pinnedVersion,
            pinnedVersion != manifest.version
        {
            throw BabelDOCRuntimeDistributionError.pinnedVersionMismatch(
                expected: pinnedVersion,
                actual: manifest.version
            )
        }
        guard !manifest.assets.isEmpty else {
            throw BabelDOCRuntimeDistributionError.invalidManifest("assets 不能为空")
        }
        if let releaseNotesURL = manifest.releaseNotesURL,
            releaseNotesURL.scheme?.lowercased() != "https"
        {
            throw BabelDOCRuntimeDistributionError.invalidManifest(
                "releaseNotesURL 必须使用 HTTPS"
            )
        }
        if let minimumGlossVersion = manifest.minimumGlossVersion {
            try Self.validateVersion(minimumGlossVersion)
            guard let currentGlossVersion else {
                throw BabelDOCRuntimeDistributionError.currentGlossVersionUnavailable(
                    minimum: minimumGlossVersion
                )
            }
            try Self.validateVersion(currentGlossVersion)
            if Self.naturalCompare(
                currentGlossVersion,
                minimumGlossVersion
            ) == .orderedAscending {
                throw BabelDOCRuntimeDistributionError.minimumGlossVersionNotMet(
                    current: currentGlossVersion,
                    minimum: minimumGlossVersion
                )
            }
        }
    }

    private static func validate(_ asset: BabelDOCRuntimeManifest.Asset) throws {
        guard asset.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw BabelDOCRuntimeDistributionError.invalidManifest("asset.sha256 必须是 64 位十六进制")
        }
        guard asset.url.scheme == "https" || asset.url.isFileURL else {
            throw BabelDOCRuntimeDistributionError.invalidManifest("asset URL 必须使用 HTTPS")
        }
        try validateRelativePath(asset.executablePath)
        guard URL(fileURLWithPath: asset.executablePath).lastPathComponent == "gloss-babeldoc" else {
            throw BabelDOCRuntimeDistributionError.invalidManifest(
                "asset executablePath 必须指向 gloss-babeldoc"
            )
        }
        if let size = asset.size, size <= 0 {
            throw BabelDOCRuntimeDistributionError.invalidManifest("asset.size 必须大于 0")
        }
    }

    private func extract(
        _ archiveURL: URL,
        format: BabelDOCRuntimeArchiveFormat,
        executablePath: String,
        into destination: URL
    ) async throws {
        switch format {
        case .raw:
            let executableURL = destination.appendingPathComponent(executablePath)
            try fileManager.createDirectory(
                at: executableURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(at: archiveURL, to: executableURL)
        case .tarGzip:
            let entries = try await Self.run(
                executable: "/usr/bin/tar",
                arguments: ["-tzf", archiveURL.path]
            )
            try Self.validateArchiveEntries(entries)
            let listing = try await Self.run(
                executable: "/usr/bin/tar",
                arguments: ["-tvzf", archiveURL.path]
            )
            try Self.rejectTarLinks(listing)
            _ = try await Self.run(
                executable: "/usr/bin/tar",
                arguments: [
                    "-xzf", archiveURL.path,
                    "-C", destination.path,
                    "--no-same-owner",
                    "--no-same-permissions",
                ]
            )
        case .zip:
            let entries = try await Self.run(
                executable: "/usr/bin/unzip",
                arguments: ["-Z1", archiveURL.path]
            )
            try Self.validateArchiveEntries(entries)
            let listing = try await Self.run(
                executable: "/usr/bin/zipinfo",
                arguments: ["-l", archiveURL.path]
            )
            try Self.rejectZipLinks(listing)
            _ = try await Self.run(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", archiveURL.path, destination.path]
            )
        }
        try Self.rejectExtractedLinks(in: destination, fileManager: fileManager)
    }

    private func makeSnapshot() -> BabelDOCRuntimeSnapshot {
        let current = persistedState.current
        let availableVersion = availableManifest?.version
        return BabelDOCRuntimeSnapshot(
            channel: persistedState.channel,
            pinnedVersion: persistedState.pinnedVersion,
            currentVersion: current?.version,
            previousVersion: persistedState.previous?.version,
            availableVersion: availableVersion,
            currentExecutableURL: current.map(executableURL(for:)),
            updateAvailable: Self.isUpdateAvailable(
                currentVersion: current?.version,
                availableVersion: availableVersion,
                pinnedVersion: persistedState.pinnedVersion
            ),
            operation: operation,
            lastError: lastError
        )
    }

    private func executableURL(for installation: Installation) -> URL {
        versionsDirectory
            .appendingPathComponent(installation.directoryName, isDirectory: true)
            .appendingPathComponent(installation.executablePath)
    }

    private func emit(
        _ update: BabelDOCRuntimeProgress,
        progress: ProgressHandler?
    ) {
        operation = update.operation
        progress?(update)
        _ = publishSnapshot()
    }

    private func record(_ error: Error, progress: ProgressHandler?) {
        operation = .failed
        lastError = error.localizedDescription
        progress?(
            .init(
                operation: .failed,
                detail: error.localizedDescription
            )
        )
        _ = publishSnapshot()
    }

    @discardableResult
    private func publishSnapshot() -> BabelDOCRuntimeSnapshot {
        let value = makeSnapshot()
        for continuation in observers.values {
            continuation.yield(value)
        }
        return value
    }

    private func removeObserver(_ identifier: UUID) {
        observers.removeValue(forKey: identifier)
    }

    private func persist() throws {
        let data = try JSONEncoder.pretty.encode(persistedState)
        try Self.writeStateAtomically(data, to: stateURL)
    }

    static func writeStateAtomically(
        _ data: Data,
        to stateURL: URL,
        afterSecuringTemporaryFile: ((URL) throws -> Void)? = nil
    ) throws {
        let temporaryURL = stateURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(stateURL.lastPathComponent).\(UUID().uuidString).tmp"
            )
        let descriptor = temporaryURL.path.withCString {
            open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw posixError(errno, path: temporaryURL.path)
        }

        var descriptorIsOpen = true
        var temporaryFileExists = true
        defer {
            if descriptorIsOpen {
                close(descriptor)
            }
            if temporaryFileExists {
                temporaryURL.path.withCString { _ = unlink($0) }
            }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw posixError(errno, path: temporaryURL.path)
        }
        var descriptorStatus = stat()
        guard
            fstat(descriptor, &descriptorStatus) == 0,
            descriptorStatus.st_mode & S_IFMT == S_IFREG,
            descriptorStatus.st_uid == getuid(),
            descriptorStatus.st_mode & 0o777 == 0o600
        else {
            throw BabelDOCRuntimeDistributionError.corruptInstallationState
        }
        try afterSecuringTemporaryFile?(temporaryURL)

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else {
                    throw posixError(EIO, path: temporaryURL.path)
                }
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw posixError(errno, path: temporaryURL.path)
                }
                guard written > 0 else {
                    throw posixError(EIO, path: temporaryURL.path)
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw posixError(errno, path: temporaryURL.path)
        }

        let closeResult = close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else {
            throw posixError(errno, path: temporaryURL.path)
        }
        guard
            let status = try fileStatus(at: temporaryURL),
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == getuid(),
            status.st_mode & 0o777 == 0o600
        else {
            throw BabelDOCRuntimeDistributionError.corruptInstallationState
        }

        let renameResult = temporaryURL.path.withCString { sourcePath in
            stateURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw posixError(errno, path: stateURL.path)
        }
        temporaryFileExists = false
    }

    private func removeUnreferencedInstallations() {
        let retained = Set(
            [persistedState.current?.directoryName, persistedState.previous?.directoryName]
                .compactMap { $0 }
        )
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: versionsDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            return
        }
        for url in contents where !retained.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func directorySize(
        at root: URL,
        fileManager: FileManager
    ) -> Int64 {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [],
                errorHandler: { _, _ in true }
            )
        else { return 0 }

        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            guard
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                ), values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func prepareDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        if let status = try fileStatus(at: url),
            status.st_mode & S_IFMT != S_IFDIR
                || status.st_uid != getuid()
        {
            throw BabelDOCRuntimeDistributionError.corruptInstallationState
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard
            let status = try fileStatus(at: url),
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == getuid()
        else {
            throw BabelDOCRuntimeDistributionError.corruptInstallationState
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private static func loadState(
        from url: URL,
        defaultChannel: BabelDOCRuntimeChannel,
        fileManager: FileManager
    ) throws -> PersistedState {
        guard let status = try fileStatus(at: url) else {
            return PersistedState(channel: defaultChannel)
        }
        do {
            guard
                status.st_mode & S_IFMT == S_IFREG,
                status.st_uid == getuid(),
                status.st_mode & 0o777 == 0o600
            else {
                throw BabelDOCRuntimeDistributionError.corruptInstallationState
            }
            let state = try JSONDecoder().decode(
                PersistedState.self,
                from: Data(contentsOf: url)
            )
            guard state.schemaVersion == 1 else {
                throw BabelDOCRuntimeDistributionError.corruptInstallationState
            }
            return state
        } catch let error as BabelDOCRuntimeDistributionError {
            throw error
        } catch {
            throw BabelDOCRuntimeDistributionError.corruptInstallationState
        }
    }

    private static func validate(
        _ state: PersistedState,
        versionsDirectory: URL,
        fileManager: FileManager
    ) throws -> PersistedState {
        do {
            guard BabelDOCRuntimeChannel.allCases.contains(state.channel) else {
                throw BabelDOCRuntimeDistributionError.channelUnavailable(
                    state.channel
                )
            }
            if let pinnedVersion = state.pinnedVersion {
                try validateVersion(pinnedVersion)
            }

            if let current = state.current {
                do {
                    try validate(
                        current,
                        versionsDirectory: versionsDirectory,
                        fileManager: fileManager
                    )
                } catch {
                    guard let previous = state.previous else {
                        throw BabelDOCRuntimeDistributionError.corruptInstallationState
                    }
                    try validate(
                        previous,
                        versionsDirectory: versionsDirectory,
                        fileManager: fileManager
                    )
                    var recoveredState = state
                    recoveredState.current = nil
                    return recoveredState
                }
            }
            if let previous = state.previous {
                try validate(
                    previous,
                    versionsDirectory: versionsDirectory,
                    fileManager: fileManager
                )
            }
            return state
        } catch {
            throw BabelDOCRuntimeDistributionError.corruptInstallationState
        }
    }

    private static func validate(
        _ installation: Installation,
        versionsDirectory: URL,
        fileManager: FileManager
    ) throws {
        try validateVersion(installation.version)
        guard
            installation.sha256
                .range(
                    of: "^[0-9a-f]{64}$",
                    options: .regularExpression
                ) != nil,
            installation.directoryName
                == installationDirectoryName(
                    version: installation.version,
                    sha256: installation.sha256
                ),
            installation.directoryName
                == URL(fileURLWithPath: installation.directoryName)
                .lastPathComponent
        else {
            throw BabelDOCRuntimeDistributionError.corruptInstallationState
        }
        try validateRelativePath(installation.executablePath)
        guard
            URL(fileURLWithPath: installation.executablePath)
                .lastPathComponent == "gloss-babeldoc"
        else {
            throw BabelDOCRuntimeDistributionError.corruptInstallationState
        }

        let installationDirectory = versionsDirectory.appendingPathComponent(
            installation.directoryName,
            isDirectory: true
        )
        guard
            let status = try fileStatus(at: installationDirectory),
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == getuid()
        else {
            throw BabelDOCRuntimeDistributionError.corruptInstallationState
        }
        try rejectSymlinkComponents(
            relativePath: installation.executablePath,
            inside: installationDirectory
        )
        try validateExecutable(
            installationDirectory.appendingPathComponent(
                installation.executablePath
            ),
            inside: installationDirectory,
            repairPermissions: false,
            fileManager: fileManager
        )
    }

    private static func posixError(_ code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    private static func fileStatus(at url: URL) throws -> stat? {
        var status = stat()
        let result = url.path.withCString { path in
            lstat(path, &status)
        }
        if result == 0 {
            return status
        }
        if errno == ENOENT {
            return nil
        }
        throw BabelDOCRuntimeDistributionError.corruptInstallationState
    }

    private static func rejectSymlinkComponents(
        relativePath: String,
        inside root: URL
    ) throws {
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component))
            guard let status = try fileStatus(at: current) else {
                throw BabelDOCRuntimeDistributionError.corruptInstallationState
            }
            if status.st_mode & S_IFMT == S_IFLNK {
                throw BabelDOCRuntimeDistributionError.corruptInstallationState
            }
        }
    }

    private static func validateVersion(_ version: String) throws {
        guard !version.isEmpty,
            version.range(of: "^[0-9A-Za-z][0-9A-Za-z.+_-]{0,127}$", options: .regularExpression) != nil
        else {
            throw BabelDOCRuntimeDistributionError.invalidManifest(
                "version 包含不允许的字符"
            )
        }
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.contains("\0") else {
            throw BabelDOCRuntimeDistributionError.invalidArchiveEntry(path)
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"),
            !normalized.hasPrefix("~"),
            normalized.range(of: "^[A-Za-z]:") == nil
        else {
            throw BabelDOCRuntimeDistributionError.invalidArchiveEntry(path)
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw BabelDOCRuntimeDistributionError.invalidArchiveEntry(path)
        }
    }

    static func validateArchiveEntries(_ listing: String) throws {
        for entry in listing.split(whereSeparator: \.isNewline) {
            let value = String(entry)
            var normalized = value.hasSuffix("/") ? String(value.dropLast()) : value
            while normalized.hasPrefix("./") {
                normalized.removeFirst(2)
            }
            if normalized == "." {
                continue
            }
            guard !normalized.isEmpty else {
                continue
            }
            try validateRelativePath(normalized)
        }
    }

    private static func rejectTarLinks(_ listing: String) throws {
        for line in listing.split(whereSeparator: \.isNewline) {
            guard let type = line.first else {
                continue
            }
            if type == "l" || type == "h" {
                throw BabelDOCRuntimeDistributionError.archiveContainsLink(String(line))
            }
        }
    }

    static func rejectZipLinks(_ listing: String) throws {
        for line in listing.split(whereSeparator: \.isNewline) {
            let value = line.drop(while: \.isWhitespace)
            guard value.count >= 10 else {
                continue
            }
            let permissions = value.prefix(10)
            guard
                permissions.dropFirst().allSatisfy({
                    $0 == "r" || $0 == "w" || $0 == "x" || $0 == "-"
                        || $0 == "s" || $0 == "S" || $0 == "t" || $0 == "T"
                })
            else {
                continue
            }
            guard permissions.first == "-" || permissions.first == "d" else {
                throw BabelDOCRuntimeDistributionError.archiveContainsLink(
                    String(line)
                )
            }
        }
    }

    private static func rejectExtractedLinks(
        in root: URL,
        fileManager: FileManager
    ) throws {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            )
        else {
            return
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw BabelDOCRuntimeDistributionError.archiveContainsLink(url.path)
            }
        }
    }

    private static func validateExecutable(
        _ executableURL: URL,
        inside root: URL,
        repairPermissions: Bool = true,
        fileManager: FileManager
    ) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let executablePath = executableURL.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard executablePath.hasPrefix(prefix) else {
            throw BabelDOCRuntimeDistributionError.executableIsLink(executableURL.path)
        }

        guard let status = try fileStatus(at: executableURL) else {
            throw BabelDOCRuntimeDistributionError.executableMissing(executableURL.path)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw BabelDOCRuntimeDistributionError.executableIsLink(executableURL.path)
        }
        guard status.st_uid == getuid() else {
            throw BabelDOCRuntimeDistributionError.executablePermissionFailed(
                executableURL.path
            )
        }

        if repairPermissions {
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )
        }
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw BabelDOCRuntimeDistributionError.executablePermissionFailed(
                executableURL.path
            )
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer {
            try? file.close()
        }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedSHA256(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func decodeSignature(_ data: Data) throws -> Data {
        if data.count == 64 {
            return data
        }
        guard
            let encoded = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let decoded = Data(base64Encoded: encoded),
            decoded.count == 64
        else {
            throw BabelDOCRuntimeDistributionError.manifestSignatureInvalid
        }
        return decoded
    }

    private static func installationDirectoryName(
        version: String,
        sha256: String
    ) -> String {
        "\(version)-\(sha256.prefix(12))"
    }

    private static func isUpdateAvailable(
        currentVersion: String?,
        availableVersion: String?,
        pinnedVersion: String?
    ) -> Bool {
        guard let availableVersion else {
            return false
        }
        if let pinnedVersion {
            return availableVersion == pinnedVersion && currentVersion != pinnedVersion
        }
        guard let currentVersion else {
            return true
        }
        return naturalCompare(availableVersion, currentVersion) == .orderedDescending
    }

    private static func naturalCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(
            rhs,
            options: [.numeric, .caseInsensitive],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func run(
        executable: String,
        arguments: [String]
    ) async throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Drain both pipes while the child is running. Waiting first can
        // deadlock once a large archive listing fills either pipe buffer.
        let stdoutTask = Task.detached {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            stderr.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()

        let output = await stdoutTask.value
        let error = await stderrTask.value
        guard process.terminationStatus == 0 else {
            let detail = String(data: error, encoding: .utf8) ?? "status \(process.terminationStatus)"
            throw BabelDOCRuntimeDistributionError.archiveExtractionFailed(
                detail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard let text = String(data: output, encoding: .utf8) else {
            throw BabelDOCRuntimeDistributionError.archiveExtractionFailed(
                "archive listing is not valid UTF-8"
            )
        }
        return text
    }
}

extension JSONEncoder {
    fileprivate static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
