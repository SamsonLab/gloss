import CryptoKit
import Foundation
import Testing

@testable import GlossCore

@Suite("BabelDOC runtime distribution")
struct BabelDOCRuntimeDistributionTests {
    private let platform = BabelDOCRuntimePlatform(
        operatingSystem: "macos",
        architecture: "arm64"
    )

    @Test("manifest selects the exact platform asset")
    func manifestSelectsPlatformAsset() throws {
        let armAsset = asset(
            url: try #require(URL(string: "https://example.com/arm64")),
            payload: Data("arm".utf8)
        )
        let intelAsset = BabelDOCRuntimeManifest.Asset(
            operatingSystem: "macos",
            architecture: "x86_64",
            url: try #require(URL(string: "https://example.com/x86_64")),
            sha256: sha256(Data("intel".utf8)),
            archiveFormat: .raw
        )
        let manifest = manifest(version: "0.6.4+gloss.2", assets: [intelAsset, armAsset])

        #expect(manifest.asset(for: platform) == armAsset)
        #expect(
            manifest.asset(
                for: BabelDOCRuntimePlatform(
                    operatingSystem: "linux",
                    architecture: "arm64"
                )
            ) == nil
        )
    }

    @Test("only published channels are exposed while reserved URLs stay deterministic")
    func defaultReleaseEndpoint() {
        let endpoint = BabelDOCRuntimeReleaseEndpoint()

        #expect(BabelDOCRuntimeChannel.allCases == [.stable])
        #expect(
            endpoint.manifestURL(for: .stable).absoluteString
                == "https://github.com/SunChJ/BabelDOC/releases/latest/download/gloss-runtime-manifest.json"
        )
        #expect(
            endpoint.manifestURL(for: .beta).absoluteString
                == "https://github.com/SunChJ/BabelDOC/releases/download/beta/gloss-runtime-manifest.json"
        )
        #expect(
            endpoint.manifestURL(for: .nightly).absoluteString
                == "https://github.com/SunChJ/BabelDOC/releases/download/nightly/gloss-runtime-manifest.json"
        )
        let manifestURL = endpoint.manifestURL(for: .stable)
        #expect(
            endpoint.signatureURL(forManifestURL: manifestURL).absoluteString
                == "\(manifestURL.absoluteString).sig"
        )
        let injectedURL = URL(
            string: "https://updates.example.test/runtime.json?token=test"
        )!
        #expect(
            endpoint.signatureURL(forManifestURL: injectedURL).absoluteString
                == "https://updates.example.test/runtime.json.sig?token=test"
        )
    }

    @Test("live transport keeps metadata fast and allows large archive downloads")
    func liveNetworkPoliciesMatchPayloadSize() {
        let metadataPolicy = BabelDOCRuntimeNetworkPolicy.metadata
        let archivePolicy = BabelDOCRuntimeNetworkPolicy.runtimeArchive
        let metadataConfiguration = BabelDOCRuntimeTransport.sessionConfiguration(
            for: metadataPolicy
        )
        let archiveConfiguration = BabelDOCRuntimeTransport.sessionConfiguration(
            for: archivePolicy
        )

        #expect(metadataConfiguration.timeoutIntervalForRequest == 12)
        #expect(metadataConfiguration.timeoutIntervalForResource == 60)
        #expect(!metadataConfiguration.waitsForConnectivity)
        #expect(archiveConfiguration.timeoutIntervalForRequest == 60)
        #expect(archiveConfiguration.timeoutIntervalForResource == 60 * 60)
        #expect(!archiveConfiguration.waitsForConnectivity)
    }

    @Test(
        "public runtime release installs and restores end to end",
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "GLOSS_RUN_BABELDOC_RUNTIME_SMOKE"
            ] == "1",
            "Set GLOSS_RUN_BABELDOC_RUNTIME_SMOKE=1 to download the public runtime."
        )
    )
    func publicRuntimeReleaseInstallsEndToEnd() async throws {
        let currentGlossVersion = try #require(
            ProcessInfo.processInfo.environment[
                "GLOSS_RUNTIME_SMOKE_APP_VERSION"
            ]
        )

        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            currentGlossVersion: currentGlossVersion
        )

        let installed = try await manager.update { progress in
            print(
                "BabelDOC runtime smoke: \(progress.operation.rawValue)"
                    + (progress.version.map { " \($0)" } ?? "")
            )
        }
        let installedVersion = try #require(installed.currentVersion)
        let executableURL = try #require(installed.currentExecutableURL)
        #expect(installed.operation == .ready)
        #expect(installed.lastError == nil)
        #expect(FileManager.default.isExecutableFile(atPath: executableURL.path))

        let restoredManager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            currentGlossVersion: currentGlossVersion
        )
        let restored = await restoredManager.snapshot()
        #expect(restored.currentVersion == installedVersion)
        #expect(restored.currentExecutableURL == executableURL)
        #expect(restored.operation == .idle)
        #expect(restored.lastError == nil)
    }

    @Test("raw runtime install verifies SHA, permissions, and persisted state")
    func installsAndPersistsRawRuntime() async throws {
        let root = try temporaryDirectory()
        let payload = Data("#!/bin/sh\necho gloss-babeldoc\n".utf8)
        let assetURL = try #require(URL(string: "https://example.com/gloss-babeldoc"))
        let runtimeManifest = manifest(
            version: "0.6.4+gloss.2",
            assets: [asset(url: assetURL, payload: payload)]
        )
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [assetURL: payload]),
            manifestSigningPublicKey: signingPublicKey
        )

        let installed = try await manager.install(runtimeManifest)

        #expect(installed.currentVersion == "0.6.4+gloss.2")
        #expect(installed.previousVersion == nil)
        #expect(installed.currentExecutableURL != nil)
        let executable = try #require(installed.currentExecutableURL)
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        #expect(try Data(contentsOf: executable) == payload)
        #expect(await manager.currentVersion == "0.6.4+gloss.2")
        #expect(await manager.currentExecutableURL == executable)
        #expect(await manager.availableVersion == "0.6.4+gloss.2")
        #expect(!(await manager.updateAvailable))

        let restoredManager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [:]),
            manifestSigningPublicKey: signingPublicKey
        )
        let restored = await restoredManager.snapshot()
        #expect(restored.currentVersion == installed.currentVersion)
        #expect(restored.currentExecutableURL == installed.currentExecutableURL)

        let stateURL = root.appendingPathComponent("state.json")
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: stateURL.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("persisted state cannot escape the managed versions directory")
    func rejectsEscapingPersistedState() throws {
        let root = try temporaryDirectory()
        _ = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [:]),
            manifestSigningPublicKey: signingPublicKey
        )
        let stateURL = root.appendingPathComponent("state.json")
        let state = """
            {
              "schemaVersion": 1,
              "channel": "stable",
              "current": {
                "version": "1.0.0",
                "directoryName": "../../../../../tmp/evil",
                "executablePath": "gloss-babeldoc",
                "sha256": "\(String(repeating: "0", count: 64))"
              }
            }
            """
        try Data(state.utf8).write(to: stateURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )

        #expect(throws: BabelDOCRuntimeDistributionError.corruptInstallationState) {
            _ = try BabelDOCRuntimeManager(
                rootDirectory: root,
                platform: platform,
                transport: transport(payloads: [:]),
                manifestSigningPublicKey: signingPublicKey
            )
        }
    }

    @Test("state replacement secures its temporary file before atomic rename")
    func stateTemporaryFileIsPrivateBeforeRename() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("state.json")
        let oldState = Data(#"{"schemaVersion":1,"channel":"stable"}"#.utf8)
        let newState = Data(
            #"{"schemaVersion":1,"channel":"stable","pinnedVersion":"1.0.0"}"#.utf8
        )
        try oldState.write(to: stateURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
        var temporaryURL: URL?

        try BabelDOCRuntimeManager.writeStateAtomically(
            newState,
            to: stateURL
        ) { stagedURL in
            temporaryURL = stagedURL
            let permissions = try #require(
                FileManager.default.attributesOfItem(
                    atPath: stagedURL.path
                )[.posixPermissions] as? NSNumber
            )
            #expect(permissions.intValue & 0o777 == 0o600)
            #expect(try Data(contentsOf: stagedURL).isEmpty)
            #expect(try Data(contentsOf: stateURL) == oldState)
        }

        let stagedURL = try #require(temporaryURL)
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(try Data(contentsOf: stateURL) == newState)
        let committedPermissions = try #require(
            FileManager.default.attributesOfItem(
                atPath: stateURL.path
            )[.posixPermissions] as? NSNumber
        )
        #expect(committedPermissions.intValue & 0o777 == 0o600)
    }

    @Test("persisted state must be an owned 0600 regular file")
    func rejectsInsecureOrLinkedState() throws {
        let insecureRoot = try temporaryDirectory()
        _ = try BabelDOCRuntimeManager(
            rootDirectory: insecureRoot,
            platform: platform,
            transport: transport(payloads: [:]),
            manifestSigningPublicKey: signingPublicKey
        )
        let insecureState = insecureRoot.appendingPathComponent("state.json")
        try Data(#"{"schemaVersion":1,"channel":"stable"}"#.utf8)
            .write(to: insecureState)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: insecureState.path
        )

        #expect(throws: BabelDOCRuntimeDistributionError.corruptInstallationState) {
            _ = try BabelDOCRuntimeManager(
                rootDirectory: insecureRoot,
                platform: platform,
                transport: transport(payloads: [:]),
                manifestSigningPublicKey: signingPublicKey
            )
        }

        let linkedRoot = try temporaryDirectory()
        _ = try BabelDOCRuntimeManager(
            rootDirectory: linkedRoot,
            platform: platform,
            transport: transport(payloads: [:]),
            manifestSigningPublicKey: signingPublicKey
        )
        let linkedState = linkedRoot.appendingPathComponent("state.json")
        let target = linkedRoot.appendingPathComponent("state-target.json")
        try Data(#"{"schemaVersion":1,"channel":"stable"}"#.utf8)
            .write(to: target)
        try FileManager.default.createSymbolicLink(
            at: linkedState,
            withDestinationURL: target
        )

        #expect(throws: BabelDOCRuntimeDistributionError.corruptInstallationState) {
            _ = try BabelDOCRuntimeManager(
                rootDirectory: linkedRoot,
                platform: platform,
                transport: transport(payloads: [:]),
                manifestSigningPublicKey: signingPublicKey
            )
        }
    }

    @Test("restoring state rejects a symlinked executable")
    func rejectsSymlinkedInstalledExecutable() async throws {
        let root = try temporaryDirectory()
        let payload = Data("runtime".utf8)
        let assetURL = try #require(URL(string: "https://example.com/runtime"))
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [assetURL: payload]),
            manifestSigningPublicKey: signingPublicKey
        )
        let installed = try await manager.install(
            manifest(
                version: "1.0.0",
                assets: [asset(url: assetURL, payload: payload)]
            )
        )
        let executable = try #require(installed.currentExecutableURL)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(
            at: executable,
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )

        #expect(throws: BabelDOCRuntimeDistributionError.corruptInstallationState) {
            _ = try BabelDOCRuntimeManager(
                rootDirectory: root,
                platform: platform,
                transport: transport(payloads: [:]),
                manifestSigningPublicKey: signingPublicKey
            )
        }
    }

    @Test("a safe previous runtime remains rollbackable when current is damaged")
    func restoresPreviousWhenCurrentIsDamaged() async throws {
        let root = try temporaryDirectory()
        let firstPayload = Data("first".utf8)
        let secondPayload = Data("second".utf8)
        let firstURL = try #require(URL(string: "https://example.com/first"))
        let secondURL = try #require(URL(string: "https://example.com/second"))
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(
                payloads: [
                    firstURL: firstPayload,
                    secondURL: secondPayload,
                ]
            ),
            manifestSigningPublicKey: signingPublicKey
        )
        let first = try await manager.install(
            manifest(
                version: "1.0.0",
                assets: [asset(url: firstURL, payload: firstPayload)]
            )
        )
        let firstExecutable = try #require(first.currentExecutableURL)
        let second = try await manager.install(
            manifest(
                version: "1.1.0",
                assets: [asset(url: secondURL, payload: secondPayload)]
            )
        )
        let damagedExecutable = try #require(second.currentExecutableURL)
        try FileManager.default.removeItem(at: damagedExecutable)

        let restoredManager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [:]),
            manifestSigningPublicKey: signingPublicKey
        )
        let degraded = await restoredManager.snapshot()
        #expect(degraded.currentVersion == nil)
        #expect(degraded.currentExecutableURL == nil)
        #expect(degraded.previousVersion == "1.0.0")

        let rolledBack = try await restoredManager.rollback()
        #expect(rolledBack.currentVersion == "1.0.0")
        #expect(rolledBack.previousVersion == nil)
        #expect(rolledBack.currentExecutableURL == firstExecutable)
        #expect(try Data(contentsOf: firstExecutable) == firstPayload)

        let reloadedManager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [:]),
            manifestSigningPublicKey: signingPublicKey
        )
        let reloaded = await reloadedManager.snapshot()
        #expect(reloaded.currentVersion == "1.0.0")
        #expect(reloaded.previousVersion == nil)
    }

    @Test("recovery rejects an unsafe previous runtime")
    func recoveryRejectsUnsafePrevious() async throws {
        let root = try temporaryDirectory()
        let firstPayload = Data("first".utf8)
        let secondPayload = Data("second".utf8)
        let firstURL = try #require(URL(string: "https://example.com/first"))
        let secondURL = try #require(URL(string: "https://example.com/second"))
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(
                payloads: [
                    firstURL: firstPayload,
                    secondURL: secondPayload,
                ]
            ),
            manifestSigningPublicKey: signingPublicKey
        )
        let first = try await manager.install(
            manifest(
                version: "1.0.0",
                assets: [asset(url: firstURL, payload: firstPayload)]
            )
        )
        let previousExecutable = try #require(first.currentExecutableURL)
        let second = try await manager.install(
            manifest(
                version: "1.1.0",
                assets: [asset(url: secondURL, payload: secondPayload)]
            )
        )
        let currentExecutable = try #require(second.currentExecutableURL)
        try FileManager.default.removeItem(at: currentExecutable)
        try FileManager.default.removeItem(at: previousExecutable)
        try FileManager.default.createSymbolicLink(
            at: previousExecutable,
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )

        #expect(throws: BabelDOCRuntimeDistributionError.corruptInstallationState) {
            _ = try BabelDOCRuntimeManager(
                rootDirectory: root,
                platform: platform,
                transport: transport(payloads: [:]),
                manifestSigningPublicKey: signingPublicKey
            )
        }
    }

    @Test("checksum failure preserves the active runtime")
    func checksumFailurePreservesCurrentRuntime() async throws {
        let root = try temporaryDirectory()
        let firstPayload = Data("first".utf8)
        let secondPayload = Data("second".utf8)
        let firstURL = try #require(URL(string: "https://example.com/first"))
        let secondURL = try #require(URL(string: "https://example.com/second"))
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(
                payloads: [
                    firstURL: firstPayload,
                    secondURL: secondPayload,
                ]
            ),
            manifestSigningPublicKey: signingPublicKey
        )

        _ = try await manager.install(
            manifest(
                version: "1.0.0",
                assets: [asset(url: firstURL, payload: firstPayload)]
            )
        )
        let invalidAsset = BabelDOCRuntimeManifest.Asset(
            operatingSystem: platform.operatingSystem,
            architecture: platform.architecture,
            url: secondURL,
            sha256: String(repeating: "0", count: 64),
            archiveFormat: .raw
        )

        await #expect(throws: BabelDOCRuntimeDistributionError.self) {
            try await manager.install(
                manifest(version: "1.1.0", assets: [invalidAsset])
            )
        }

        let snapshot = await manager.snapshot()
        #expect(snapshot.currentVersion == "1.0.0")
        let executable = try #require(snapshot.currentExecutableURL)
        #expect(try Data(contentsOf: executable) == firstPayload)
    }

    @Test("install keeps one rollback version and rollback swaps them")
    func updateAndRollback() async throws {
        let root = try temporaryDirectory()
        let firstPayload = Data("first".utf8)
        let secondPayload = Data("second".utf8)
        let firstURL = try #require(URL(string: "https://example.com/first"))
        let secondURL = try #require(URL(string: "https://example.com/second"))
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(
                payloads: [
                    firstURL: firstPayload,
                    secondURL: secondPayload,
                ]
            ),
            manifestSigningPublicKey: signingPublicKey
        )

        _ = try await manager.install(
            manifest(
                version: "1.0.0",
                assets: [asset(url: firstURL, payload: firstPayload)]
            )
        )
        let second = try await manager.install(
            manifest(
                version: "1.1.0",
                assets: [asset(url: secondURL, payload: secondPayload)]
            )
        )
        #expect(second.currentVersion == "1.1.0")
        #expect(second.previousVersion == "1.0.0")

        let rolledBack = try await manager.rollback()
        #expect(rolledBack.currentVersion == "1.0.0")
        #expect(rolledBack.previousVersion == "1.1.0")
        let executable = try #require(rolledBack.currentExecutableURL)
        #expect(try Data(contentsOf: executable) == firstPayload)
    }

    @Test("uninstall removes current and rollback runtimes and allows reinstall")
    func uninstallAndReinstall() async throws {
        let root = try temporaryDirectory()
        let firstPayload = Data("first-runtime".utf8)
        let secondPayload = Data("second-runtime".utf8)
        let firstURL = try #require(URL(string: "https://example.com/first-runtime"))
        let secondURL = try #require(URL(string: "https://example.com/second-runtime"))
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(
                payloads: [
                    firstURL: firstPayload,
                    secondURL: secondPayload,
                ]
            ),
            manifestSigningPublicKey: signingPublicKey
        )

        _ = try await manager.install(
            manifest(
                version: "1.0.0",
                assets: [asset(url: firstURL, payload: firstPayload)]
            )
        )
        _ = try await manager.install(
            manifest(
                version: "1.1.0",
                assets: [asset(url: secondURL, payload: secondPayload)]
            )
        )
        #expect(await manager.reclaimableBytes() >= Int64(firstPayload.count + secondPayload.count))

        let removed = try await manager.uninstall()
        #expect(removed.currentVersion == nil)
        #expect(removed.previousVersion == nil)
        #expect(removed.currentExecutableURL == nil)
        #expect(removed.operation == .idle)
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: versions.path).isEmpty
        )

        let restoredManager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [firstURL: firstPayload]),
            manifestSigningPublicKey: signingPublicKey
        )
        #expect(await restoredManager.snapshot().currentVersion == nil)
        let reinstalled = try await restoredManager.install(
            manifest(
                version: "1.0.0",
                assets: [asset(url: firstURL, payload: firstPayload)]
            )
        )
        #expect(reinstalled.currentVersion == "1.0.0")
        #expect(reinstalled.currentExecutableURL != nil)
    }

    @Test("update fetches signed metadata once and installs it")
    func updateUsesInjectedURLAndTransport() async throws {
        let root = try temporaryDirectory()
        let payload = Data("runtime".utf8)
        let manifestURL = try #require(URL(string: "https://updates.example.test/custom.json"))
        let assetURL = try #require(URL(string: "https://updates.example.test/runtime"))
        let runtimeManifest = manifest(
            version: "2.0.0",
            assets: [asset(url: assetURL, payload: payload)]
        )
        let manifestData = try JSONEncoder().encode(runtimeManifest)
        let recorder = URLRecorder()
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(
                payloads: [assetURL: payload],
                manifestData: manifestData,
                recorder: recorder
            ),
            manifestSigningPublicKey: signingPublicKey
        )

        let installed = try await manager.update(manifestURL: manifestURL)
        #expect(installed.currentVersion == "2.0.0")
        #expect(!installed.updateAvailable)
        #expect(
            Set(await recorder.fetchedURLs)
                == Set([manifestURL, signatureURL(for: manifestURL)])
        )
        #expect(await recorder.fetchedURLs.count == 2)
        #expect(await recorder.downloadedURLs == [assetURL])
    }

    @Test("available update installs without fetching metadata again")
    func installAvailableUpdateReusesVerifiedManifest() async throws {
        let root = try temporaryDirectory()
        let payload = Data("runtime".utf8)
        let manifestURL = try #require(URL(string: "https://updates.example.test/custom.json"))
        let assetURL = try #require(URL(string: "https://updates.example.test/runtime"))
        let runtimeManifest = manifest(
            version: "2.0.0",
            assets: [asset(url: assetURL, payload: payload)]
        )
        let manifestData = try JSONEncoder().encode(runtimeManifest)
        let recorder = URLRecorder()
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(
                payloads: [assetURL: payload],
                manifestData: manifestData,
                recorder: recorder
            ),
            manifestSigningPublicKey: signingPublicKey
        )

        let checked = try await manager.checkForUpdates(manifestURL: manifestURL)
        #expect(checked.availableVersion == "2.0.0")
        #expect(checked.updateAvailable)
        let fetchesAfterCheck = await recorder.fetchedURLs

        let installed = try await manager.installAvailableUpdate()
        #expect(installed.currentVersion == "2.0.0")
        #expect(!installed.updateAvailable)
        #expect(await recorder.fetchedURLs == fetchesAfterCheck)
        #expect(await recorder.downloadedURLs == [assetURL])
    }

    @Test("pin and channel reject manifests outside policy")
    func pinAndChannelPolicy() async throws {
        let root = try temporaryDirectory()
        let payload = Data("runtime".utf8)
        let assetURL = try #require(URL(string: "https://example.com/runtime"))
        let stable = manifest(
            version: "2.0.0",
            assets: [asset(url: assetURL, payload: payload)]
        )
        let stableData = try JSONEncoder().encode(stable)
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [:], manifestData: stableData),
            manifestSigningPublicKey: signingPublicKey
        )

        _ = try await manager.pin(version: "1.9.0")
        await #expect(throws: BabelDOCRuntimeDistributionError.self) {
            try await manager.checkForUpdates()
        }

        await #expect(
            throws: BabelDOCRuntimeDistributionError.channelUnavailable(.beta)
        ) {
            try await manager.setChannel(.beta)
        }
        let channelSnapshot = await manager.snapshot()
        #expect(channelSnapshot.channel == .stable)
        #expect(channelSnapshot.pinnedVersion == "1.9.0")
    }

    @Test("update check fails closed when the manifest is modified")
    func rejectsModifiedManifest() async throws {
        let root = try temporaryDirectory()
        let assetURL = try #require(URL(string: "https://example.com/runtime"))
        let original = try JSONEncoder().encode(
            manifest(
                version: "1.0.0",
                assets: [asset(url: assetURL, payload: Data("runtime".utf8))]
            )
        )
        let modified = Data(
            String(decoding: original, as: UTF8.self)
                .replacingOccurrences(of: "1.0.0", with: "9.0.0")
                .utf8
        )
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(
                payloads: [:],
                manifestData: modified,
                signatureData: signature(for: original)
            ),
            manifestSigningPublicKey: signingPublicKey
        )

        await #expect(
            throws: BabelDOCRuntimeDistributionError.manifestSignatureInvalid
        ) {
            try await manager.checkForUpdates()
        }
        #expect(await manager.snapshot().availableVersion == nil)
    }

    @Test("update check fails closed when the detached signature is modified")
    func rejectsModifiedSignature() async throws {
        let root = try temporaryDirectory()
        let assetURL = try #require(URL(string: "https://example.com/runtime"))
        let data = try JSONEncoder().encode(
            manifest(
                version: "1.0.0",
                assets: [asset(url: assetURL, payload: Data("runtime".utf8))]
            )
        )
        var invalidSignature = signature(for: data)
        invalidSignature[invalidSignature.startIndex] ^= 0xff
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(
                payloads: [:],
                manifestData: data,
                signatureData: invalidSignature
            ),
            manifestSigningPublicKey: signingPublicKey
        )

        await #expect(
            throws: BabelDOCRuntimeDistributionError.manifestSignatureInvalid
        ) {
            try await manager.checkForUpdates()
        }
    }

    @Test("update check accepts a Base64 detached signature")
    func acceptsBase64Signature() async throws {
        let root = try temporaryDirectory()
        let assetURL = try #require(URL(string: "https://example.com/runtime"))
        let data = try JSONEncoder().encode(
            manifest(
                version: "1.0.0",
                assets: [asset(url: assetURL, payload: Data("runtime".utf8))]
            )
        )
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(
                payloads: [:],
                manifestData: data,
                signatureData: signature(for: data).base64EncodedData()
            ),
            manifestSigningPublicKey: signingPublicKey
        )

        let checked = try await manager.checkForUpdates()
        #expect(checked.availableVersion == "1.0.0")
        #expect(checked.updateAvailable)
    }

    @Test("offline update check preserves an installed runtime")
    func offlineCheckPreservesInstalledRuntime() async throws {
        let root = try temporaryDirectory()
        let payload = Data("runtime".utf8)
        let assetURL = try #require(URL(string: "https://example.com/runtime"))
        let installer = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [assetURL: payload]),
            manifestSigningPublicKey: signingPublicKey
        )
        _ = try await installer.install(
            manifest(
                version: "1.0.0",
                assets: [asset(url: assetURL, payload: payload)]
            )
        )
        let offlineTransport = BabelDOCRuntimeTransport(
            fetchData: { _ in throw TestError.offline },
            download: { _, _ in throw TestError.offline }
        )
        let offlineManager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: offlineTransport,
            manifestSigningPublicKey: signingPublicKey
        )

        await #expect(throws: TestError.offline) {
            try await offlineManager.checkForUpdates()
        }
        let snapshot = await offlineManager.snapshot()
        #expect(snapshot.currentVersion == "1.0.0")
        #expect(snapshot.currentExecutableURL != nil)
        #expect(snapshot.operation == .failed)
    }

    @Test("minimum Gloss version and release notes URL fail closed")
    func validatesGlossCompatibilityAndReleaseNotesURL() async throws {
        let root = try temporaryDirectory()
        let payload = Data("runtime".utf8)
        let assetURL = try #require(URL(string: "https://example.com/runtime"))
        let runtimeAsset = asset(url: assetURL, payload: payload)
        let incompatible = BabelDOCRuntimeManifest(
            channel: .stable,
            version: "1.0.0",
            releaseTag: "v1.0.0",
            publishedAt: "2026-07-22T00:00:00Z",
            minimumGlossVersion: "0.8.0",
            assets: [runtimeAsset]
        )
        let oldManager = try BabelDOCRuntimeManager(
            rootDirectory: root.appendingPathComponent("old"),
            platform: platform,
            transport: transport(payloads: [assetURL: payload]),
            manifestSigningPublicKey: signingPublicKey,
            currentGlossVersion: "0.7.9"
        )

        await #expect(
            throws: BabelDOCRuntimeDistributionError.minimumGlossVersionNotMet(
                current: "0.7.9",
                minimum: "0.8.0"
            )
        ) {
            try await oldManager.install(incompatible)
        }

        let currentManager = try BabelDOCRuntimeManager(
            rootDirectory: root.appendingPathComponent("current"),
            platform: platform,
            transport: transport(payloads: [assetURL: payload]),
            manifestSigningPublicKey: signingPublicKey,
            currentGlossVersion: "0.8.0"
        )
        let installed = try await currentManager.install(incompatible)
        #expect(installed.currentVersion == "1.0.0")

        let insecureNotes = BabelDOCRuntimeManifest(
            channel: .stable,
            version: "1.0.1",
            releaseTag: "v1.0.1",
            publishedAt: "2026-07-22T00:00:00Z",
            releaseNotesURL: URL(string: "http://example.com/notes"),
            assets: [runtimeAsset]
        )
        await #expect(throws: BabelDOCRuntimeDistributionError.self) {
            try await currentManager.install(insecureNotes)
        }
    }

    @Test("declared asset size is verified before activation")
    func verifiesAssetSize() async throws {
        let root = try temporaryDirectory()
        let payload = Data("runtime".utf8)
        let assetURL = try #require(URL(string: "https://example.com/runtime"))
        let wrongSize = BabelDOCRuntimeManifest.Asset(
            operatingSystem: platform.operatingSystem,
            architecture: platform.architecture,
            url: assetURL,
            sha256: sha256(payload),
            size: Int64(payload.count + 1),
            archiveFormat: .raw
        )
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [assetURL: payload]),
            manifestSigningPublicKey: signingPublicKey
        )

        await #expect(
            throws: BabelDOCRuntimeDistributionError.payloadSizeMismatch(
                expected: Int64(payload.count + 1),
                actual: Int64(payload.count)
            )
        ) {
            try await manager.install(
                manifest(version: "1.0.0", assets: [wrongSize])
            )
        }
        #expect(await manager.snapshot().currentVersion == nil)
    }

    @Test("snapshot stream reports operation changes")
    func snapshotStreamReportsOperations() async throws {
        let root = try temporaryDirectory()
        let payload = Data("runtime".utf8)
        let assetURL = try #require(URL(string: "https://example.com/runtime"))
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root,
            platform: platform,
            transport: transport(payloads: [assetURL: payload]),
            manifestSigningPublicKey: signingPublicKey
        )
        let stream = await manager.snapshots()
        let collector = SnapshotCollector()
        let task = Task {
            for await snapshot in stream {
                await collector.append(snapshot)
                if snapshot.currentVersion == "1.0.0" {
                    break
                }
            }
        }

        _ = try await manager.install(
            manifest(
                version: "1.0.0",
                assets: [asset(url: assetURL, payload: payload)]
            )
        )
        await task.value

        let operations = await collector.snapshots.map(\.operation)
        #expect(operations.first == .idle)
        #expect(operations.contains(.downloading))
        #expect(operations.contains(.verifying))
        #expect(operations.contains(.extracting))
        #expect(operations.contains(.installing))
        #expect(operations.last == .ready)
    }

    @Test("archive entry validation blocks traversal and absolute paths")
    func archivePathValidation() {
        #expect(throws: BabelDOCRuntimeDistributionError.self) {
            try BabelDOCRuntimeManager.validateArchiveEntries(
                "gloss-babeldoc\n../outside\n"
            )
        }
        #expect(throws: BabelDOCRuntimeDistributionError.self) {
            try BabelDOCRuntimeManager.validateArchiveEntries(
                "/tmp/gloss-babeldoc\n"
            )
        }
        #expect(throws: Never.self) {
            try BabelDOCRuntimeManager.validateArchiveEntries(
                "runtime/\nruntime/bin/\nruntime/bin/gloss-babeldoc\n"
            )
        }
    }

    @Test("tar archives containing symlinks are rejected before install")
    func rejectsTarSymlink() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/tar") else {
            return
        }
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("archive-source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        let executable = source.appendingPathComponent("gloss-babeldoc")
        try Data("runtime".utf8).write(to: executable)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        let archive = root.appendingPathComponent("runtime.tar.gz")
        try run(
            "/usr/bin/tar",
            ["-czf", archive.path, "-C", source.path, "."]
        )

        let assetURL = try #require(URL(string: "https://example.com/runtime.tar.gz"))
        let payload = try Data(contentsOf: archive)
        let tarAsset = BabelDOCRuntimeManifest.Asset(
            operatingSystem: platform.operatingSystem,
            architecture: platform.architecture,
            url: assetURL,
            sha256: sha256(payload),
            archiveFormat: .tarGzip
        )
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root.appendingPathComponent("install", isDirectory: true),
            platform: platform,
            transport: transport(payloads: [assetURL: payload]),
            manifestSigningPublicKey: signingPublicKey
        )

        await #expect(throws: BabelDOCRuntimeDistributionError.self) {
            try await manager.install(
                manifest(version: "1.0.0", assets: [tarAsset])
            )
        }
        #expect(await manager.snapshot().currentVersion == nil)
    }

    @Test(
        "large archive listings are drained without blocking",
        .timeLimit(.minutes(1))
    )
    func installsTarWithLargeListing() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/tar") else {
            return
        }
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("large-archive-source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try Data("runtime".utf8).write(
            to: source.appendingPathComponent("gloss-babeldoc")
        )
        let suffix = String(repeating: "x", count: 72)
        for index in 0..<2_600 {
            let name = String(format: "payload-%04d-%@", index, suffix)
            try Data().write(to: source.appendingPathComponent(name))
        }

        let archive = root.appendingPathComponent("large-runtime.tar.gz")
        try run(
            "/usr/bin/tar",
            ["-czf", archive.path, "-C", source.path, "."]
        )
        let payload = try Data(contentsOf: archive)
        let assetURL = try #require(
            URL(string: "https://example.com/large-runtime.tar.gz")
        )
        let tarAsset = BabelDOCRuntimeManifest.Asset(
            operatingSystem: platform.operatingSystem,
            architecture: platform.architecture,
            url: assetURL,
            sha256: sha256(payload),
            archiveFormat: .tarGzip
        )
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root.appendingPathComponent("install", isDirectory: true),
            platform: platform,
            transport: transport(payloads: [assetURL: payload]),
            manifestSigningPublicKey: signingPublicKey
        )

        let installed = try await manager.install(
            manifest(version: "1.0.0", assets: [tarAsset])
        )

        #expect(installed.currentVersion == "1.0.0")
        #expect(installed.currentExecutableURL != nil)
    }

    @Test("zip symlink is rejected before a child path can escape")
    func rejectsZipSymlinkBeforeExtraction() async throws {
        guard
            FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
            FileManager.default.isExecutableFile(atPath: "/usr/bin/zipinfo")
        else {
            return
        }
        let root = try temporaryDirectory()
        let archive = root.appendingPathComponent("runtime.zip")
        let escaped = root.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createDirectory(
            at: escaped,
            withIntermediateDirectories: true
        )
        let escapedChild = escaped.appendingPathComponent("child")
        let python = """
            import stat
            import sys
            import zipfile

            with zipfile.ZipFile(sys.argv[1], "w") as archive:
                link = zipfile.ZipInfo("link")
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(link, sys.argv[2])
                archive.writestr("link/child", "escaped")
                archive.writestr("gloss-babeldoc", "runtime")
            """
        try run(
            "/usr/bin/python3",
            ["-c", python, archive.path, escaped.path]
        )

        let assetURL = try #require(URL(string: "https://example.com/runtime.zip"))
        let payload = try Data(contentsOf: archive)
        let zipAsset = BabelDOCRuntimeManifest.Asset(
            operatingSystem: platform.operatingSystem,
            architecture: platform.architecture,
            url: assetURL,
            sha256: sha256(payload),
            archiveFormat: .zip
        )
        let manager = try BabelDOCRuntimeManager(
            rootDirectory: root.appendingPathComponent("install", isDirectory: true),
            platform: platform,
            transport: transport(payloads: [assetURL: payload]),
            manifestSigningPublicKey: signingPublicKey
        )

        await #expect(throws: BabelDOCRuntimeDistributionError.self) {
            try await manager.install(
                manifest(version: "1.0.0", assets: [zipAsset])
            )
        }
        #expect(!FileManager.default.fileExists(atPath: escapedChild.path))
    }

    private func manifest(
        version: String,
        channel: BabelDOCRuntimeChannel = .stable,
        assets: [BabelDOCRuntimeManifest.Asset]
    ) -> BabelDOCRuntimeManifest {
        BabelDOCRuntimeManifest(
            channel: channel,
            version: version,
            releaseTag: "v\(version.replacingOccurrences(of: "+", with: "-"))",
            publishedAt: "2026-07-22T00:00:00Z",
            assets: assets
        )
    }

    private func asset(
        url: URL,
        payload: Data
    ) -> BabelDOCRuntimeManifest.Asset {
        BabelDOCRuntimeManifest.Asset(
            operatingSystem: platform.operatingSystem,
            architecture: platform.architecture,
            url: url,
            sha256: sha256(payload),
            archiveFormat: .raw
        )
    }

    private func transport(
        payloads: [URL: Data],
        manifestData: Data = Data(),
        signatureData: Data? = nil,
        recorder: URLRecorder? = nil
    ) -> BabelDOCRuntimeTransport {
        let detachedSignature = signatureData ?? signature(for: manifestData)
        return BabelDOCRuntimeTransport(
            fetchData: { url in
                await recorder?.recordFetch(url)
                if url.absoluteString.hasSuffix(".sig") {
                    return detachedSignature
                }
                return manifestData
            },
            download: { url, destination in
                await recorder?.recordDownload(url)
                guard let payload = payloads[url] else {
                    throw TestError.missingPayload(url)
                }
                try payload.write(to: destination, options: .atomic)
            }
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GlossRuntimeDistributionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var signingPrivateKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x2a, count: 32)
        )
    }

    private var signingPublicKey: Data {
        signingPrivateKey.publicKey.rawRepresentation
    }

    private func signature(for data: Data) -> Data {
        try! signingPrivateKey.signature(for: data)
    }

    private func signatureURL(for manifestURL: URL) -> URL {
        URL(string: "\(manifestURL.absoluteString).sig")!
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

private enum TestError: Error, Equatable {
    case missingPayload(URL)
    case offline
}

private actor URLRecorder {
    private(set) var fetchedURLs: [URL] = []
    private(set) var downloadedURLs: [URL] = []

    func recordFetch(_ url: URL) {
        fetchedURLs.append(url)
    }

    func recordDownload(_ url: URL) {
        downloadedURLs.append(url)
    }
}

private actor SnapshotCollector {
    private(set) var snapshots: [BabelDOCRuntimeSnapshot] = []

    func append(_ snapshot: BabelDOCRuntimeSnapshot) {
        snapshots.append(snapshot)
    }
}
