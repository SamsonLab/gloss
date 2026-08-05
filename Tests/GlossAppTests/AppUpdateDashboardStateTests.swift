import GlossCore
import XCTest

@testable import Gloss

final class AppUpdateDashboardStateTests: XCTestCase {
    func testManagedUpdateOffersHomebrewRestart() {
        let update = updateAvailability()
        let state = AppUpdateDashboardState.updateAvailable(
            update,
            delivery: .homebrew(installation())
        )

        XCTAssertEqual(state.action, .install)
        XCTAssertEqual(
            state.presentation.actionTitle,
            "更新并重新启动"
        )
        XCTAssertTrue(state.presentation.detail.contains("Homebrew"))
        XCTAssertEqual(
            state.menuPresentation.title,
            "更新 Gloss 到 0.8.3…"
        )
    }

    func testUnmanagedUpdateOnlyOffersOfficialReleasePage() {
        let state = AppUpdateDashboardState.updateAvailable(
            updateAvailability(),
            delivery: .releasePage
        )

        XCTAssertEqual(state.action, .openReleasePage)
        XCTAssertEqual(state.presentation.actionTitle, "查看下载")
        XCTAssertTrue(state.presentation.detail.contains("sunchj/tap/gloss"))
        XCTAssertEqual(
            state.menuPresentation.title,
            "下载 Gloss 0.8.3…"
        )
    }

    func testBusinessTaskBlockKeepsVerifiedInstallationForAutomaticContinuation() {
        let expectedInstallation = installation()
        let state = AppUpdateDashboardState.blockedByBusinessTask(
            updateAvailability(),
            installation: expectedInstallation
        )

        XCTAssertEqual(state.action, .install)
        XCTAssertEqual(state.presentation.headline, "等待当前翻译任务完成")
        XCTAssertFalse(state.presentation.actionEnabled)
        XCTAssertFalse(state.menuPresentation.isEnabled)
        XCTAssertTrue(state.presentation.detail.contains("自动安装"))
        XCTAssertTrue(state.menuPresentation.title.contains("0.8.3"))
        guard case .blockedByBusinessTask(_, let actualInstallation) = state else {
            return XCTFail("Expected blocked business-task state")
        }
        XCTAssertEqual(actualInstallation, expectedInstallation)
    }

    func testCheckingAndPreparingStatesDisableRepeatedActions() {
        let checking = AppUpdateDashboardState.checking(
            currentVersion: "0.8.2"
        )
        let preparing = AppUpdateDashboardState.preparingInstall(
            version: "0.8.3"
        )

        XCTAssertNil(checking.action)
        XCTAssertFalse(checking.presentation.actionEnabled)
        XCTAssertTrue(checking.presentation.showsProgress)
        XCTAssertNil(preparing.action)
        XCTAssertFalse(preparing.menuPresentation.isEnabled)
    }

    func testFailedHelperResultIsVisibleAndRetryableOnRelaunch() {
        let state = AppUpdateDashboardState.fromHomebrewResult(
            GlossHomebrewUpgradeResult(
                outcome: .failed,
                expectedVersion: "0.8.3",
                errorCode: "homebrew_upgrade_failed",
                message: "tap 尚未同步",
                completedAt: Date(timeIntervalSince1970: 2_000)
            ),
            currentVersion: "0.8.2"
        )

        XCTAssertEqual(
            state,
            .failed(
                currentVersion: "0.8.2",
                message: "tap 尚未同步"
            )
        )
        XCTAssertEqual(state.action, .check)
        XCTAssertEqual(state.presentation.actionTitle, "重试")
    }

    func testSuccessfulHelperResultUsesInstalledVersion() {
        let state = AppUpdateDashboardState.fromHomebrewResult(
            GlossHomebrewUpgradeResult(
                outcome: .succeeded,
                expectedVersion: "0.8.3",
                installedVersion: "0.8.4",
                completedAt: Date(timeIntervalSince1970: 2_000)
            ),
            currentVersion: "0.8.4"
        )

        XCTAssertEqual(
            state,
            .upToDate(
                currentVersion: "0.8.4",
                latestVersion: "0.8.4"
            )
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
