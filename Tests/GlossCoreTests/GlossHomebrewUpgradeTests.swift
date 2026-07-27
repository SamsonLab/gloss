import CryptoKit
import Foundation
import Testing

@testable import GlossCore

@Suite("Gloss Homebrew upgrade helper")
struct GlossHomebrewUpgradeTests {
    private actor CommandPolicyRecorder {
        var updateTimeout: Duration?
        var upgradeTimeout: Duration?
        var upgradeEnvironment: [String: String]?

        func record(
            arguments: [String],
            environment: [String: String],
            timeout: Duration?
        ) {
            if arguments == GlossHomebrewUpgradeWorkflow.homebrewUpdateArguments {
                updateTimeout = timeout
            } else if arguments
                == GlossHomebrewUpgradeWorkflow.homebrewUpgradeArguments
            {
                upgradeTimeout = timeout
                upgradeEnvironment = environment
            }
        }
    }

    private actor Recorder {
        struct Invocation: Equatable, Sendable {
            let executableURL: URL
            let arguments: [String]
        }

        var invocations: [Invocation] = []
        var output: @Sendable (URL, [String]) -> GlossCommandOutput

        init(
            output:
                @escaping @Sendable (
                    URL,
                    [String]
                ) -> GlossCommandOutput
        ) {
            self.output = output
        }

        func run(
            executableURL: URL,
            arguments: [String]
        ) -> GlossCommandOutput {
            invocations.append(
                Invocation(
                    executableURL: executableURL,
                    arguments: arguments
                )
            )
            return output(executableURL, arguments)
        }
    }

    @Test("request and result stores round-trip their wire formats")
    func storesRoundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestURL = directory.appendingPathComponent("request.json")
        let resultURL = directory.appendingPathComponent("result.json")
        let request = makeRequest(resultURL: resultURL)
        let completedAt = Date(timeIntervalSince1970: 1_785_160_000)
        let result = GlossHomebrewUpgradeResult(
            outcome: .succeeded,
            expectedVersion: "0.8.3",
            installedVersion: "0.8.4",
            completedAt: completedAt
        )

        try GlossHomebrewUpgradeRequestStore.write(request, to: requestURL)
        try GlossHomebrewUpgradeResultStore.write(result, to: resultURL)

        #expect(
            try GlossHomebrewUpgradeRequestStore.load(from: requestURL)
                == request
        )
        #expect(
            try GlossHomebrewUpgradeResultStore.load(from: resultURL)
                == result
        )
    }

    @Test("workflow runs only the fixed Homebrew commands and relaunches")
    func workflowSucceeds() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resultURL = directory.appendingPathComponent("result.json")
        let request = makeRequest(resultURL: resultURL)
        let brewURL = request.brewExecutableURL
        let recorder = Recorder { _, _ in
            GlossCommandOutput(
                terminationStatus: 0,
                standardOutput: Data()
            )
        }
        let runner = GlossCommandRunner { executableURL, arguments in
            await recorder.run(
                executableURL: executableURL,
                arguments: arguments
            )
        }
        let workflow = GlossHomebrewUpgradeWorkflow(
            commandRunner: runner,
            parentProcessWaiter: GlossParentProcessWaiter { processID, timeout in
                #expect(processID == 98_765)
                #expect(timeout == .seconds(120))
            },
            recoveryManager: noOpRecoveryManager(),
            releaseBindingVerifier: GlossHomebrewReleaseBindingVerifier { _ in },
            verifier: GlossHomebrewUpgradeVerifier { _ in "0.8.4" },
            now: { Date(timeIntervalSince1970: 1_785_160_000) }
        )

        let result = try await workflow.runAndPersist(request)

        #expect(result.succeeded)
        #expect(result.installedVersion == "0.8.4")
        #expect(
            await recorder.invocations == [
                Recorder.Invocation(
                    executableURL: brewURL,
                    arguments: ["update", "--quiet"]
                ),
                Recorder.Invocation(
                    executableURL: brewURL,
                    arguments: [
                        "upgrade",
                        "--cask",
                        "--require-sha",
                        "sunchj/tap/gloss",
                    ]
                ),
                Recorder.Invocation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/open"),
                    arguments: ["/Applications/Gloss.app"]
                ),
            ]
        )
        #expect(
            try GlossHomebrewUpgradeResultStore.load(from: resultURL)
                == result
        )
    }

    @Test("a failed Homebrew command persists failure and reopens Gloss")
    func workflowPersistsFailureAndRelaunches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resultURL = directory.appendingPathComponent("result.json")
        let request = makeRequest(resultURL: resultURL)
        let recorder = Recorder { executableURL, arguments in
            if executableURL == request.brewExecutableURL,
                arguments == GlossHomebrewUpgradeWorkflow.homebrewUpgradeArguments
            {
                return GlossCommandOutput(
                    terminationStatus: 1,
                    standardOutput: Data(),
                    standardError: Data("upgrade failed".utf8)
                )
            }
            return GlossCommandOutput(
                terminationStatus: 0,
                standardOutput: Data()
            )
        }
        let runner = GlossCommandRunner { executableURL, arguments in
            await recorder.run(
                executableURL: executableURL,
                arguments: arguments
            )
        }
        let workflow = GlossHomebrewUpgradeWorkflow(
            commandRunner: runner,
            parentProcessWaiter: GlossParentProcessWaiter { _, _ in },
            recoveryManager: noOpRecoveryManager(),
            releaseBindingVerifier: GlossHomebrewReleaseBindingVerifier { _ in },
            verifier: GlossHomebrewUpgradeVerifier { _ in
                Issue.record("verifier must not run after a failed upgrade")
                return "0.8.3"
            },
            now: { Date(timeIntervalSince1970: 1_785_160_000) }
        )

        let result = try await workflow.runAndPersist(request)

        #expect(!result.succeeded)
        #expect(result.errorCode == "homebrew_upgrade_failed")
        #expect(
            await recorder.invocations.last
                == Recorder.Invocation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/open"),
                    arguments: ["/Applications/Gloss.app"]
                )
        )
        #expect(
            try GlossHomebrewUpgradeResultStore.load(from: resultURL)
                == result
        )
    }

    @Test("a damaged upgrade restores the validated previous App")
    func workflowRecordsSuccessfulRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = makeRequest(
            resultURL: directory.appendingPathComponent("result.json")
        )
        let runner = GlossCommandRunner { executableURL, arguments in
            if executableURL == request.brewExecutableURL,
                arguments == GlossHomebrewUpgradeWorkflow.homebrewUpgradeArguments
            {
                return GlossCommandOutput(
                    terminationStatus: 1,
                    standardOutput: Data()
                )
            }
            return GlossCommandOutput(
                terminationStatus: 0,
                standardOutput: Data()
            )
        }
        let workflow = GlossHomebrewUpgradeWorkflow(
            commandRunner: runner,
            parentProcessWaiter: GlossParentProcessWaiter { _, _ in },
            recoveryManager: GlossAppUpdateRecoveryManager(
                prepare: { _ in },
                restoreIfNeeded: { _ in true }
            ),
            releaseBindingVerifier: GlossHomebrewReleaseBindingVerifier { _ in },
            verifier: GlossHomebrewUpgradeVerifier { _ in "0.8.3" }
        )

        let result = try await workflow.runAndPersist(request)

        #expect(!result.succeeded)
        #expect(result.recoveredPreviousInstallation)
        #expect(result.recoveryError == nil)
        #expect(result.errorCode == "homebrew_upgrade_failed")
    }

    @Test("recovery failure is persisted and still attempts relaunch")
    func workflowRecordsRecoveryFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = makeRequest(
            resultURL: directory.appendingPathComponent("result.json")
        )
        let recorder = Recorder { executableURL, arguments in
            if executableURL == request.brewExecutableURL,
                arguments == GlossHomebrewUpgradeWorkflow.homebrewUpgradeArguments
            {
                return GlossCommandOutput(
                    terminationStatus: 1,
                    standardOutput: Data()
                )
            }
            return GlossCommandOutput(
                terminationStatus: 0,
                standardOutput: Data()
            )
        }
        let runner = GlossCommandRunner { executableURL, arguments in
            await recorder.run(
                executableURL: executableURL,
                arguments: arguments
            )
        }
        let workflow = GlossHomebrewUpgradeWorkflow(
            commandRunner: runner,
            parentProcessWaiter: GlossParentProcessWaiter { _, _ in },
            recoveryManager: GlossAppUpdateRecoveryManager(
                prepare: { _ in },
                restoreIfNeeded: { _ in
                    throw GlossHomebrewUpgradeError.recoveryFailed(
                        "backup unavailable"
                    )
                }
            ),
            releaseBindingVerifier: GlossHomebrewReleaseBindingVerifier { _ in },
            verifier: GlossHomebrewUpgradeVerifier { _ in "0.8.3" }
        )

        let result = try await workflow.runAndPersist(request)

        #expect(result.errorCode == "recovery_failed")
        #expect(result.recoveryError?.contains("backup unavailable") == true)
        #expect(
            await recorder.invocations.last
                == Recorder.Invocation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/open"),
                    arguments: ["/Applications/Gloss.app"]
                )
        )
    }

    @Test("brew commands are bounded and upgrade cannot implicitly update")
    func workflowPinsCommandPolicy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = makeRequest(
            resultURL: directory.appendingPathComponent("result.json")
        )
        let recorder = CommandPolicyRecorder()
        let runner = GlossCommandRunner(runWithTimeout: {
            _,
            arguments,
            environment,
            timeout in
            await recorder.record(
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
            return GlossCommandOutput(
                terminationStatus: 0,
                standardOutput: Data()
            )
        })
        let workflow = GlossHomebrewUpgradeWorkflow(
            commandRunner: runner,
            parentProcessWaiter: GlossParentProcessWaiter { _, _ in },
            recoveryManager: noOpRecoveryManager(),
            releaseBindingVerifier: GlossHomebrewReleaseBindingVerifier { _ in },
            verifier: GlossHomebrewUpgradeVerifier { _ in "0.8.3" },
            commandTimeout: .seconds(42)
        )

        #expect(try await workflow.runAndPersist(request).succeeded)
        #expect(await recorder.updateTimeout == .seconds(42))
        #expect(await recorder.upgradeTimeout == .seconds(42))
        #expect(
            await recorder.upgradeEnvironment
                == GlossHomebrewUpgradeWorkflow.noAutomaticUpdateEnvironment
        )
    }

    @Test("live verifier accepts the exact managed ad-hoc build")
    func liveVerifierAcceptsExactVersion() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let currentBundleURL = URL(fileURLWithPath: "/Applications/Gloss.app")
        let managedBundleURL = URL(
            fileURLWithPath: "/opt/homebrew/Caskroom/gloss/0.8.4/Gloss.app"
        )
        let resultURL = temporaryDirectory()
            .appendingPathComponent("result.json")
        let request = makeRequest(
            resultURL: resultURL,
            expectedVersion: "0.8.4"
        )
        #if arch(arm64)
            let runningArchitecture = "arm64"
        #else
            let runningArchitecture = "x86_64"
        #endif
        let recorder = Recorder { executableURL, arguments in
            switch (executableURL.path, arguments) {
            case (
                brewURL.path,
                GlossHomebrewInstallationDetector.infoArguments
            ):
                return GlossCommandOutput(
                    terminationStatus: 0,
                    standardOutput: Self.infoJSON(version: "0.8.4")
                )
            case (
                "/usr/bin/lipo",
                [
                    currentBundleURL
                        .appendingPathComponent("Contents/MacOS/Gloss").path,
                    "-verify_arch",
                    runningArchitecture,
                ]
            ):
                return GlossCommandOutput(
                    terminationStatus: 0,
                    standardOutput: Data()
                )
            case (
                "/usr/bin/codesign",
                ["--verify", "--deep", "--strict", currentBundleURL.path]
            ):
                return GlossCommandOutput(
                    terminationStatus: 0,
                    standardOutput: Data()
                )
            case (
                "/usr/bin/codesign",
                ["--display", "--verbose=4", currentBundleURL.path]
            ):
                return GlossCommandOutput(
                    terminationStatus: 0,
                    standardOutput: Data(),
                    standardError: Data(
                        "Executable=Gloss\nSignature=adhoc\n".utf8
                    )
                )
            case (
                "/usr/bin/xattr",
                [
                    "-p",
                    "com.apple.quarantine",
                    currentBundleURL.path,
                ]
            ):
                return GlossCommandOutput(
                    terminationStatus: 1,
                    standardOutput: Data(),
                    standardError: Data(
                        "No such xattr: com.apple.quarantine".utf8
                    )
                )
            default:
                return GlossCommandOutput(
                    terminationStatus: 127,
                    standardOutput: Data()
                )
            }
        }
        let runner = GlossCommandRunner { executableURL, arguments in
            await recorder.run(
                executableURL: executableURL,
                arguments: arguments
            )
        }
        let existingPaths = Set([
            brewURL.path,
            currentBundleURL.path,
            managedBundleURL.path,
        ])
        let verifier = GlossHomebrewUpgradeVerifier.live(
            commandRunner: runner,
            pathInspector: GlossPathInspector(
                isExecutable: { $0 == brewURL },
                fileExists: { existingPaths.contains($0.path) },
                pathsReferToSameItem: { first, second in
                    let canonical: [String: String] = [
                        currentBundleURL.path: currentBundleURL.path,
                        managedBundleURL.path: currentBundleURL.path,
                    ]
                    return (canonical[first.path] ?? first.path)
                        == (canonical[second.path] ?? second.path)
                }
            ),
            bundleVersionReader: GlossBundleVersionReader { _ in "0.8.4" }
        )

        #expect(try await verifier.verify(request) == "0.8.4")
        #expect(await recorder.invocations.count == 5)
    }

    @Test("post-upgrade verification requires the exact signed version")
    func postUpgradeVersionMustMatchExactly() {
        #expect(
            GlossHomebrewUpgradeVerifier.installedVersion(
                "0.8.3",
                matchesExpectedVersion: "0.8.3"
            )
        )
        #expect(
            !GlossHomebrewUpgradeVerifier.installedVersion(
                "0.8.4",
                matchesExpectedVersion: "0.8.3"
            )
        )
    }

    @Test("helper request rejects same-version updates and downgrades")
    func requestRequiresStrictlyNewerVersion() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for version in ["0.8.2", "0.8.1"] {
            let request = makeRequest(
                resultURL: directory.appendingPathComponent(
                    "\(version)-result.json"
                ),
                expectedVersion: version
            )
            #expect(throws: GlossHomebrewUpgradeError.self) {
                try request.validate()
            }
        }
    }

    @Test("signed cask and current architecture metadata bind before upgrade")
    func releaseBindingSucceeds() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository =
            directory
            .appendingPathComponent("sunchj/homebrew-tap", isDirectory: true)
        let caskURL = repository.appendingPathComponent("Casks/gloss.rb")
        let caskData = Data("trusted cask".utf8)
        try FileManager.default.createDirectory(
            at: caskURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try caskData.write(to: caskURL)
        let request = makeRequest(
            resultURL: directory.appendingPathComponent("result.json"),
            expectedHomebrewCaskSHA256: Self.sha256(caskData),
            expectedHomebrewCaskSize: Int64(caskData.count)
        )
        let runner = bindingRunner(
            repository: repository,
            version: request.expectedVersion,
            assetURL: request.expectedAssetURL,
            assetSHA256: request.expectedAssetSHA256
        )

        try await GlossHomebrewReleaseBindingVerifier.live(
            commandRunner: runner
        ).verify(request)
    }

    @Test("cask version URL and SHA mismatches fail closed")
    func releaseBindingRejectsMetadataMismatches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository =
            directory
            .appendingPathComponent("sunchj/homebrew-tap", isDirectory: true)
        let caskURL = repository.appendingPathComponent("Casks/gloss.rb")
        let caskData = Data("trusted cask".utf8)
        try FileManager.default.createDirectory(
            at: caskURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try caskData.write(to: caskURL)
        let request = makeRequest(
            resultURL: directory.appendingPathComponent("result.json"),
            expectedHomebrewCaskSHA256: Self.sha256(caskData),
            expectedHomebrewCaskSize: Int64(caskData.count)
        )
        let cases: [(String, URL, String)] = [
            ("0.8.4", request.expectedAssetURL, request.expectedAssetSHA256),
            (
                request.expectedVersion,
                URL(string: "https://attacker.example/Gloss.zip")!,
                request.expectedAssetSHA256
            ),
            (
                request.expectedVersion,
                request.expectedAssetURL,
                String(repeating: "c", count: 64)
            ),
        ]

        for (version, assetURL, assetSHA256) in cases {
            let verifier = GlossHomebrewReleaseBindingVerifier.live(
                commandRunner: bindingRunner(
                    repository: repository,
                    version: version,
                    assetURL: assetURL,
                    assetSHA256: assetSHA256
                )
            )
            await #expect(throws: GlossHomebrewUpgradeError.self) {
                try await verifier.verify(request)
            }
        }
    }

    @Test("tampered tap cask fails signed hash binding")
    func releaseBindingRejectsTamperedCask() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository =
            directory
            .appendingPathComponent("sunchj/homebrew-tap", isDirectory: true)
        let caskURL = repository.appendingPathComponent("Casks/gloss.rb")
        try FileManager.default.createDirectory(
            at: caskURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("tampered".utf8).write(to: caskURL)
        let request = makeRequest(
            resultURL: directory.appendingPathComponent("result.json"),
            expectedHomebrewCaskSHA256: Self.sha256(Data("trusted".utf8)),
            expectedHomebrewCaskSize: Int64(Data("trusted".utf8).count)
        )

        await #expect(throws: GlossHomebrewUpgradeError.self) {
            try await GlossHomebrewReleaseBindingVerifier.live(
                commandRunner: bindingRunner(
                    repository: repository,
                    version: request.expectedVersion,
                    assetURL: request.expectedAssetURL,
                    assetSHA256: request.expectedAssetSHA256
                )
            ).verify(request)
        }
    }

    @Test("tap cask must be a regular in-repository file")
    func releaseBindingRejectsSymlinkedCask() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository =
            directory
            .appendingPathComponent("sunchj/homebrew-tap", isDirectory: true)
        let caskURL = repository.appendingPathComponent("Casks/gloss.rb")
        let outsideURL = directory.appendingPathComponent("outside.rb")
        let caskData = Data("trusted cask".utf8)
        try FileManager.default.createDirectory(
            at: caskURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try caskData.write(to: outsideURL)
        try FileManager.default.createSymbolicLink(
            at: caskURL,
            withDestinationURL: outsideURL
        )
        let request = makeRequest(
            resultURL: directory.appendingPathComponent("result.json"),
            expectedHomebrewCaskSHA256: Self.sha256(caskData),
            expectedHomebrewCaskSize: Int64(caskData.count)
        )

        await #expect(throws: GlossHomebrewUpgradeError.self) {
            try await GlossHomebrewReleaseBindingVerifier.live(
                commandRunner: bindingRunner(
                    repository: repository,
                    version: request.expectedVersion,
                    assetURL: request.expectedAssetURL,
                    assetSHA256: request.expectedAssetSHA256
                )
            ).verify(request)
        }
    }

    @Test("helper independently reverifies the raw signed manifest")
    func signedRequestIsReverified() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resultURL = directory.appendingPathComponent("result.json")
        let request = makeRequest(resultURL: resultURL)
        let manifest = GlossAppReleaseManifest(
            version: request.expectedVersion,
            releaseTag: request.expectedReleaseTag,
            publishedAt: "2026-07-27T00:00:00Z",
            minimumMacOSVersion: "14.0",
            assets: ["arm64", "x86_64"].map { architecture in
                GlossAppReleaseManifest.Asset(
                    operatingSystem: "macos",
                    architecture: architecture,
                    url: URL(
                        string:
                            "https://github.com/SunChJ/gloss-releases/releases/download/\(request.expectedReleaseTag)/Gloss-macos-\(architecture).zip"
                    )!,
                    sha256: String(repeating: "a", count: 64),
                    size: 100
                )
            },
            homebrewCask: GlossAppReleaseManifest.HomebrewCask(
                url: request.expectedHomebrewCaskURL,
                sha256: request.expectedHomebrewCaskSHA256,
                size: request.expectedHomebrewCaskSize
            )
        )
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: request.manifestURL)
        try privateKey.signature(for: manifestData).write(
            to: request.manifestSignatureURL
        )

        try GlossSignedAppUpdateRequestVerifier(
            manifestSigningPublicKey: privateKey.publicKey.rawRepresentation
        ).verify(request)

        var tampered = manifestData
        tampered[tampered.startIndex] ^= 0x01
        try tampered.write(to: request.manifestURL)
        #expect(throws: GlossHomebrewUpgradeError.self) {
            try GlossSignedAppUpdateRequestVerifier(
                manifestSigningPublicKey:
                    privateKey.publicKey.rawRepresentation
            ).verify(request)
        }
    }

    @Test("readiness marker is required before the App can exit")
    func readinessHandshakeSucceedsAndRejectsEarlyExit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readinessURL = directory.appendingPathComponent("ready.json")
        let requestIdentifier = UUID()
        let processIdentifier =
            Int32(ProcessInfo.processInfo.processIdentifier)
        try GlossUpdateHelperReadinessStore.write(
            GlossUpdateHelperReadiness(
                requestIdentifier: requestIdentifier,
                helperProcessIdentifier: processIdentifier
            ),
            to: readinessURL
        )
        try await GlossUpdateHelperReadinessWaiter.live.wait(
            for: readinessURL,
            requestIdentifier: requestIdentifier,
            helperProcessIdentifier: processIdentifier,
            timeout: .seconds(1)
        )

        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        await #expect(throws: GlossHomebrewUpgradeError.helperExitedBeforeReady) {
            try await GlossUpdateHelperReadinessWaiter.live.wait(
                for: directory.appendingPathComponent("missing.json"),
                requestIdentifier: UUID(),
                helperProcessIdentifier: exited.processIdentifier,
                timeout: .seconds(1)
            )
        }
    }

    @Test("readiness and command execution have bounded timeouts")
    func helperAndCommandTimeouts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        helper.arguments = ["10"]
        try helper.run()
        await #expect(throws: GlossHomebrewUpgradeError.helperReadinessTimedOut) {
            try await GlossUpdateHelperReadinessWaiter.live.wait(
                for: directory.appendingPathComponent("missing.json"),
                requestIdentifier: UUID(),
                helperProcessIdentifier: helper.processIdentifier,
                timeout: .milliseconds(50)
            )
        }

        await #expect(throws: GlossCommandRunnerError.self) {
            try await GlossCommandRunner.live.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .milliseconds(50)
            )
        }
    }

    @Test("launcher stages an independent helper and canonical request")
    func launcherStagesHelper() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent(
            "AppUpdater",
            isDirectory: true
        )
        let resultURL = cacheURL.appendingPathComponent("latest-result.json")
        try FileManager.default.createDirectory(
            at: cacheURL,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: resultURL, options: .atomic)
        let installation = GlossHomebrewInstallation(
            brewExecutableURL: URL(
                fileURLWithPath: "/opt/homebrew/bin/brew"
            ),
            caskToken: "sunchj/tap/gloss",
            installedVersion: "0.8.2",
            availableVersion: "0.8.3",
            managedAppURL: URL(
                fileURLWithPath:
                    "/opt/homebrew/Caskroom/gloss/0.8.2/Gloss.app"
            ),
            installedAppTargetURL: URL(
                fileURLWithPath: "/Applications/Gloss.app"
            )
        )

        let launch = try await GlossAppUpdateHelperLauncher(
            readinessWaiter: GlossUpdateHelperReadinessWaiter {
                _,
                _,
                _,
                _ in
            }
        ).launch(
            bundledHelperURL: URL(fileURLWithPath: "/usr/bin/true"),
            installation: installation,
            update: updateAvailability(),
            parentProcessIdentifier: 98_765,
            currentBundleURL: URL(
                fileURLWithPath: "/Applications/Gloss.app"
            ),
            cacheRootURL: cacheURL,
            resultURL: resultURL
        )

        #expect(launch.processIdentifier > 1)
        #expect(
            FileManager.default.isExecutableFile(
                atPath:
                    launch.stagingDirectoryURL
                    .appendingPathComponent("gloss-update-helper").path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: resultURL.path))
        let request = try GlossHomebrewUpgradeRequestStore.load(
            from: launch.requestURL
        )
        #expect(request.expectedVersion == "0.8.3")
        #expect(request.resultPath == resultURL.path)
        #expect(request.expectedArchitecture == GlossAppArchitecture.current)
        #expect(
            try Data(contentsOf: request.manifestURL)
                == updateAvailability().manifestData
        )
    }

    private func makeRequest(
        resultURL: URL,
        expectedVersion: String = "0.8.3",
        expectedHomebrewCaskSHA256: String = String(
            repeating: "b",
            count: 64
        ),
        expectedHomebrewCaskSize: Int64 = 200
    ) -> GlossHomebrewUpgradeRequest {
        GlossHomebrewUpgradeRequest(
            brewExecutablePath: "/opt/homebrew/bin/brew",
            caskToken: "sunchj/tap/gloss",
            previousVersion: "0.8.2",
            expectedVersion: expectedVersion,
            expectedReleaseTag: "v\(expectedVersion)",
            expectedArchitecture: GlossAppArchitecture.current,
            expectedAssetURL: URL(
                string:
                    "https://github.com/SunChJ/gloss-releases/releases/download/v\(expectedVersion)/Gloss-macos-\(GlossAppArchitecture.current).zip"
            )!,
            expectedAssetSHA256: String(repeating: "a", count: 64),
            expectedAssetSize: 100,
            expectedHomebrewCaskURL: URL(
                string:
                    "https://github.com/SunChJ/gloss-releases/releases/download/v\(expectedVersion)/gloss.rb"
            )!,
            expectedHomebrewCaskSHA256: expectedHomebrewCaskSHA256,
            expectedHomebrewCaskSize: expectedHomebrewCaskSize,
            parentProcessIdentifier: 98_765,
            currentBundlePath: "/Applications/Gloss.app",
            resultPath: resultURL.path,
            readinessPath:
                resultURL.deletingLastPathComponent()
                .appendingPathComponent("ready.json").path,
            manifestPath:
                resultURL.deletingLastPathComponent()
                .appendingPathComponent("release-manifest.json").path,
            manifestSignaturePath:
                resultURL.deletingLastPathComponent()
                .appendingPathComponent("release-manifest.json.sig").path,
            recoveryBundlePath:
                resultURL.deletingLastPathComponent()
                .appendingPathComponent("recovery/Gloss.app").path
        )
    }

    private func updateAvailability() -> GlossAppUpdateAvailability {
        GlossAppUpdateAvailability(
            version: "0.8.3",
            releaseTag: "v0.8.3",
            publishedAt: Date(timeIntervalSince1970: 1_000),
            minimumMacOSVersion: "14.0",
            releasePageURL: URL(
                string:
                    "https://github.com/SunChJ/gloss-releases/releases/tag/v0.8.3"
            )!,
            architecture: GlossAppArchitecture.current,
            assetURL: URL(
                string:
                    "https://github.com/SunChJ/gloss-releases/releases/download/v0.8.3/Gloss-macos-\(GlossAppArchitecture.current).zip"
            )!,
            assetSHA256: String(repeating: "a", count: 64),
            assetSize: 100,
            homebrewCask: GlossAppReleaseManifest.HomebrewCask(
                url: URL(
                    string:
                        "https://github.com/SunChJ/gloss-releases/releases/download/v0.8.3/gloss.rb"
                )!,
                sha256: String(repeating: "b", count: 64),
                size: 200
            ),
            manifestData: Data("signed manifest".utf8),
            detachedSignatureData: Data("signature".utf8)
        )
    }

    private func noOpRecoveryManager() -> GlossAppUpdateRecoveryManager {
        GlossAppUpdateRecoveryManager(
            prepare: { _ in },
            restoreIfNeeded: { _ in false }
        )
    }

    private func bindingRunner(
        repository: URL,
        version: String,
        assetURL: URL,
        assetSHA256: String
    ) -> GlossCommandRunner {
        GlossCommandRunner { executableURL, arguments in
            guard executableURL.path == "/opt/homebrew/bin/brew" else {
                return GlossCommandOutput(
                    terminationStatus: 127,
                    standardOutput: Data()
                )
            }
            if arguments
                == GlossHomebrewReleaseBindingVerifier.repositoryArguments
            {
                return GlossCommandOutput(
                    terminationStatus: 0,
                    standardOutput: Data("\(repository.path)\n".utf8)
                )
            }
            if arguments == GlossHomebrewInstallationDetector.infoArguments {
                return GlossCommandOutput(
                    terminationStatus: 0,
                    standardOutput: Self.infoJSON(
                        version: version,
                        assetURL: assetURL,
                        assetSHA256: assetSHA256
                    )
                )
            }
            return GlossCommandOutput(
                terminationStatus: 127,
                standardOutput: Data()
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gloss-homebrew-upgrade-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private static func infoJSON(
        version: String,
        assetURL: URL? = nil,
        assetSHA256: String = String(repeating: "a", count: 64)
    ) -> Data {
        let resolvedAssetURL =
            assetURL
            ?? URL(
                string:
                    "https://github.com/SunChJ/gloss-releases/releases/download/v\(version)/Gloss-macos-\(GlossAppArchitecture.current).zip"
            )!
        return Data(
            """
            {
              "formulae": [],
              "casks": [
                {
                  "token": "gloss",
                  "full_token": "sunchj/tap/gloss",
                  "tap": "sunchj/tap",
                  "version": "\(version)",
                  "installed": "\(version)",
                  "url": "\(resolvedAssetURL.absoluteString)",
                  "sha256": "\(assetSHA256)",
                  "artifacts": [
                    {
                      "app": ["Gloss.app"],
                      "target": "/Applications/Gloss.app"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )
    }
}
