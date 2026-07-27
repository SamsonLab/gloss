import Foundation
import Testing

@testable import GlossCore

@Suite("Gloss Homebrew installation detection")
struct GlossHomebrewInstallationTests {
    private actor RunnerRecorder {
        struct Invocation: Equatable, Sendable {
            let executableURL: URL
            let arguments: [String]
        }

        var outputs: [URL: GlossCommandOutput]
        var invocations: [Invocation] = []

        init(outputs: [URL: GlossCommandOutput]) {
            self.outputs = outputs
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
            return outputs[executableURL]
                ?? GlossCommandOutput(terminationStatus: 127, standardOutput: Data())
        }
    }

    @Test("detects an arm64 Homebrew-managed app from cask JSON")
    func detectsManagedArmInstallation() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let currentBundleURL = URL(fileURLWithPath: "/Applications/Gloss.app")
        let managedURL = URL(
            fileURLWithPath:
                "/opt/homebrew/Caskroom/gloss/0.8.2/Gloss.app"
        )
        let runner = RunnerRecorder(
            outputs: [
                brewURL: GlossCommandOutput(
                    terminationStatus: 0,
                    standardOutput: infoJSON()
                )
            ]
        )
        let detector = GlossHomebrewInstallationDetector(
            commandRunner: GlossCommandRunner { executableURL, arguments in
                await runner.run(
                    executableURL: executableURL,
                    arguments: arguments
                )
            },
            pathInspector: pathInspector(
                executableURLs: [brewURL],
                existingURLs: [currentBundleURL, managedURL],
                canonicalPaths: [
                    currentBundleURL.path: currentBundleURL.path,
                    managedURL.path: currentBundleURL.path,
                ]
            )
        )

        let installation = try #require(
            try await detector.detect(currentBundleURL: currentBundleURL)
        )

        #expect(installation.brewExecutableURL == brewURL)
        #expect(installation.caskToken == "sunchj/tap/gloss")
        #expect(installation.installedVersion == "0.8.2")
        #expect(installation.availableVersion == "0.8.10")
        #expect(installation.managedAppURL.path == managedURL.path)
        #expect(installation.installedAppTargetURL == currentBundleURL)
        #expect(
            await runner.invocations == [
                RunnerRecorder.Invocation(
                    executableURL: brewURL,
                    arguments: [
                        "info",
                        "--cask",
                        "--json=v2",
                        "sunchj/tap/gloss",
                    ]
                )
            ]
        )
    }

    @Test("only the two fixed Homebrew executable paths are eligible")
    func usesOnlyFixedBrewPaths() async throws {
        #expect(
            GlossHomebrewInstallationDetector.brewExecutableURLs.map(\.path)
                == [
                    "/opt/homebrew/bin/brew",
                    "/usr/local/bin/brew",
                ]
        )

        let runner = RunnerRecorder(outputs: [:])
        let detector = GlossHomebrewInstallationDetector(
            commandRunner: GlossCommandRunner { executableURL, arguments in
                await runner.run(
                    executableURL: executableURL,
                    arguments: arguments
                )
            },
            pathInspector: pathInspector(
                executableURLs: [
                    URL(fileURLWithPath: "/tmp/untrusted/bin/brew")
                ]
            )
        )

        #expect(
            try await detector.detect(
                currentBundleURL: URL(
                    fileURLWithPath: "/Applications/Gloss.app"
                )
            ) == nil
        )
        #expect(await runner.invocations.isEmpty)
    }

    @Test("falls back to the fixed Intel Homebrew path")
    func detectsManagedIntelInstallation() async throws {
        let brewURL = URL(fileURLWithPath: "/usr/local/bin/brew")
        let currentBundleURL = URL(fileURLWithPath: "/Applications/Gloss.app")
        let managedURL = URL(
            fileURLWithPath:
                "/usr/local/Caskroom/gloss/0.8.2/Gloss.app"
        )
        let runner = RunnerRecorder(
            outputs: [
                brewURL: GlossCommandOutput(
                    terminationStatus: 0,
                    standardOutput: infoJSON()
                )
            ]
        )
        let detector = GlossHomebrewInstallationDetector(
            commandRunner: GlossCommandRunner { executableURL, arguments in
                await runner.run(
                    executableURL: executableURL,
                    arguments: arguments
                )
            },
            pathInspector: pathInspector(
                executableURLs: [brewURL],
                existingURLs: [currentBundleURL, managedURL],
                canonicalPaths: [
                    currentBundleURL.path: currentBundleURL.path,
                    managedURL.path: currentBundleURL.path,
                ]
            )
        )

        let installation = try #require(
            try await detector.detect(currentBundleURL: currentBundleURL)
        )

        #expect(installation.brewExecutableURL == brewURL)
        #expect(installation.managedAppURL.path == managedURL.path)
    }

    @Test("malformed brew JSON fails explicitly")
    func rejectsMalformedJSON() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let detector = detector(
            brewURL: brewURL,
            output: GlossCommandOutput(
                terminationStatus: 0,
                standardOutput: Data("not JSON".utf8)
            )
        )

        await #expect(throws: GlossHomebrewDetectionError.malformedInfo) {
            try await detector.detect(
                currentBundleURL: URL(
                    fileURLWithPath: "/Applications/Gloss.app"
                )
            )
        }
    }

    @Test("foreign cask identity fails explicitly")
    func rejectsForeignCaskIdentity() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let foreignJSON = infoJSON(
            fullToken: "attacker/tap/gloss",
            tap: "attacker/tap"
        )
        let detector = detector(
            brewURL: brewURL,
            output: GlossCommandOutput(
                terminationStatus: 0,
                standardOutput: foreignJSON
            )
        )

        await #expect(
            throws: GlossHomebrewDetectionError.invalidCaskIdentity
        ) {
            try await detector.detect(
                currentBundleURL: URL(
                    fileURLWithPath: "/Applications/Gloss.app"
                )
            )
        }
    }

    @Test("a copied app is not treated as the Homebrew-managed instance")
    func rejectsNonManagedCopy() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let copiedBundleURL = URL(
            fileURLWithPath: "/Users/test/Applications/Gloss.app"
        )
        let installedTargetURL = URL(
            fileURLWithPath: "/Applications/Gloss.app"
        )
        let managedURL = URL(
            fileURLWithPath:
                "/opt/homebrew/Caskroom/gloss/0.8.2/Gloss.app"
        )
        let runner = RunnerRecorder(
            outputs: [
                brewURL: GlossCommandOutput(
                    terminationStatus: 0,
                    standardOutput: infoJSON()
                )
            ]
        )
        let detector = GlossHomebrewInstallationDetector(
            commandRunner: GlossCommandRunner { executableURL, arguments in
                await runner.run(
                    executableURL: executableURL,
                    arguments: arguments
                )
            },
            pathInspector: pathInspector(
                executableURLs: [brewURL],
                existingURLs: [
                    copiedBundleURL,
                    installedTargetURL,
                    managedURL,
                ],
                canonicalPaths: [
                    copiedBundleURL.path: copiedBundleURL.path,
                    installedTargetURL.path: installedTargetURL.path,
                    managedURL.path: installedTargetURL.path,
                ]
            )
        )

        #expect(
            try await detector.detect(currentBundleURL: copiedBundleURL) == nil
        )
    }

    @Test("an available but uninstalled cask is not a managed install")
    func ignoresUninstalledCask() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let detector = detector(
            brewURL: brewURL,
            output: GlossCommandOutput(
                terminationStatus: 0,
                standardOutput: infoJSON(installedVersion: nil)
            )
        )

        #expect(
            try await detector.detect(
                currentBundleURL: URL(
                    fileURLWithPath: "/Applications/Gloss.app"
                )
            ) == nil
        )
    }

    @Test("a failed brew info command does not claim ownership")
    func handlesBrewInfoFailure() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let detector = detector(
            brewURL: brewURL,
            output: GlossCommandOutput(
                terminationStatus: 1,
                standardOutput: Data(),
                standardError: Data("not installed".utf8)
            )
        )

        #expect(
            try await detector.detect(
                currentBundleURL: URL(
                    fileURLWithPath: "/Applications/Gloss.app"
                )
            ) == nil
        )
    }

    private func detector(
        brewURL: URL,
        output: GlossCommandOutput
    ) -> GlossHomebrewInstallationDetector {
        GlossHomebrewInstallationDetector(
            commandRunner: GlossCommandRunner { _, _ in output },
            pathInspector: pathInspector(
                executableURLs: [brewURL]
            )
        )
    }

    private func pathInspector(
        executableURLs: Set<URL> = [],
        existingURLs: Set<URL> = [],
        canonicalPaths: [String: String] = [:]
    ) -> GlossPathInspector {
        let executablePaths = Set(executableURLs.map(\.path))
        let existingPaths = Set(existingURLs.map(\.path))
        return GlossPathInspector(
            isExecutable: { executablePaths.contains($0.path) },
            fileExists: { existingPaths.contains($0.path) },
            pathsReferToSameItem: { first, second in
                let firstPath = canonicalPaths[first.path] ?? first.path
                let secondPath = canonicalPaths[second.path] ?? second.path
                return firstPath == secondPath
            }
        )
    }

    private func infoJSON(
        token: String = "gloss",
        fullToken: String = "sunchj/tap/gloss",
        tap: String = "sunchj/tap",
        version: String = "0.8.10",
        installedVersion: String? = "0.8.2"
    ) -> Data {
        let installedJSON = installedVersion.map { "\"\($0)\"" } ?? "null"
        return Data(
            """
            {
              "formulae": [],
              "casks": [
                {
                  "token": "\(token)",
                  "full_token": "\(fullToken)",
                  "tap": "\(tap)",
                  "version": "\(version)",
                  "installed": \(installedJSON),
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
