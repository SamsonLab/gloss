import CryptoKit
import Foundation
import Testing

@testable import GlossCore

@Suite("Gloss app update discovery")
struct GlossAppUpdateDiscoveryTests {
    private enum TestError: Error {
        case offline
    }

    private actor FetchRecorder {
        var payloads: [URL: Data]
        var offline = false
        var requestedURLs: [URL] = []

        init(payloads: [URL: Data] = [:]) {
            self.payloads = payloads
        }

        func fetch(_ url: URL) throws -> Data {
            requestedURLs.append(url)
            if offline {
                throw TestError.offline
            }
            return payloads[url] ?? Data()
        }

        func setOffline() {
            offline = true
        }
    }

    private actor CheckHistory {
        var lastCheck: Date?
        var recordedChecks: [Date] = []

        init(lastCheck: Date? = nil) {
            self.lastCheck = lastCheck
        }

        func record(_ date: Date) {
            lastCheck = date
            recordedChecks.append(date)
        }
    }

    @Test("semantic version precedence compares numeric components")
    func comparesSemanticVersions() throws {
        let newerPatch = try #require(GlossSemanticVersion("0.8.10"))
        let olderPatch = try #require(GlossSemanticVersion("0.8.9"))
        let prerelease = try #require(GlossSemanticVersion("0.8.10-rc.2"))
        let laterPrerelease = try #require(GlossSemanticVersion("0.8.10-rc.10"))
        let buildOne = try #require(GlossSemanticVersion("0.8.10+build.1"))
        let buildTwo = try #require(GlossSemanticVersion("0.8.10+build.2"))

        #expect(newerPatch > olderPatch)
        #expect(prerelease < laterPrerelease)
        #expect(laterPrerelease < newerPatch)
        #expect(buildOne == buildTwo)
        #expect(GlossSemanticVersion("0.08.10") == nil)
        #expect(GlossSemanticVersion("0.8") == nil)
        #expect(GlossSemanticVersion("0.8.10-01") == nil)
    }

    @Test("official endpoints cannot be redirected by callers")
    func usesFixedOfficialEndpoints() {
        #expect(
            GlossAppReleaseEndpoint.manifestURL.absoluteString
                == "https://github.com/SunChJ/gloss-releases/releases/latest/download/gloss-release-manifest.json"
        )
        #expect(
            GlossAppReleaseEndpoint.signatureURL.absoluteString
                == "https://github.com/SunChJ/gloss-releases/releases/latest/download/gloss-release-manifest.json.sig"
        )
    }

    @Test("valid signed manifest reports only advisory release metadata")
    func discoversSignedUpdate() async throws {
        let signed = try signedManifest(version: "0.8.10")
        let fetchRecorder = FetchRecorder(
            payloads: [
                GlossAppReleaseEndpoint.manifestURL: signed.manifest,
                GlossAppReleaseEndpoint.signatureURL: signed.signature,
            ]
        )
        let discovery = try GlossAppUpdateDiscovery(
            currentVersion: "0.8.9",
            fetcher: GlossAppUpdateDataFetcher { url in
                try await fetchRecorder.fetch(url)
            },
            manifestSigningPublicKey: signingPublicKey
        )

        let result = try await discovery.check(
            mode: .manual,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        guard case .updateAvailable(let update) = result else {
            Issue.record("Expected an available update")
            return
        }
        #expect(update.version == "0.8.10")
        #expect(update.releaseTag == "v0.8.10")
        #expect(update.architecture == GlossAppArchitecture.current)
        #expect(
            update.assetURL.lastPathComponent
                == "Gloss-macos-\(GlossAppArchitecture.current).zip"
        )
        #expect(
            update.homebrewCask.token
                == GlossHomebrewInstallationDetector.caskToken
        )
        #expect(update.manifestData == signed.manifest)
        #expect(update.detachedSignatureData == signed.signature)
        #expect(
            update.releasePageURL.absoluteString
                == "https://github.com/SunChJ/gloss-releases/releases/tag/v0.8.10"
        )
        let requestedURLs = await fetchRecorder.requestedURLs
        #expect(
            requestedURLs == [
                GlossAppReleaseEndpoint.manifestURL,
                GlossAppReleaseEndpoint.signatureURL,
            ]
        )
    }

    @Test("invalid signature fails closed")
    func rejectsInvalidSignature() async throws {
        let signed = try signedManifest(version: "0.8.10")
        var invalidSignature = signed.signature
        invalidSignature[invalidSignature.startIndex] ^= 0xff
        let discovery = try discovery(
            currentVersion: "0.8.9",
            manifestData: signed.manifest,
            signatureData: invalidSignature
        )

        await #expect(throws: GlossAppUpdateError.invalidManifestSignature) {
            try await discovery.check(mode: .manual)
        }
    }

    @Test("signed manifest with a foreign asset URL fails closed")
    func rejectsForeignManifest() async throws {
        var manifest = manifest(version: "0.8.10")
        manifest = GlossAppReleaseManifest(
            version: manifest.version,
            releaseTag: manifest.releaseTag,
            publishedAt: manifest.publishedAt,
            minimumMacOSVersion: manifest.minimumMacOSVersion,
            assets: [
                GlossAppReleaseManifest.Asset(
                    operatingSystem: "macos",
                    architecture: "arm64",
                    url: URL(
                        string:
                            "https://attacker.example/Gloss-macos-arm64.zip"
                    )!,
                    sha256: String(repeating: "a", count: 64),
                    size: 100
                ),
                manifest.assets[1],
            ],
            homebrewCask: manifest.homebrewCask
        )
        let signed = try sign(manifest)
        let discovery = try discovery(
            currentVersion: "0.8.9",
            manifestData: signed.manifest,
            signatureData: signed.signature
        )

        await #expect(throws: GlossAppUpdateError.self) {
            try await discovery.check(mode: .manual)
        }
    }

    @Test("malformed and mismatched official manifests fail closed")
    func rejectsMalformedManifest() async throws {
        let malformed = Data(#"{"schemaVersion":1}"#.utf8)
        let malformedSignature = try signingPrivateKey.signature(for: malformed)
        let malformedDiscovery = try discovery(
            currentVersion: "0.8.9",
            manifestData: malformed,
            signatureData: malformedSignature
        )
        await #expect(throws: GlossAppUpdateError.self) {
            try await malformedDiscovery.check(mode: .manual)
        }

        let mismatched = GlossAppReleaseManifest(
            version: "0.8.10",
            releaseTag: "v9.9.9",
            publishedAt: "2026-07-27T00:00:00Z",
            minimumMacOSVersion: "14.0",
            assets: manifest(version: "0.8.10").assets,
            homebrewCask: manifest(version: "0.8.10").homebrewCask
        )
        let signedMismatch = try sign(mismatched)
        let mismatchDiscovery = try discovery(
            currentVersion: "0.8.9",
            manifestData: signedMismatch.manifest,
            signatureData: signedMismatch.signature
        )
        await #expect(throws: GlossAppUpdateError.self) {
            try await mismatchDiscovery.check(mode: .manual)
        }
    }

    @Test("signed manifest cannot redirect the Homebrew cask token")
    func rejectsForeignCaskToken() async throws {
        let original = manifest(version: "0.8.10")
        let redirected = GlossAppReleaseManifest(
            version: original.version,
            releaseTag: original.releaseTag,
            publishedAt: original.publishedAt,
            minimumMacOSVersion: original.minimumMacOSVersion,
            assets: original.assets,
            homebrewCask: GlossAppReleaseManifest.HomebrewCask(
                token: "attacker/tap/gloss",
                url: original.homebrewCask.url,
                sha256: original.homebrewCask.sha256,
                size: original.homebrewCask.size
            )
        )
        let signed = try sign(redirected)
        let discovery = try discovery(
            currentVersion: "0.8.9",
            manifestData: signed.manifest,
            signatureData: signed.signature
        )

        await #expect(throws: GlossAppUpdateError.self) {
            try await discovery.check(mode: .manual)
        }
    }

    @Test("offline failure is surfaced and records the automatic attempt")
    func surfacesOfflineFailure() async throws {
        let fetchRecorder = FetchRecorder()
        await fetchRecorder.setOffline()
        let history = CheckHistory()
        let discovery = try GlossAppUpdateDiscovery(
            currentVersion: "0.8.9",
            fetcher: GlossAppUpdateDataFetcher { url in
                try await fetchRecorder.fetch(url)
            },
            history: makeHistory(history),
            manifestSigningPublicKey: signingPublicKey
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await #expect(throws: TestError.offline) {
            try await discovery.check(mode: .automatic, now: now)
        }
        #expect(await history.recordedChecks == [now])
    }

    @Test("automatic checks are throttled for 24 hours")
    func throttlesAutomaticChecks() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = now.addingTimeInterval(-60)
        let history = CheckHistory(lastCheck: previous)
        let fetchRecorder = FetchRecorder()
        let discovery = try GlossAppUpdateDiscovery(
            currentVersion: "0.8.9",
            fetcher: GlossAppUpdateDataFetcher { url in
                try await fetchRecorder.fetch(url)
            },
            history: makeHistory(history),
            manifestSigningPublicKey: signingPublicKey
        )

        let result = try await discovery.check(mode: .automatic, now: now)

        #expect(
            result
                == .throttled(
                    nextCheckAt: previous.addingTimeInterval(24 * 60 * 60)
                )
        )
        #expect(await fetchRecorder.requestedURLs.isEmpty)
        #expect(await history.recordedChecks.isEmpty)
    }

    @Test("manual checks bypass the 24-hour throttle")
    func manualCheckBypassesThrottle() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = CheckHistory(lastCheck: now.addingTimeInterval(-60))
        let signed = try signedManifest(version: "0.8.10")
        let fetchRecorder = FetchRecorder(
            payloads: [
                GlossAppReleaseEndpoint.manifestURL: signed.manifest,
                GlossAppReleaseEndpoint.signatureURL: signed.signature,
            ]
        )
        let discovery = try GlossAppUpdateDiscovery(
            currentVersion: "0.8.9",
            fetcher: GlossAppUpdateDataFetcher { url in
                try await fetchRecorder.fetch(url)
            },
            history: makeHistory(history),
            manifestSigningPublicKey: signingPublicKey
        )

        let result = try await discovery.check(mode: .manual, now: now)

        guard case .updateAvailable = result else {
            Issue.record("Expected manual check to bypass throttling")
            return
        }
        #expect(await fetchRecorder.requestedURLs.count == 2)
        #expect(await history.recordedChecks == [now])
    }

    @Test("same or older official version is up to date")
    func reportsUpToDate() async throws {
        let signed = try signedManifest(version: "0.8.9")
        let discovery = try discovery(
            currentVersion: "0.8.10",
            manifestData: signed.manifest,
            signatureData: signed.signature
        )

        #expect(
            try await discovery.check(mode: .manual)
                == .upToDate(latestVersion: "0.8.9")
        )
    }

    private func discovery(
        currentVersion: String,
        manifestData: Data,
        signatureData: Data
    ) throws -> GlossAppUpdateDiscovery {
        try GlossAppUpdateDiscovery(
            currentVersion: currentVersion,
            fetcher: GlossAppUpdateDataFetcher { url in
                switch url {
                case GlossAppReleaseEndpoint.manifestURL:
                    manifestData
                case GlossAppReleaseEndpoint.signatureURL:
                    signatureData
                default:
                    throw TestError.offline
                }
            },
            manifestSigningPublicKey: signingPublicKey
        )
    }

    private func makeHistory(
        _ history: CheckHistory
    ) -> GlossAppUpdateCheckHistory {
        GlossAppUpdateCheckHistory(
            lastCheck: { await history.lastCheck },
            recordCheck: { date in await history.record(date) }
        )
    }

    private func signedManifest(
        version: String
    ) throws -> (manifest: Data, signature: Data) {
        try sign(manifest(version: version))
    }

    private func sign(
        _ manifest: GlossAppReleaseManifest
    ) throws -> (manifest: Data, signature: Data) {
        let data = try JSONEncoder().encode(manifest)
        return (data, try signingPrivateKey.signature(for: data))
    }

    private func manifest(version: String) -> GlossAppReleaseManifest {
        let releaseTag = "v\(version)"
        return GlossAppReleaseManifest(
            version: version,
            releaseTag: releaseTag,
            publishedAt: "2026-07-27T00:00:00Z",
            minimumMacOSVersion: "14.0",
            assets: ["arm64", "x86_64"].map { architecture in
                GlossAppReleaseManifest.Asset(
                    operatingSystem: "macos",
                    architecture: architecture,
                    url: URL(
                        string:
                            "https://github.com/SunChJ/gloss-releases/releases/download/\(releaseTag)/Gloss-macos-\(architecture).zip"
                    )!,
                    sha256: String(repeating: "a", count: 64),
                    size: 100
                )
            },
            homebrewCask: GlossAppReleaseManifest.HomebrewCask(
                url: URL(
                    string:
                        "https://github.com/SunChJ/gloss-releases/releases/download/\(releaseTag)/gloss.rb"
                )!,
                sha256: String(repeating: "b", count: 64),
                size: 200
            )
        )
    }

    private var signingPrivateKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(0..<32)
        )
    }

    private var signingPublicKey: Data {
        signingPrivateKey.publicKey.rawRepresentation
    }
}
