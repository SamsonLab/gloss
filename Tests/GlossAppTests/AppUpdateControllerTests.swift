import Foundation
import GlossCore
import XCTest

@testable import Gloss

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testAutomaticThrottleReturnsToIdleWithoutUserFacingFailure() async {
        let controller = makeController(
            check: { _ in
                .throttled(nextCheckAt: Date(timeIntervalSince1970: 2_000))
            }
        )

        await controller.check(mode: .automatic)

        XCTAssertEqual(
            controller.state,
            .idle(currentVersion: "0.8.2")
        )
    }

    func testManagedInstallIsOfferedAfterSignedUpdateDiscovery() async {
        let expectedInstallation = installation()
        let controller = makeController(
            check: { _ in .updateAvailable(self.updateAvailability()) },
            detect: { expectedInstallation }
        )

        await controller.check(mode: .manual)

        XCTAssertEqual(
            controller.state,
            .updateAvailable(
                updateAvailability(),
                delivery: .homebrew(expectedInstallation)
            )
        )
    }

    func testUnmanagedInstallOnlyOpensOfficialReleasePage() async {
        var openedURL: URL?
        let controller = makeController(
            check: { _ in .updateAvailable(self.updateAvailability()) },
            detect: { nil },
            openReleasePage: {
                openedURL = $0
                return true
            }
        )

        await controller.check(mode: .manual)
        await controller.performPrimaryAction()

        XCTAssertEqual(openedURL, updateAvailability().releasePageURL)
    }

    func testActivePDFDefersInstallWithoutLaunchingHelper() async {
        var helperLaunchCount = 0
        var terminationCount = 0
        let controller = makeController(
            check: { _ in .updateAvailable(self.updateAvailability()) },
            detect: { self.installation() },
            launch: { _, _ in helperLaunchCount += 1 },
            isPDFActive: { true },
            terminate: { terminationCount += 1 }
        )

        await controller.check(mode: .manual)
        await controller.performPrimaryAction()

        XCTAssertEqual(helperLaunchCount, 0)
        XCTAssertEqual(terminationCount, 0)
        guard case .blockedByBusinessTask = controller.state else {
            return XCTFail("Expected business-task blocked state")
        }
    }

    func testVerifiedHelperLaunchRequestsTermination() async {
        var launchedInstallation: GlossHomebrewInstallation?
        var launchedUpdate: GlossAppUpdateAvailability?
        var terminationCount = 0
        let controller = makeController(
            check: { _ in .updateAvailable(self.updateAvailability()) },
            detect: { self.installation() },
            launch: { installation, update in
                launchedInstallation = installation
                launchedUpdate = update
            },
            terminate: { terminationCount += 1 }
        )

        await controller.check(mode: .manual)
        await controller.performPrimaryAction()

        XCTAssertEqual(launchedInstallation, installation())
        XCTAssertEqual(launchedUpdate, updateAvailability())
        XCTAssertEqual(terminationCount, 1)
        XCTAssertEqual(
            controller.state,
            .preparingInstall(version: "0.8.3")
        )
    }

    func testUnsupportedMinimumSystemDoesNotInspectHomebrew() async {
        var detectionCount = 0
        let controller = makeController(
            check: { _ in .updateAvailable(self.updateAvailability(minimum: "15.0")) },
            detect: {
                detectionCount += 1
                return self.installation()
            },
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 14,
                minorVersion: 7,
                patchVersion: 0
            )
        )

        await controller.check(mode: .manual)

        XCTAssertEqual(detectionCount, 0)
        guard case .unavailable(_, let reason) = controller.state else {
            return XCTFail("Expected unavailable state")
        }
        XCTAssertTrue(reason.contains("macOS 15.0"))
    }

    func testSystemVersionComparisonUsesAllComponents() {
        XCTAssertTrue(
            AppUpdateController.supports(
                minimumMacOSVersion: "14.1",
                current: OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 1,
                    patchVersion: 0
                )
            )
        )
        XCTAssertFalse(
            AppUpdateController.supports(
                minimumMacOSVersion: "14.1.1",
                current: OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 1,
                    patchVersion: 0
                )
            )
        )
    }

    func testStagingCleanupRemovesOnlyTheScopedUpdaterDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "gloss-app-update-cleanup-\(UUID().uuidString)",
                isDirectory: true
            )
            .appendingPathComponent("AppUpdater", isDirectory: true)
        let staging = root.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        let helper =
            staging
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("gloss-update-helper")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: helper)
        defer {
            try? FileManager.default.removeItem(
                at: root.deletingLastPathComponent()
            )
        }

        try AppUpdateStagingCleaner.removeStagedHelpers(at: staging)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staging.path)
        )
        XCTAssertThrowsError(
            try AppUpdateStagingCleaner.removeStagedHelpers(
                at: root.deletingLastPathComponent()
            )
        ) { error in
            XCTAssertEqual(
                error as? AppUpdateStagingCleaner.CleanupError,
                .invalidDirectory
            )
        }
    }

    private func makeController(
        check:
            @escaping (GlossAppUpdateCheckMode) async throws
            -> GlossAppUpdateCheckResult,
        detect: @escaping () async throws -> GlossHomebrewInstallation? = {
            nil
        },
        launch:
            @escaping (
                GlossHomebrewInstallation,
                GlossAppUpdateAvailability
            ) async throws -> Void = { _, _ in },
        openReleasePage: @escaping (URL) -> Bool = { _ in true },
        isPDFActive: @escaping () -> Bool = { false },
        terminate: @escaping () -> Void = {},
        operatingSystemVersion: OperatingSystemVersion = OperatingSystemVersion(
            majorVersion: 14,
            minorVersion: 0,
            patchVersion: 0
        )
    ) -> AppUpdateController {
        AppUpdateController(
            currentVersion: "0.8.2",
            dependencies: AppUpdateController.Dependencies(
                check: check,
                detectHomebrewInstallation: detect,
                launchHomebrewUpdate: launch,
                openReleasePage: openReleasePage,
                isBusinessTaskActive: isPDFActive,
                requestApplicationTermination: terminate,
                operatingSystemVersion: { operatingSystemVersion }
            )
        )
    }

    private func updateAvailability(
        minimum: String = "14.0"
    ) -> GlossAppUpdateAvailability {
        GlossAppUpdateAvailability(
            version: "0.8.3",
            releaseTag: "v0.8.3",
            publishedAt: Date(timeIntervalSince1970: 1_000),
            minimumMacOSVersion: minimum,
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
            manifestData: Data("manifest".utf8),
            detachedSignatureData: Data("signature".utf8)
        )
    }

    private func installation() -> GlossHomebrewInstallation {
        GlossHomebrewInstallation(
            brewExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            caskToken: "sunchj/tap/gloss",
            installedVersion: "0.8.2",
            availableVersion: "0.8.2",
            managedAppURL: URL(
                fileURLWithPath:
                    "/opt/homebrew/Caskroom/gloss/0.8.2/Gloss.app"
            ),
            installedAppTargetURL: URL(
                fileURLWithPath: "/Applications/Gloss.app"
            )
        )
    }
}
