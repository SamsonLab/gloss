import CryptoKit
import Foundation

public struct GlossSemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]
    public let buildMetadata: [String]

    public init?(_ value: String) {
        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2,
            buildParts.first?.isEmpty == false
        else {
            return nil
        }

        let precedence = buildParts[0]
        let precedenceParts = precedence.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard precedenceParts.count <= 2,
            precedenceParts.first?.isEmpty == false
        else {
            return nil
        }

        let core = precedenceParts[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard core.count == 3,
            let major = Self.parseCoreNumber(core[0]),
            let minor = Self.parseCoreNumber(core[1]),
            let patch = Self.parseCoreNumber(core[2])
        else {
            return nil
        }

        let prerelease =
            precedenceParts.count == 2
            ? precedenceParts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            ).map(String.init)
            : []
        guard Self.validateIdentifiers(prerelease, rejectNumericLeadingZeroes: true) else {
            return nil
        }

        let buildMetadata =
            buildParts.count == 2
            ? buildParts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            ).map(String.init)
            : []
        guard Self.validateIdentifiers(buildMetadata, rejectNumericLeadingZeroes: false) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildMetadata = buildMetadata
    }

    public var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            value += "-\(prerelease.joined(separator: "."))"
        }
        if !buildMetadata.isEmpty {
            value += "+\(buildMetadata.joined(separator: "."))"
        }
        return value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsCore = [lhs.major, lhs.minor, lhs.patch]
        let rhsCore = [rhs.major, rhs.minor, rhs.patch]
        if lhsCore != rhsCore {
            return lhsCore.lexicographicallyPrecedes(rhsCore)
        }

        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            guard left != right else {
                continue
            }
            let leftIsNumeric = left.allSatisfy(\.isNumber)
            let rightIsNumeric = right.allSatisfy(\.isNumber)
            switch (leftIsNumeric, rightIsNumeric) {
            case (true, true):
                if left.count != right.count {
                    return left.count < right.count
                }
                return left < right
            case (true, false):
                return true
            case (false, true):
                return false
            case (false, false):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func parseCoreNumber(_ value: Substring) -> Int? {
        guard !value.isEmpty,
            value.allSatisfy(\.isNumber),
            value == "0" || value.first != "0"
        else {
            return nil
        }
        return Int(value)
    }

    private static func validateIdentifiers(
        _ identifiers: [String],
        rejectNumericLeadingZeroes: Bool
    ) -> Bool {
        identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                identifier.utf8.allSatisfy({
                    ($0 >= 48 && $0 <= 57)
                        || ($0 >= 65 && $0 <= 90)
                        || ($0 >= 97 && $0 <= 122)
                        || $0 == 45
                })
            else {
                return false
            }
            return !rejectNumericLeadingZeroes
                || !identifier.allSatisfy(\.isNumber)
                || identifier == "0"
                || identifier.first != "0"
        }
    }
}

public struct GlossAppReleaseManifest: Codable, Equatable, Sendable {
    public struct Asset: Codable, Equatable, Sendable {
        public let operatingSystem: String
        public let architecture: String
        public let url: URL
        public let sha256: String
        public let size: Int64

        public init(
            operatingSystem: String,
            architecture: String,
            url: URL,
            sha256: String,
            size: Int64
        ) {
            self.operatingSystem = operatingSystem
            self.architecture = architecture
            self.url = url
            self.sha256 = sha256
            self.size = size
        }
    }

    public struct HomebrewCask: Codable, Equatable, Sendable {
        public let token: String
        public let url: URL
        public let sha256: String
        public let size: Int64

        public init(
            token: String = GlossHomebrewInstallationDetector.caskToken,
            url: URL,
            sha256: String,
            size: Int64
        ) {
            self.token = token
            self.url = url
            self.sha256 = sha256
            self.size = size
        }
    }

    public let schemaVersion: Int
    public let channel: String
    public let version: String
    public let releaseTag: String
    public let publishedAt: String
    public let minimumMacOSVersion: String
    public let assets: [Asset]
    public let homebrewCask: HomebrewCask

    public init(
        schemaVersion: Int = 2,
        channel: String = "stable",
        version: String,
        releaseTag: String,
        publishedAt: String,
        minimumMacOSVersion: String,
        assets: [Asset],
        homebrewCask: HomebrewCask
    ) {
        self.schemaVersion = schemaVersion
        self.channel = channel
        self.version = version
        self.releaseTag = releaseTag
        self.publishedAt = publishedAt
        self.minimumMacOSVersion = minimumMacOSVersion
        self.assets = assets
        self.homebrewCask = homebrewCask
    }
}

public enum GlossAppArchitecture {
    public static var current: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unsupported"
        #endif
    }
}

public enum GlossAppReleaseEndpoint {
    public static let manifestURL = URL(
        string:
            "https://github.com/SunChJ/gloss-releases/releases/latest/download/gloss-release-manifest.json"
    )!
    public static let signatureURL = URL(
        string:
            "https://github.com/SunChJ/gloss-releases/releases/latest/download/gloss-release-manifest.json.sig"
    )!
    public static let releasesURL = URL(
        string: "https://github.com/SunChJ/gloss-releases/releases"
    )!

    public static func releasePageURL(for tag: String) -> URL {
        releasesURL.appendingPathComponent("tag").appendingPathComponent(tag)
    }
}

public enum GlossAppUpdateError: LocalizedError, Equatable, Sendable {
    case invalidCurrentVersion(String)
    case invalidSigningKey
    case invalidManifestSignature
    case invalidManifest(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion(let version):
            "当前 Gloss 版本无效：\(version)"
        case .invalidSigningKey:
            "Gloss 内置的应用更新 manifest 签名公钥无效。"
        case .invalidManifestSignature:
            "Gloss 应用更新 manifest 的 Ed25519 签名无效。"
        case .invalidManifest(let reason):
            "Gloss 应用更新 manifest 无效：\(reason)"
        }
    }
}

public struct GlossAppReleaseManifestValidator: Sendable {
    public static let pinnedManifestSigningPublicKey = Data(
        base64Encoded: "FtPLO0dyvSMP4BUSZtk4ROgObX6F2GAToLeNfOygcVY="
    )!

    private let publicKey: Curve25519.Signing.PublicKey

    public init(
        manifestSigningPublicKey: Data = Self.pinnedManifestSigningPublicKey
    ) throws {
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: manifestSigningPublicKey
            )
        } catch {
            throw GlossAppUpdateError.invalidSigningKey
        }
    }

    public func validate(
        manifestData: Data,
        detachedSignatureData: Data
    ) throws -> GlossAppReleaseManifest {
        let signature = try Self.decodeSignature(detachedSignatureData)
        guard publicKey.isValidSignature(signature, for: manifestData) else {
            throw GlossAppUpdateError.invalidManifestSignature
        }

        let manifest: GlossAppReleaseManifest
        do {
            manifest = try JSONDecoder().decode(
                GlossAppReleaseManifest.self,
                from: manifestData
            )
        } catch {
            throw GlossAppUpdateError.invalidManifest("JSON 无法解析")
        }
        try Self.validateContents(manifest)
        return manifest
    }

    private static func decodeSignature(_ data: Data) throws -> Data {
        if data.count == 64 {
            return data
        }
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let decoded = Data(base64Encoded: text),
            decoded.count == 64
        {
            return decoded
        }
        throw GlossAppUpdateError.invalidManifestSignature
    }

    private static func validateContents(_ manifest: GlossAppReleaseManifest) throws {
        guard manifest.schemaVersion == 2 else {
            throw GlossAppUpdateError.invalidManifest("不支持 schemaVersion")
        }
        guard manifest.channel == "stable" else {
            throw GlossAppUpdateError.invalidManifest("仅支持 stable 通道")
        }
        guard GlossSemanticVersion(manifest.version) != nil else {
            throw GlossAppUpdateError.invalidManifest("version 不是有效的语义化版本")
        }
        guard manifest.releaseTag == "v\(manifest.version)" else {
            throw GlossAppUpdateError.invalidManifest("releaseTag 与 version 不匹配")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard formatter.date(from: manifest.publishedAt) != nil else {
            throw GlossAppUpdateError.invalidManifest("publishedAt 不是 ISO 8601 时间")
        }
        guard
            manifest.minimumMacOSVersion.range(
                of: #"^[0-9]+(\.[0-9]+){1,2}$"#,
                options: .regularExpression
            ) != nil
        else {
            throw GlossAppUpdateError.invalidManifest("minimumMacOSVersion 无效")
        }

        var architectures = Set<String>()
        for asset in manifest.assets {
            guard asset.operatingSystem == "macos",
                ["arm64", "x86_64"].contains(asset.architecture),
                architectures.insert(asset.architecture).inserted
            else {
                throw GlossAppUpdateError.invalidManifest("asset 平台无效或重复")
            }
            guard asset.size > 0 else {
                throw GlossAppUpdateError.invalidManifest("asset size 必须大于零")
            }
            guard
                asset.sha256.range(
                    of: "^[0-9a-f]{64}$",
                    options: .regularExpression
                ) != nil
            else {
                throw GlossAppUpdateError.invalidManifest("asset SHA-256 无效")
            }
            try validateOfficialAssetURL(
                asset.url,
                architecture: asset.architecture,
                releaseTag: manifest.releaseTag
            )
        }
        guard architectures == Set(["arm64", "x86_64"]) else {
            throw GlossAppUpdateError.invalidManifest("缺少受支持架构的 asset")
        }
        guard
            manifest.homebrewCask.token
                == GlossHomebrewInstallationDetector.caskToken
        else {
            throw GlossAppUpdateError.invalidManifest(
                "homebrewCask token 无效"
            )
        }
        guard manifest.homebrewCask.size > 0 else {
            throw GlossAppUpdateError.invalidManifest(
                "homebrewCask size 必须大于零"
            )
        }
        guard
            manifest.homebrewCask.sha256.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
        else {
            throw GlossAppUpdateError.invalidManifest(
                "homebrewCask SHA-256 无效"
            )
        }
        try validateOfficialHomebrewCaskURL(
            manifest.homebrewCask.url,
            releaseTag: manifest.releaseTag
        )
    }

    static func validateOfficialAssetURL(
        _ url: URL,
        architecture: String,
        releaseTag: String
    ) throws {
        guard
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.scheme == "https",
            components.host?.lowercased() == "github.com",
            components.port == nil,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path
                == "/SunChJ/gloss-releases/releases/download/\(releaseTag)/Gloss-macos-\(architecture).zip"
        else {
            throw GlossAppUpdateError.invalidManifest("asset URL 不是官方发行地址")
        }
    }

    static func validateOfficialHomebrewCaskURL(
        _ url: URL,
        releaseTag: String
    ) throws {
        guard
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.scheme == "https",
            components.host?.lowercased() == "github.com",
            components.port == nil,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path
                == "/SunChJ/gloss-releases/releases/download/\(releaseTag)/gloss.rb"
        else {
            throw GlossAppUpdateError.invalidManifest(
                "homebrewCask URL 不是官方发行地址"
            )
        }
    }
}

public struct GlossAppUpdateDataFetcher: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let fetchImplementation: Fetch

    public init(fetch: @escaping Fetch) {
        fetchImplementation = fetch
    }

    public func fetch(from url: URL) async throws -> Data {
        try await fetchImplementation(url)
    }

    public static let live = ephemeral()

    public static func ephemeral(
        requestTimeout: TimeInterval = 12,
        resourceTimeout: TimeInterval = 60
    ) -> Self {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)

        return Self { url in
            let (data, response) = try await session.data(from: url)
            if let response = response as? HTTPURLResponse,
                !(200..<300).contains(response.statusCode)
            {
                throw GlossAppUpdateTransportError.httpFailure(
                    url: url,
                    statusCode: response.statusCode
                )
            }
            return data
        }
    }
}

public enum GlossAppUpdateTransportError: LocalizedError, Equatable, Sendable {
    case httpFailure(url: URL, statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .httpFailure(let url, let statusCode):
            "获取 \(url.absoluteString) 失败（HTTP \(statusCode)）。"
        }
    }
}

public struct GlossAppUpdateCheckHistory: Sendable {
    public typealias LastCheck = @Sendable () async -> Date?
    public typealias RecordCheck = @Sendable (Date) async -> Void

    private let lastCheckImplementation: LastCheck
    private let recordCheckImplementation: RecordCheck

    public init(
        lastCheck: @escaping LastCheck,
        recordCheck: @escaping RecordCheck
    ) {
        lastCheckImplementation = lastCheck
        recordCheckImplementation = recordCheck
    }

    public func lastCheck() async -> Date? {
        await lastCheckImplementation()
    }

    public func recordCheck(at date: Date) async {
        await recordCheckImplementation(date)
    }

    public static let transient = Self(
        lastCheck: { nil },
        recordCheck: { _ in }
    )
}

public enum GlossAppUpdateCheckMode: Sendable {
    case automatic
    case manual
}

public struct GlossAppUpdateAvailability: Equatable, Sendable {
    public let version: String
    public let releaseTag: String
    public let publishedAt: Date
    public let minimumMacOSVersion: String
    public let releasePageURL: URL
    public let architecture: String
    public let assetURL: URL
    public let assetSHA256: String
    public let assetSize: Int64
    public let homebrewCask: GlossAppReleaseManifest.HomebrewCask
    public let manifestData: Data
    public let detachedSignatureData: Data

    public init(
        version: String,
        releaseTag: String,
        publishedAt: Date,
        minimumMacOSVersion: String,
        releasePageURL: URL,
        architecture: String,
        assetURL: URL,
        assetSHA256: String,
        assetSize: Int64,
        homebrewCask: GlossAppReleaseManifest.HomebrewCask,
        manifestData: Data,
        detachedSignatureData: Data
    ) {
        self.version = version
        self.releaseTag = releaseTag
        self.publishedAt = publishedAt
        self.minimumMacOSVersion = minimumMacOSVersion
        self.releasePageURL = releasePageURL
        self.architecture = architecture
        self.assetURL = assetURL
        self.assetSHA256 = assetSHA256
        self.assetSize = assetSize
        self.homebrewCask = homebrewCask
        self.manifestData = manifestData
        self.detachedSignatureData = detachedSignatureData
    }
}

public enum GlossAppUpdateCheckResult: Equatable, Sendable {
    case throttled(nextCheckAt: Date)
    case upToDate(latestVersion: String)
    case updateAvailable(GlossAppUpdateAvailability)
}

public actor GlossAppUpdateDiscovery {
    public static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private let currentVersion: GlossSemanticVersion
    private let fetcher: GlossAppUpdateDataFetcher
    private let history: GlossAppUpdateCheckHistory
    private let validator: GlossAppReleaseManifestValidator

    public init(
        currentVersion: String,
        fetcher: GlossAppUpdateDataFetcher,
        history: GlossAppUpdateCheckHistory = .transient,
        manifestSigningPublicKey: Data =
            GlossAppReleaseManifestValidator.pinnedManifestSigningPublicKey
    ) throws {
        guard let parsedCurrentVersion = GlossSemanticVersion(currentVersion) else {
            throw GlossAppUpdateError.invalidCurrentVersion(currentVersion)
        }
        self.currentVersion = parsedCurrentVersion
        self.fetcher = fetcher
        self.history = history
        validator = try GlossAppReleaseManifestValidator(
            manifestSigningPublicKey: manifestSigningPublicKey
        )
    }

    public func check(
        mode: GlossAppUpdateCheckMode = .automatic,
        now: Date = Date()
    ) async throws -> GlossAppUpdateCheckResult {
        if mode == .automatic,
            let lastCheck = await history.lastCheck()
        {
            let nextCheckAt = lastCheck.addingTimeInterval(
                Self.automaticCheckInterval
            )
            if now < nextCheckAt {
                return .throttled(nextCheckAt: nextCheckAt)
            }
        }

        await history.recordCheck(at: now)
        let manifestData = try await fetcher.fetch(
            from: GlossAppReleaseEndpoint.manifestURL
        )
        let signatureData = try await fetcher.fetch(
            from: GlossAppReleaseEndpoint.signatureURL
        )
        let manifest = try validator.validate(
            manifestData: manifestData,
            detachedSignatureData: signatureData
        )
        guard let availableVersion = GlossSemanticVersion(manifest.version) else {
            throw GlossAppUpdateError.invalidManifest(
                "version 不是有效的语义化版本"
            )
        }
        guard availableVersion > currentVersion else {
            return .upToDate(latestVersion: manifest.version)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let publishedAt = formatter.date(from: manifest.publishedAt) else {
            throw GlossAppUpdateError.invalidManifest(
                "publishedAt 不是 ISO 8601 时间"
            )
        }
        guard
            let asset = manifest.assets.first(where: {
                $0.operatingSystem == "macos"
                    && $0.architecture == GlossAppArchitecture.current
            })
        else {
            throw GlossAppUpdateError.invalidManifest(
                "缺少当前架构 \(GlossAppArchitecture.current) 的 asset"
            )
        }
        return .updateAvailable(
            GlossAppUpdateAvailability(
                version: manifest.version,
                releaseTag: manifest.releaseTag,
                publishedAt: publishedAt,
                minimumMacOSVersion: manifest.minimumMacOSVersion,
                releasePageURL: GlossAppReleaseEndpoint.releasePageURL(
                    for: manifest.releaseTag
                ),
                architecture: asset.architecture,
                assetURL: asset.url,
                assetSHA256: asset.sha256,
                assetSize: asset.size,
                homebrewCask: manifest.homebrewCask,
                manifestData: manifestData,
                detachedSignatureData: signatureData
            )
        )
    }
}
