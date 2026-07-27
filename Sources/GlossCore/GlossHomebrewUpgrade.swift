import CryptoKit
import Darwin
import Foundation

public struct GlossHomebrewUpgradeRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let brewExecutablePath: String
    public let caskToken: String
    public let previousVersion: String
    public let expectedVersion: String
    public let expectedReleaseTag: String
    public let expectedArchitecture: String
    public let expectedAssetURL: URL
    public let expectedAssetSHA256: String
    public let expectedAssetSize: Int64
    public let expectedHomebrewCaskURL: URL
    public let expectedHomebrewCaskSHA256: String
    public let expectedHomebrewCaskSize: Int64
    public let parentProcessIdentifier: Int32
    public let currentBundlePath: String
    public let resultPath: String
    public let readinessPath: String
    public let manifestPath: String
    public let manifestSignaturePath: String
    public let recoveryBundlePath: String
    public let requestIdentifier: UUID

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        brewExecutablePath: String,
        caskToken: String,
        previousVersion: String,
        expectedVersion: String,
        expectedReleaseTag: String,
        expectedArchitecture: String,
        expectedAssetURL: URL,
        expectedAssetSHA256: String,
        expectedAssetSize: Int64,
        expectedHomebrewCaskURL: URL,
        expectedHomebrewCaskSHA256: String,
        expectedHomebrewCaskSize: Int64,
        parentProcessIdentifier: Int32,
        currentBundlePath: String,
        resultPath: String,
        readinessPath: String,
        manifestPath: String,
        manifestSignaturePath: String,
        recoveryBundlePath: String,
        requestIdentifier: UUID = UUID()
    ) {
        self.schemaVersion = schemaVersion
        self.brewExecutablePath = brewExecutablePath
        self.caskToken = caskToken
        self.previousVersion = previousVersion
        self.expectedVersion = expectedVersion
        self.expectedReleaseTag = expectedReleaseTag
        self.expectedArchitecture = expectedArchitecture
        self.expectedAssetURL = expectedAssetURL
        self.expectedAssetSHA256 = expectedAssetSHA256
        self.expectedAssetSize = expectedAssetSize
        self.expectedHomebrewCaskURL = expectedHomebrewCaskURL
        self.expectedHomebrewCaskSHA256 = expectedHomebrewCaskSHA256
        self.expectedHomebrewCaskSize = expectedHomebrewCaskSize
        self.parentProcessIdentifier = parentProcessIdentifier
        self.currentBundlePath = currentBundlePath
        self.resultPath = resultPath
        self.readinessPath = readinessPath
        self.manifestPath = manifestPath
        self.manifestSignaturePath = manifestSignaturePath
        self.recoveryBundlePath = recoveryBundlePath
        self.requestIdentifier = requestIdentifier
    }

    public init(
        installation: GlossHomebrewInstallation,
        update: GlossAppUpdateAvailability,
        parentProcessIdentifier: Int32,
        currentBundleURL: URL,
        resultURL: URL,
        readinessURL: URL,
        manifestURL: URL,
        manifestSignatureURL: URL,
        recoveryBundleURL: URL,
        requestIdentifier: UUID = UUID()
    ) {
        self.init(
            brewExecutablePath: installation.brewExecutableURL.path,
            caskToken: installation.caskToken,
            previousVersion: installation.installedVersion,
            expectedVersion: update.version,
            expectedReleaseTag: update.releaseTag,
            expectedArchitecture: update.architecture,
            expectedAssetURL: update.assetURL,
            expectedAssetSHA256: update.assetSHA256,
            expectedAssetSize: update.assetSize,
            expectedHomebrewCaskURL: update.homebrewCask.url,
            expectedHomebrewCaskSHA256: update.homebrewCask.sha256,
            expectedHomebrewCaskSize: update.homebrewCask.size,
            parentProcessIdentifier: parentProcessIdentifier,
            currentBundlePath: currentBundleURL.path,
            resultPath: resultURL.path,
            readinessPath: readinessURL.path,
            manifestPath: manifestURL.path,
            manifestSignaturePath: manifestSignatureURL.path,
            recoveryBundlePath: recoveryBundleURL.path,
            requestIdentifier: requestIdentifier
        )
    }

    public var brewExecutableURL: URL {
        URL(fileURLWithPath: brewExecutablePath)
    }

    public var currentBundleURL: URL {
        URL(fileURLWithPath: currentBundlePath, isDirectory: true)
    }

    public var resultURL: URL {
        URL(fileURLWithPath: resultPath)
    }

    public var readinessURL: URL {
        URL(fileURLWithPath: readinessPath)
    }

    public var manifestURL: URL {
        URL(fileURLWithPath: manifestPath)
    }

    public var manifestSignatureURL: URL {
        URL(fileURLWithPath: manifestSignaturePath)
    }

    public var recoveryBundleURL: URL {
        URL(fileURLWithPath: recoveryBundlePath, isDirectory: true)
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "unsupported schema version"
            )
        }
        guard
            GlossHomebrewInstallationDetector.brewExecutableURLs.map(\.path)
                .contains(brewExecutablePath)
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "brew executable is not trusted"
            )
        }
        guard caskToken == GlossHomebrewInstallationDetector.caskToken else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "cask token is not trusted"
            )
        }
        guard let parsedPreviousVersion = GlossSemanticVersion(previousVersion)
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "previous version is invalid"
            )
        }
        guard let parsedExpectedVersion = GlossSemanticVersion(expectedVersion)
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "expected version is invalid"
            )
        }
        guard parsedPreviousVersion < parsedExpectedVersion else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "expected version must be newer than the installed version"
            )
        }
        guard expectedReleaseTag == "v\(expectedVersion)" else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "release tag does not match expected version"
            )
        }
        guard expectedArchitecture == GlossAppArchitecture.current else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "asset architecture does not match this Mac"
            )
        }
        guard expectedAssetSize > 0,
            expectedAssetSHA256.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "signed app asset metadata is invalid"
            )
        }
        guard expectedHomebrewCaskSize > 0,
            expectedHomebrewCaskSHA256.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "signed Homebrew cask metadata is invalid"
            )
        }
        do {
            try GlossAppReleaseManifestValidator.validateOfficialAssetURL(
                expectedAssetURL,
                architecture: expectedArchitecture,
                releaseTag: expectedReleaseTag
            )
            try GlossAppReleaseManifestValidator
                .validateOfficialHomebrewCaskURL(
                    expectedHomebrewCaskURL,
                    releaseTag: expectedReleaseTag
                )
        } catch {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "signed release URLs are invalid"
            )
        }
        guard parentProcessIdentifier > 1 else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "parent process identifier is invalid"
            )
        }
        guard currentBundlePath == "/Applications/Gloss.app",
            currentBundleURL.standardizedFileURL.path == currentBundlePath,
            currentBundleURL.lastPathComponent == "Gloss.app"
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "current bundle path is invalid"
            )
        }
        guard resultPath.hasPrefix("/"),
            resultURL.standardizedFileURL.path == resultPath,
            resultURL.pathExtension == "json"
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "result path is invalid"
            )
        }
        guard readinessPath.hasPrefix("/"),
            readinessURL.standardizedFileURL.path == readinessPath,
            readinessURL.pathExtension == "json",
            readinessURL != resultURL
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "readiness path is invalid"
            )
        }
        guard manifestPath.hasPrefix("/"),
            manifestURL.standardizedFileURL.path == manifestPath,
            manifestURL.lastPathComponent == "release-manifest.json",
            manifestSignaturePath.hasPrefix("/"),
            manifestSignatureURL.standardizedFileURL.path
                == manifestSignaturePath,
            manifestSignatureURL.lastPathComponent
                == "release-manifest.json.sig",
            manifestURL.deletingLastPathComponent()
                == readinessURL.deletingLastPathComponent(),
            manifestSignatureURL.deletingLastPathComponent()
                == readinessURL.deletingLastPathComponent()
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "signed manifest paths are invalid"
            )
        }
        let expectedRecoveryURL =
            readinessURL.deletingLastPathComponent()
            .appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent("Gloss.app", isDirectory: true)
        guard recoveryBundlePath.hasPrefix("/"),
            recoveryBundleURL.standardizedFileURL.path == recoveryBundlePath,
            recoveryBundleURL == expectedRecoveryURL
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "recovery bundle path is invalid"
            )
        }
    }
}

public struct GlossHomebrewUpgradeResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
    }

    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let outcome: Outcome
    public let expectedVersion: String
    public let installedVersion: String?
    public let errorCode: String?
    public let message: String?
    public let recoveredPreviousInstallation: Bool
    public let recoveryError: String?
    public let completedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        outcome: Outcome,
        expectedVersion: String,
        installedVersion: String? = nil,
        errorCode: String? = nil,
        message: String? = nil,
        recoveredPreviousInstallation: Bool = false,
        recoveryError: String? = nil,
        completedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.outcome = outcome
        self.expectedVersion = expectedVersion
        self.installedVersion = installedVersion
        self.errorCode = errorCode
        self.message = message
        self.recoveredPreviousInstallation = recoveredPreviousInstallation
        self.recoveryError = recoveryError
        self.completedAt = completedAt
    }

    public var succeeded: Bool {
        outcome == .succeeded
    }
}

public enum GlossUpdateHelperArguments {
    public static let requestFileFlag = "--request"

    public static func requestFileURL(
        from arguments: [String]
    ) throws -> URL {
        guard arguments.count == 2,
            arguments[0] == requestFileFlag,
            arguments[1].hasPrefix("/")
        else {
            throw GlossHomebrewUpgradeError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1])
    }
}

public enum GlossHomebrewUpgradeError: LocalizedError, Equatable, Sendable {
    case invalidArguments
    case invalidRequest(String)
    case helperReadinessTimedOut
    case helperExitedBeforeReady
    case parentProcessDidNotExit
    case recoveryPreparationFailed(String)
    case recoveryFailed(String)
    case releaseBindingFailed(String)
    case homebrewUpdateFailed(status: Int32, detail: String)
    case homebrewUpgradeFailed(status: Int32, detail: String)
    case installationVerificationFailed(String)
    case relaunchFailed(status: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "更新 helper 参数无效。"
        case .invalidRequest(let reason):
            "更新请求无效：\(reason)"
        case .helperReadinessTimedOut:
            "更新 helper 未在限定时间内完成启动验证。"
        case .helperExitedBeforeReady:
            "更新 helper 在完成启动验证前退出。"
        case .parentProcessDidNotExit:
            "Gloss 未在限定时间内退出。"
        case .recoveryPreparationFailed(let reason):
            "无法准备 Gloss 恢复副本：\(reason)"
        case .recoveryFailed(let reason):
            "Gloss 更新失败，且恢复上一版本失败：\(reason)"
        case .releaseBindingFailed(let reason):
            "Homebrew Cask 未通过签名发行绑定验证：\(reason)"
        case .homebrewUpdateFailed(let status, let detail):
            "Homebrew 更新失败（\(status)）：\(detail)"
        case .homebrewUpgradeFailed(let status, let detail):
            "Gloss 的 Homebrew 升级失败（\(status)）：\(detail)"
        case .installationVerificationFailed(let reason):
            "升级后的 Gloss 未通过验证：\(reason)"
        case .relaunchFailed(let status, let detail):
            "Gloss 升级完成，但重新打开失败（\(status)）：\(detail)"
        }
    }

    public var resultCode: String {
        switch self {
        case .invalidArguments:
            "invalid_arguments"
        case .invalidRequest:
            "invalid_request"
        case .helperReadinessTimedOut:
            "helper_readiness_timeout"
        case .helperExitedBeforeReady:
            "helper_exited_before_ready"
        case .parentProcessDidNotExit:
            "parent_exit_timeout"
        case .recoveryPreparationFailed:
            "recovery_preparation_failed"
        case .recoveryFailed:
            "recovery_failed"
        case .releaseBindingFailed:
            "release_binding_failed"
        case .homebrewUpdateFailed:
            "homebrew_update_failed"
        case .homebrewUpgradeFailed:
            "homebrew_upgrade_failed"
        case .installationVerificationFailed:
            "installation_verification_failed"
        case .relaunchFailed:
            "relaunch_failed"
        }
    }
}

public struct GlossUpdateHelperReadiness: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let requestIdentifier: UUID
    public let helperProcessIdentifier: Int32

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        requestIdentifier: UUID,
        helperProcessIdentifier: Int32
    ) {
        self.schemaVersion = schemaVersion
        self.requestIdentifier = requestIdentifier
        self.helperProcessIdentifier = helperProcessIdentifier
    }
}

public enum GlossUpdateHelperReadinessStore {
    public static func load(from url: URL) throws -> GlossUpdateHelperReadiness {
        try JSONDecoder().decode(
            GlossUpdateHelperReadiness.self,
            from: Data(contentsOf: url)
        )
    }

    public static func write(
        _ readiness: GlossUpdateHelperReadiness,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(readiness)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

public struct GlossSignedAppUpdateRequestVerifier: Sendable {
    private let validator: GlossAppReleaseManifestValidator

    public init(
        manifestSigningPublicKey: Data =
            GlossAppReleaseManifestValidator.pinnedManifestSigningPublicKey
    ) throws {
        validator = try GlossAppReleaseManifestValidator(
            manifestSigningPublicKey: manifestSigningPublicKey
        )
    }

    public func verify(_ request: GlossHomebrewUpgradeRequest) throws {
        let manifest: GlossAppReleaseManifest
        do {
            manifest = try validator.validate(
                manifestData: Data(contentsOf: request.manifestURL),
                detachedSignatureData: Data(
                    contentsOf: request.manifestSignatureURL
                )
            )
        } catch {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "signed release manifest could not be reverified"
            )
        }
        guard manifest.version == request.expectedVersion,
            manifest.releaseTag == request.expectedReleaseTag,
            let asset = manifest.assets.first(where: {
                $0.operatingSystem == "macos"
                    && $0.architecture == request.expectedArchitecture
            }),
            asset.url == request.expectedAssetURL,
            asset.sha256 == request.expectedAssetSHA256,
            asset.size == request.expectedAssetSize,
            manifest.homebrewCask.token == request.caskToken,
            manifest.homebrewCask.url
                == request.expectedHomebrewCaskURL,
            manifest.homebrewCask.sha256
                == request.expectedHomebrewCaskSHA256,
            manifest.homebrewCask.size
                == request.expectedHomebrewCaskSize
        else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "update request does not match the signed release manifest"
            )
        }
    }
}

public enum GlossHomebrewUpgradeRequestStore {
    public static func load(from url: URL) throws -> GlossHomebrewUpgradeRequest {
        try JSONDecoder().decode(
            GlossHomebrewUpgradeRequest.self,
            from: Data(contentsOf: url)
        )
    }

    public static func write(
        _ request: GlossHomebrewUpgradeRequest,
        to url: URL
    ) throws {
        try writeJSON(request, to: url)
    }

    private static func writeJSON<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

public enum GlossHomebrewUpgradeResultStore {
    public static func load(from url: URL) throws -> GlossHomebrewUpgradeResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            GlossHomebrewUpgradeResult.self,
            from: Data(contentsOf: url)
        )
    }

    public static func write(
        _ result: GlossHomebrewUpgradeResult,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

public struct GlossParentProcessWaiter: Sendable {
    public typealias Wait = @Sendable (Int32, Duration) async throws -> Void

    private let waitImplementation: Wait

    public init(wait: @escaping Wait) {
        waitImplementation = wait
    }

    public func wait(
        for processIdentifier: Int32,
        timeout: Duration
    ) async throws {
        try await waitImplementation(processIdentifier, timeout)
    }

    public static let live = Self { processIdentifier, timeout in
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while Self.isRunning(processIdentifier) {
            guard clock.now < deadline else {
                throw GlossHomebrewUpgradeError.parentProcessDidNotExit
            }
            try await Task<Never, Never>.sleep(for: .milliseconds(250))
        }
    }

    private static func isRunning(_ processIdentifier: Int32) -> Bool {
        if kill(pid_t(processIdentifier), 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

public struct GlossHomebrewUpgradeVerifier: Sendable {
    public typealias Verify =
        @Sendable (
            GlossHomebrewUpgradeRequest
        ) async throws -> String

    private let verifyImplementation: Verify

    public init(verify: @escaping Verify) {
        verifyImplementation = verify
    }

    public func verify(
        _ request: GlossHomebrewUpgradeRequest
    ) async throws -> String {
        try await verifyImplementation(request)
    }

    public static func live(
        commandRunner: GlossCommandRunner = .live,
        pathInspector: GlossPathInspector = .live,
        bundleVersionReader: GlossBundleVersionReader = .live
    ) -> Self {
        Self { request in
            let detector = GlossHomebrewInstallationDetector(
                commandRunner: commandRunner,
                pathInspector: pathInspector
            )
            guard
                let installation = try await detector.detect(
                    brewExecutableURL: request.brewExecutableURL,
                    currentBundleURL: request.currentBundleURL
                )
            else {
                throw
                    GlossHomebrewUpgradeError
                    .installationVerificationFailed(
                        "Homebrew 不再管理当前 App"
                    )
            }
            guard installation.caskToken == request.caskToken,
                Self.installedVersion(
                    installation.installedVersion,
                    matchesExpectedVersion: request.expectedVersion
                )
            else {
                throw
                    GlossHomebrewUpgradeError
                    .installationVerificationFailed(
                        "Homebrew 安装版本与签名发行版本不一致"
                    )
            }

            let bundleVersion = try bundleVersionReader.version(
                at: request.currentBundleURL
            )
            guard bundleVersion == installation.installedVersion else {
                throw
                    GlossHomebrewUpgradeError
                    .installationVerificationFailed(
                        "App bundle 与 Homebrew 安装版本不一致"
                    )
            }

            let appExecutableURL =
                request.currentBundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("Gloss")
            let architecture = try await commandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/lipo"),
                arguments: [
                    appExecutableURL.path,
                    "-verify_arch",
                    Self.runningArchitecture,
                ]
            )
            guard architecture.terminationStatus == 0 else {
                throw
                    GlossHomebrewUpgradeError
                    .installationVerificationFailed(
                        "App 不包含当前 Mac 所需的架构"
                    )
            }

            let verification = try await commandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: [
                    "--verify",
                    "--deep",
                    "--strict",
                    request.currentBundlePath,
                ]
            )
            guard verification.terminationStatus == 0 else {
                throw
                    GlossHomebrewUpgradeError
                    .installationVerificationFailed(
                        "代码签名完整性检查失败"
                    )
            }

            let signatureDetails = try await commandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: [
                    "--display",
                    "--verbose=4",
                    request.currentBundlePath,
                ]
            )
            let signatureText = Self.commandText(signatureDetails)
            guard signatureDetails.terminationStatus == 0,
                signatureText.split(separator: "\n").contains(
                    where: { $0.trimmingCharacters(in: .whitespaces) == "Signature=adhoc" }
                )
            else {
                throw
                    GlossHomebrewUpgradeError
                    .installationVerificationFailed(
                        "App 不是预期的 ad-hoc 签名"
                    )
            }

            let quarantine = try await commandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xattr"),
                arguments: [
                    "-p",
                    "com.apple.quarantine",
                    request.currentBundlePath,
                ]
            )
            let quarantineText = Self.commandText(quarantine)
            guard quarantine.terminationStatus != 0,
                quarantineText.contains("No such xattr")
            else {
                throw
                    GlossHomebrewUpgradeError
                    .installationVerificationFailed(
                        quarantine.terminationStatus == 0
                            ? "App 仍带有 quarantine 属性"
                            : "无法确认 App 的 quarantine 状态"
                    )
            }
            return installation.installedVersion
        }
    }

    private static func commandText(_ output: GlossCommandOutput) -> String {
        String(
            decoding: output.standardOutput + output.standardError,
            as: UTF8.self
        )
    }

    static func installedVersion(
        _ installedVersion: String,
        matchesExpectedVersion expectedVersion: String
    ) -> Bool {
        guard let installed = GlossSemanticVersion(installedVersion),
            let expected = GlossSemanticVersion(expectedVersion)
        else {
            return false
        }
        return installed == expected
    }

    private static var runningArchitecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unsupported"
        #endif
    }
}

public struct GlossBundleVersionReader: Sendable {
    public typealias Read = @Sendable (URL) throws -> String

    private let readImplementation: Read

    public init(read: @escaping Read) {
        readImplementation = read
    }

    public func version(at bundleURL: URL) throws -> String {
        try readImplementation(bundleURL)
    }

    public static let live = Self { bundleURL in
        let infoURL =
            bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard
            let propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any],
            let version = propertyList["CFBundleShortVersionString"] as? String,
            GlossSemanticVersion(version) != nil
        else {
            throw GlossHomebrewUpgradeError.installationVerificationFailed(
                "无法读取 App 版本"
            )
        }
        return version
    }
}

public struct GlossRecoveryBundleValidator: Sendable {
    public typealias Validate =
        @Sendable (URL, Set<String>) async throws -> Void

    private let validateImplementation: Validate

    public init(validate: @escaping Validate) {
        validateImplementation = validate
    }

    public func validate(
        _ bundleURL: URL,
        allowedVersions: Set<String>
    ) async throws {
        try await validateImplementation(bundleURL, allowedVersions)
    }

    public static func live(
        commandRunner: GlossCommandRunner = .live,
        bundleVersionReader: GlossBundleVersionReader = .live
    ) -> Self {
        Self { bundleURL, allowedVersions in
            guard Self.isDirectoryWithoutSymlinks(bundleURL) else {
                throw GlossHomebrewUpgradeError.recoveryFailed(
                    "恢复 App 不是常规目录，或包含符号链接路径"
                )
            }
            let version = try bundleVersionReader.version(at: bundleURL)
            guard allowedVersions.contains(version) else {
                throw GlossHomebrewUpgradeError.recoveryFailed(
                    "恢复 App 版本不在允许范围内"
                )
            }
            let executableURL =
                bundleURL
                .appendingPathComponent("Contents/MacOS/Gloss")
            let architecture = try await commandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/lipo"),
                arguments: [
                    executableURL.path,
                    "-verify_arch",
                    GlossAppArchitecture.current,
                ],
                timeout: .seconds(60)
            )
            guard architecture.terminationStatus == 0 else {
                throw GlossHomebrewUpgradeError.recoveryFailed(
                    "恢复 App 不包含当前 Mac 架构"
                )
            }
            let signature = try await commandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: [
                    "--verify",
                    "--deep",
                    "--strict",
                    bundleURL.path,
                ],
                timeout: .seconds(60)
            )
            guard signature.terminationStatus == 0 else {
                throw GlossHomebrewUpgradeError.recoveryFailed(
                    "恢复 App 的代码签名无效"
                )
            }
            guard try !Self.hasQuarantineAttribute(bundleURL) else {
                throw GlossHomebrewUpgradeError.recoveryFailed(
                    "恢复 App 仍带有 quarantine 属性"
                )
            }
        }
    }

    private static func isDirectoryWithoutSymlinks(_ url: URL) -> Bool {
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL else {
            return false
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            return false
        }
        return metadata.st_mode & S_IFMT == S_IFDIR
    }

    private static func hasQuarantineAttribute(_ url: URL) throws -> Bool {
        let result = url.path.withCString { path in
            "com.apple.quarantine".withCString { name in
                getxattr(path, name, nil, 0, 0, 0)
            }
        }
        if result >= 0 {
            return true
        }
        if errno == ENOATTR {
            return false
        }
        throw GlossHomebrewUpgradeError.recoveryFailed(
            "无法确认恢复 App 的 quarantine 状态"
        )
    }
}

public struct GlossAppUpdateRecoveryManager: Sendable {
    public typealias Prepare =
        @Sendable (GlossHomebrewUpgradeRequest) async throws -> Void
    public typealias Restore =
        @Sendable (GlossHomebrewUpgradeRequest) async throws -> Bool

    private let prepareImplementation: Prepare
    private let restoreImplementation: Restore

    public init(
        prepare: @escaping Prepare,
        restoreIfNeeded: @escaping Restore
    ) {
        prepareImplementation = prepare
        restoreImplementation = restoreIfNeeded
    }

    public func prepare(_ request: GlossHomebrewUpgradeRequest) async throws {
        try await prepareImplementation(request)
    }

    public func restoreIfNeeded(
        _ request: GlossHomebrewUpgradeRequest
    ) async throws -> Bool {
        try await restoreImplementation(request)
    }

    public static func live(
        validator: GlossRecoveryBundleValidator = .live()
    ) -> Self {
        Self(
            prepare: { request in
                let fileManager = FileManager.default
                do {
                    try await validator.validate(
                        request.currentBundleURL,
                        allowedVersions: [request.previousVersion]
                    )
                    let recoveryRoot =
                        request.recoveryBundleURL.deletingLastPathComponent()
                    try fileManager.createDirectory(
                        at: recoveryRoot,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    if fileManager.fileExists(
                        atPath: request.recoveryBundlePath
                    ) {
                        try fileManager.removeItem(
                            at: request.recoveryBundleURL
                        )
                    }
                    try fileManager.copyItem(
                        at: request.currentBundleURL,
                        to: request.recoveryBundleURL
                    )
                    try await validator.validate(
                        request.recoveryBundleURL,
                        allowedVersions: [request.previousVersion]
                    )
                } catch {
                    throw
                        GlossHomebrewUpgradeError
                        .recoveryPreparationFailed(
                            error.localizedDescription
                        )
                }
            },
            restoreIfNeeded: { request in
                let fileManager = FileManager.default
                if fileManager.fileExists(
                    atPath: request.currentBundlePath
                ) {
                    do {
                        try await validator.validate(
                            request.currentBundleURL,
                            allowedVersions: [
                                request.previousVersion,
                                request.expectedVersion,
                            ]
                        )
                        return false
                    } catch {
                        // The installed target is partial or invalid; restore
                        // only from the already-validated private backup.
                    }
                }
                do {
                    try await validator.validate(
                        request.recoveryBundleURL,
                        allowedVersions: [request.previousVersion]
                    )
                    let replacementURL =
                        request.currentBundleURL.deletingLastPathComponent()
                        .appendingPathComponent(
                            ".Gloss-recovery-\(UUID().uuidString).app",
                            isDirectory: true
                        )
                    defer {
                        try? fileManager.removeItem(at: replacementURL)
                    }
                    try fileManager.copyItem(
                        at: request.recoveryBundleURL,
                        to: replacementURL
                    )
                    try await validator.validate(
                        replacementURL,
                        allowedVersions: [request.previousVersion]
                    )
                    if fileManager.fileExists(
                        atPath: request.currentBundlePath
                    ) {
                        try fileManager.removeItem(
                            at: request.currentBundleURL
                        )
                    }
                    try fileManager.moveItem(
                        at: replacementURL,
                        to: request.currentBundleURL
                    )
                    try await validator.validate(
                        request.currentBundleURL,
                        allowedVersions: [request.previousVersion]
                    )
                    return true
                } catch {
                    throw GlossHomebrewUpgradeError.recoveryFailed(
                        error.localizedDescription
                    )
                }
            }
        )
    }
}

public struct GlossHomebrewReleaseBindingVerifier: Sendable {
    public static let repositoryArguments = [
        "--repository",
        "sunchj/tap",
    ]

    public typealias Verify =
        @Sendable (GlossHomebrewUpgradeRequest) async throws -> Void

    private let verifyImplementation: Verify

    public init(verify: @escaping Verify) {
        verifyImplementation = verify
    }

    public func verify(_ request: GlossHomebrewUpgradeRequest) async throws {
        try await verifyImplementation(request)
    }

    public static func live(
        commandRunner: GlossCommandRunner = .live,
        commandTimeout: Duration = .seconds(60),
        fileLoader: @escaping @Sendable (URL) throws -> Data = {
            try Data(contentsOf: $0, options: [.mappedIfSafe])
        }
    ) -> Self {
        Self { request in
            let repository = try await commandRunner.run(
                executableURL: request.brewExecutableURL,
                arguments: Self.repositoryArguments,
                environment: GlossHomebrewUpgradeWorkflow
                    .noAutomaticUpdateEnvironment,
                timeout: commandTimeout
            )
            guard repository.terminationStatus == 0 else {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "无法定位 sunchj/tap"
                )
            }
            let repositoryText = String(
                decoding: repository.standardOutput,
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let repositoryLines = repositoryText.split(whereSeparator: \.isNewline)
            guard repositoryLines.count == 1,
                repositoryText.hasPrefix("/")
            else {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "tap 仓库路径无效"
                )
            }
            let repositoryURL = URL(fileURLWithPath: repositoryText)
                .standardizedFileURL
            guard repositoryURL.lastPathComponent == "homebrew-tap",
                repositoryURL.deletingLastPathComponent().lastPathComponent
                    == "sunchj",
                repositoryURL.resolvingSymlinksInPath() == repositoryURL
            else {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "tap 仓库身份无效"
                )
            }

            let caskURL =
                repositoryURL
                .appendingPathComponent("Casks", isDirectory: true)
                .appendingPathComponent("gloss.rb")
            guard
                caskURL.standardizedFileURL.path.hasPrefix(
                    repositoryURL.path + "/"
                ),
                caskURL.resolvingSymlinksInPath() == caskURL,
                Self.isRegularFile(caskURL)
            else {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "tap 中的 Casks/gloss.rb 不是受限目录内的常规文件"
                )
            }
            let caskData: Data
            do {
                caskData = try fileLoader(caskURL)
            } catch {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "无法读取 tap 中的 Casks/gloss.rb"
                )
            }
            let caskSHA256 = SHA256.hash(data: caskData)
                .map { String(format: "%02x", $0) }
                .joined()
            guard caskData.count == request.expectedHomebrewCaskSize,
                caskSHA256 == request.expectedHomebrewCaskSHA256
            else {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "tap 中的 Casks/gloss.rb 与签名 manifest 不一致"
                )
            }

            let info = try await commandRunner.run(
                executableURL: request.brewExecutableURL,
                arguments: GlossHomebrewInstallationDetector.infoArguments,
                environment: GlossHomebrewUpgradeWorkflow
                    .noAutomaticUpdateEnvironment,
                timeout: commandTimeout
            )
            guard info.terminationStatus == 0 else {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "无法读取 Gloss cask metadata"
                )
            }
            let release: GlossHomebrewCaskRelease
            do {
                release =
                    try GlossHomebrewInstallationDetector
                    .parseCaskRelease(info.standardOutput)
            } catch {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "Gloss cask metadata 无效"
                )
            }
            guard release.version == request.expectedVersion else {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "cask version 与签名 manifest 不一致"
                )
            }
            guard release.url == request.expectedAssetURL else {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "当前架构 cask URL 与签名 manifest 不一致"
                )
            }
            guard
                release.sha256
                    == request.expectedAssetSHA256.lowercased()
            else {
                throw GlossHomebrewUpgradeError.releaseBindingFailed(
                    "当前架构 cask SHA-256 与签名 manifest 不一致"
                )
            }
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            return false
        }
        return metadata.st_mode & S_IFMT == S_IFREG
    }
}

public struct GlossHomebrewUpgradeWorkflow: Sendable {
    public static let noAutomaticUpdateEnvironment = [
        "HOMEBREW_NO_AUTO_UPDATE": "1"
    ]
    public static let homebrewUpdateArguments = ["update", "--quiet"]
    public static let homebrewUpgradeArguments = [
        "upgrade",
        "--cask",
        "--require-sha",
        GlossHomebrewInstallationDetector.caskToken,
    ]
    public static let openExecutableURL = URL(fileURLWithPath: "/usr/bin/open")

    private let commandRunner: GlossCommandRunner
    private let parentProcessWaiter: GlossParentProcessWaiter
    private let recoveryManager: GlossAppUpdateRecoveryManager
    private let releaseBindingVerifier: GlossHomebrewReleaseBindingVerifier
    private let verifier: GlossHomebrewUpgradeVerifier
    private let parentExitTimeout: Duration
    private let commandTimeout: Duration
    private let now: @Sendable () -> Date

    public init(
        commandRunner: GlossCommandRunner,
        parentProcessWaiter: GlossParentProcessWaiter,
        recoveryManager: GlossAppUpdateRecoveryManager = .live(),
        releaseBindingVerifier: GlossHomebrewReleaseBindingVerifier? = nil,
        verifier: GlossHomebrewUpgradeVerifier,
        parentExitTimeout: Duration = .seconds(120),
        commandTimeout: Duration = .seconds(10 * 60),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.commandRunner = commandRunner
        self.parentProcessWaiter = parentProcessWaiter
        self.recoveryManager = recoveryManager
        self.releaseBindingVerifier =
            releaseBindingVerifier
            ?? .live(
                commandRunner: commandRunner,
                commandTimeout: commandTimeout
            )
        self.verifier = verifier
        self.parentExitTimeout = parentExitTimeout
        self.commandTimeout = commandTimeout
        self.now = now
    }

    public static func live() -> Self {
        let commandRunner = GlossCommandRunner.live
        return Self(
            commandRunner: commandRunner,
            parentProcessWaiter: .live,
            recoveryManager: .live(),
            releaseBindingVerifier: .live(
                commandRunner: commandRunner
            ),
            verifier: .live(commandRunner: commandRunner)
        )
    }

    @discardableResult
    public func runAndPersist(
        _ request: GlossHomebrewUpgradeRequest,
        afterValidation: @escaping @Sendable () throws -> Void = {}
    ) async throws -> GlossHomebrewUpgradeResult {
        var installedVersion: String?
        var requestIsValid = false
        var recoveryPrepared = false
        do {
            try request.validate()
            requestIsValid = true
            guard
                request.parentProcessIdentifier
                    != Int32(ProcessInfo.processInfo.processIdentifier)
            else {
                throw GlossHomebrewUpgradeError.invalidRequest(
                    "helper cannot wait for itself"
                )
            }
            try await recoveryManager.prepare(request)
            recoveryPrepared = true
            try afterValidation()
            try await parentProcessWaiter.wait(
                for: request.parentProcessIdentifier,
                timeout: parentExitTimeout
            )

            let update: GlossCommandOutput
            do {
                update = try await commandRunner.run(
                    executableURL: request.brewExecutableURL,
                    arguments: Self.homebrewUpdateArguments,
                    timeout: commandTimeout
                )
            } catch {
                throw GlossHomebrewUpgradeError.homebrewUpdateFailed(
                    status: -1,
                    detail: error.localizedDescription
                )
            }
            guard update.terminationStatus == 0 else {
                throw GlossHomebrewUpgradeError.homebrewUpdateFailed(
                    status: update.terminationStatus,
                    detail: Self.failureDetail(update)
                )
            }

            try await releaseBindingVerifier.verify(request)

            let upgrade: GlossCommandOutput
            do {
                upgrade = try await commandRunner.run(
                    executableURL: request.brewExecutableURL,
                    arguments: Self.homebrewUpgradeArguments,
                    environment: Self.noAutomaticUpdateEnvironment,
                    timeout: commandTimeout
                )
            } catch {
                throw GlossHomebrewUpgradeError.homebrewUpgradeFailed(
                    status: -1,
                    detail: error.localizedDescription
                )
            }
            guard upgrade.terminationStatus == 0 else {
                throw GlossHomebrewUpgradeError.homebrewUpgradeFailed(
                    status: upgrade.terminationStatus,
                    detail: Self.failureDetail(upgrade)
                )
            }

            installedVersion = try await verifier.verify(request)
            let success = GlossHomebrewUpgradeResult(
                outcome: .succeeded,
                expectedVersion: request.expectedVersion,
                installedVersion: installedVersion,
                completedAt: now()
            )
            try GlossHomebrewUpgradeResultStore.write(
                success,
                to: request.resultURL
            )

            try await relaunch(request)
            return success
        } catch {
            guard requestIsValid else {
                throw error
            }
            var recoveredPreviousInstallation = false
            var recoveryError: String?
            var reportedError = error
            if recoveryPrepared {
                do {
                    recoveredPreviousInstallation =
                        try await recoveryManager.restoreIfNeeded(request)
                } catch {
                    recoveryError = error.localizedDescription
                    reportedError = GlossHomebrewUpgradeError.recoveryFailed(
                        "原始错误：\(reportedError.localizedDescription)；\(error.localizedDescription)"
                    )
                }
            }
            var failure = failureResult(
                request: request,
                installedVersion: installedVersion,
                error: reportedError,
                recoveredPreviousInstallation:
                    recoveredPreviousInstallation,
                recoveryError: recoveryError
            )
            var resultWriteError: Error?
            do {
                try GlossHomebrewUpgradeResultStore.write(
                    failure,
                    to: request.resultURL
                )
            } catch {
                resultWriteError = error
            }
            do {
                try await relaunch(request)
            } catch {
                let originalMessage =
                    failure.message ?? "原始更新失败原因未知"
                let relaunchError = GlossHomebrewUpgradeError.relaunchFailed(
                    status: (error as? GlossHomebrewUpgradeError)
                        .flatMap { upgradeError -> Int32? in
                            if case .relaunchFailed(let status, _) = upgradeError {
                                return status
                            }
                            return nil
                        } ?? -1,
                    detail:
                        "\(originalMessage)；重新打开也失败：\(error.localizedDescription)"
                )
                failure = failureResult(
                    request: request,
                    installedVersion: installedVersion,
                    error: relaunchError,
                    recoveredPreviousInstallation:
                        recoveredPreviousInstallation,
                    recoveryError: recoveryError
                )
                do {
                    try GlossHomebrewUpgradeResultStore.write(
                        failure,
                        to: request.resultURL
                    )
                } catch {
                    resultWriteError = resultWriteError ?? error
                }
            }
            if let resultWriteError {
                throw resultWriteError
            }
            return failure
        }
    }

    private func failureResult(
        request: GlossHomebrewUpgradeRequest,
        installedVersion: String?,
        error: Error,
        recoveredPreviousInstallation: Bool = false,
        recoveryError: String? = nil
    ) -> GlossHomebrewUpgradeResult {
        let upgradeError = error as? GlossHomebrewUpgradeError
        return GlossHomebrewUpgradeResult(
            outcome: .failed,
            expectedVersion: request.expectedVersion,
            installedVersion: installedVersion,
            errorCode: upgradeError?.resultCode ?? "unexpected_error",
            message: error.localizedDescription,
            recoveredPreviousInstallation:
                recoveredPreviousInstallation,
            recoveryError: recoveryError,
            completedAt: now()
        )
    }

    private static func failureDetail(
        _ output: GlossCommandOutput
    ) -> String {
        let data =
            output.standardError.isEmpty
            ? output.standardOutput
            : output.standardError
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "no diagnostic output"
        }
        return String(text.prefix(2_000))
    }

    private func relaunch(
        _ request: GlossHomebrewUpgradeRequest
    ) async throws {
        let relaunch: GlossCommandOutput
        do {
            relaunch = try await commandRunner.run(
                executableURL: Self.openExecutableURL,
                arguments: [request.currentBundlePath],
                timeout: .seconds(30)
            )
        } catch {
            throw GlossHomebrewUpgradeError.relaunchFailed(
                status: -1,
                detail: error.localizedDescription
            )
        }
        guard relaunch.terminationStatus == 0 else {
            throw GlossHomebrewUpgradeError.relaunchFailed(
                status: relaunch.terminationStatus,
                detail: Self.failureDetail(relaunch)
            )
        }
    }
}

public struct GlossUpdateHelperLaunch: Equatable, Sendable {
    public let processIdentifier: Int32
    public let stagingDirectoryURL: URL
    public let requestURL: URL
    public let resultURL: URL
    public let readinessURL: URL

    public init(
        processIdentifier: Int32,
        stagingDirectoryURL: URL,
        requestURL: URL,
        resultURL: URL,
        readinessURL: URL
    ) {
        self.processIdentifier = processIdentifier
        self.stagingDirectoryURL = stagingDirectoryURL
        self.requestURL = requestURL
        self.resultURL = resultURL
        self.readinessURL = readinessURL
    }
}

public struct GlossUpdateHelperReadinessWaiter: Sendable {
    public typealias Wait =
        @Sendable (URL, UUID, Int32, Duration) async throws -> Void

    private let waitImplementation: Wait

    public init(wait: @escaping Wait) {
        waitImplementation = wait
    }

    public func wait(
        for readinessURL: URL,
        requestIdentifier: UUID,
        helperProcessIdentifier: Int32,
        timeout: Duration
    ) async throws {
        try await waitImplementation(
            readinessURL,
            requestIdentifier,
            helperProcessIdentifier,
            timeout
        )
    }

    public static let live = Self {
        readinessURL,
        requestIdentifier,
        helperProcessIdentifier,
        timeout in
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: readinessURL.path) {
                let readiness = try GlossUpdateHelperReadinessStore.load(
                    from: readinessURL
                )
                guard
                    readiness.schemaVersion
                        == GlossUpdateHelperReadiness.currentSchemaVersion,
                    readiness.requestIdentifier == requestIdentifier,
                    readiness.helperProcessIdentifier
                        == helperProcessIdentifier
                else {
                    throw GlossHomebrewUpgradeError.invalidRequest(
                        "helper readiness marker does not match the request"
                    )
                }
                return
            }
            guard Self.isRunning(helperProcessIdentifier) else {
                throw GlossHomebrewUpgradeError.helperExitedBeforeReady
            }
            try await Task<Never, Never>.sleep(for: .milliseconds(50))
        }
        if Self.isRunning(helperProcessIdentifier) {
            kill(pid_t(helperProcessIdentifier), SIGTERM)
        }
        throw GlossHomebrewUpgradeError.helperReadinessTimedOut
    }

    private static func isRunning(_ processIdentifier: Int32) -> Bool {
        if kill(pid_t(processIdentifier), 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

public struct GlossAppUpdateHelperLauncher: Sendable {
    public static let helperName = "gloss-update-helper"

    private let readinessWaiter: GlossUpdateHelperReadinessWaiter

    public init(
        readinessWaiter: GlossUpdateHelperReadinessWaiter = .live
    ) {
        self.readinessWaiter = readinessWaiter
    }

    public func launch(
        bundledHelperURL: URL,
        installation: GlossHomebrewInstallation,
        update: GlossAppUpdateAvailability,
        parentProcessIdentifier: Int32,
        currentBundleURL: URL,
        cacheRootURL: URL,
        resultURL: URL,
        readinessTimeout: Duration = .seconds(30)
    ) async throws -> GlossUpdateHelperLaunch {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: bundledHelperURL.path) else {
            throw GlossHomebrewUpgradeError.invalidRequest(
                "bundled update helper is missing"
            )
        }

        let stagingDirectoryURL = cacheRootURL.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let stagedHelperURL = stagingDirectoryURL.appendingPathComponent(
            Self.helperName
        )
        let requestURL = stagingDirectoryURL.appendingPathComponent(
            "request.json"
        )
        let readinessURL = stagingDirectoryURL.appendingPathComponent(
            "ready.json"
        )
        let manifestURL = stagingDirectoryURL.appendingPathComponent(
            "release-manifest.json"
        )
        let manifestSignatureURL = stagingDirectoryURL.appendingPathComponent(
            "release-manifest.json.sig"
        )
        let recoveryBundleURL =
            stagingDirectoryURL
            .appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent("Gloss.app", isDirectory: true)
        let requestIdentifier = UUID()
        let request = GlossHomebrewUpgradeRequest(
            installation: installation,
            update: update,
            parentProcessIdentifier: parentProcessIdentifier,
            currentBundleURL: currentBundleURL,
            resultURL: resultURL,
            readinessURL: readinessURL,
            manifestURL: manifestURL,
            manifestSignatureURL: manifestSignatureURL,
            recoveryBundleURL: recoveryBundleURL,
            requestIdentifier: requestIdentifier
        )
        try request.validate()

        var process: Process?
        do {
            try fileManager.createDirectory(
                at: stagingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(
                at: bundledHelperURL,
                to: stagedHelperURL
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: stagedHelperURL.path
            )
            if fileManager.fileExists(atPath: resultURL.path) {
                try fileManager.removeItem(at: resultURL)
            }
            try update.manifestData.write(to: manifestURL, options: .atomic)
            try update.detachedSignatureData.write(
                to: manifestSignatureURL,
                options: .atomic
            )
            for protectedURL in [manifestURL, manifestSignatureURL] {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: protectedURL.path
                )
            }
            try GlossHomebrewUpgradeRequestStore.write(
                request,
                to: requestURL
            )

            let helperProcess = Process()
            process = helperProcess
            helperProcess.executableURL = stagedHelperURL
            helperProcess.arguments = [
                GlossUpdateHelperArguments.requestFileFlag,
                requestURL.path,
            ]
            helperProcess.standardInput = FileHandle.nullDevice
            helperProcess.standardOutput = FileHandle.nullDevice
            helperProcess.standardError = FileHandle.nullDevice
            try helperProcess.run()
            try await readinessWaiter.wait(
                for: readinessURL,
                requestIdentifier: requestIdentifier,
                helperProcessIdentifier: helperProcess.processIdentifier,
                timeout: readinessTimeout
            )

            return GlossUpdateHelperLaunch(
                processIdentifier: helperProcess.processIdentifier,
                stagingDirectoryURL: stagingDirectoryURL,
                requestURL: requestURL,
                resultURL: resultURL,
                readinessURL: readinessURL
            )
        } catch {
            if let process, process.isRunning {
                process.terminate()
            }
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw error
        }
    }
}
