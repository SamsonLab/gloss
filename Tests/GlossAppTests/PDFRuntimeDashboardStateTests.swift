import GlossCore
import XCTest

@testable import Gloss

final class PDFRuntimeDashboardStateTests: XCTestCase {
    func testReadyStateShowsVerifiedRuntimeIdentityAndReconnect() {
        let state = PDFRuntimeDashboardState.ready(
            PDFRuntimeReadyInfo(
                endpoint: "http://127.0.0.1:49160",
                processIdentifier: 42,
                version: "0.6.4+gloss.3",
                executablePath: "/Applications/Gloss.app/Contents/Resources/gloss-babeldoc"
            )
        )

        XCTAssertTrue(state.isReady)
        XCTAssertEqual(state.action, .reconnect)
        XCTAssertEqual(state.presentation.headline, "PDF 服务已就绪")
        XCTAssertTrue(state.presentation.detail.contains("PID 42"))
        XCTAssertTrue(state.presentation.detail.contains("0.6.4+gloss.3"))
        XCTAssertFalse(state.presentation.actionIsDestructive)
    }

    func testTranslatingStateMakesOnlyTaskCancellationDestructive() {
        let info = PDFRuntimeReadyInfo(
            endpoint: "http://127.0.0.1:49160",
            processIdentifier: 42,
            version: "0.6.4+gloss.3",
            executablePath: nil
        )
        let state = PDFRuntimeDashboardState.translating(
            info,
            fileName: "paper.pdf",
            progress: 37
        )

        XCTAssertEqual(state.action, .cancel)
        XCTAssertEqual(state.presentation.actionTitle, "停止任务")
        XCTAssertTrue(state.presentation.actionIsDestructive)
        XCTAssertTrue(state.presentation.detail.contains("37%"))
        XCTAssertTrue(state.presentation.showsProgress)
    }

    func testInstallUpdateFailureAndRollbackHaveDistinctActions() {
        XCTAssertEqual(PDFRuntimeDashboardState.notInstalled.action, .install)
        XCTAssertEqual(
            PDFRuntimeDashboardState.failed(
                message: "健康检查失败",
                installedVersion: "0.6.4+gloss.3",
                canRollback: false
            ).action,
            .reconnect
        )
        XCTAssertEqual(
            PDFRuntimeDashboardState.failed(
                message: "更新后无法启动",
                installedVersion: "0.6.4+gloss.3",
                canRollback: true
            ).action,
            .rollback
        )
    }

    func testReconnectingExplainsVerifiedOldProcessCleanup() {
        let state = PDFRuntimeDashboardState.reconnecting(
            previousProcessIdentifier: 314
        )

        XCTAssertNil(state.action)
        XCTAssertTrue(state.presentation.detail.contains("PID 314"))
        XCTAssertFalse(state.presentation.actionEnabled)
        XCTAssertTrue(state.presentation.showsProgress)
    }

    func testStoppingDisablesRepeatedActions() {
        let state = PDFRuntimeDashboardState.stopping(
            previousProcessIdentifier: 314
        )

        XCTAssertNil(state.action)
        XCTAssertTrue(state.presentation.detail.contains("PID 314"))
        XCTAssertFalse(state.presentation.actionEnabled)
        XCTAssertTrue(state.presentation.showsProgress)
    }

    func testInstalledRuntimeCanBeUninstalledOnlyFromStableStates() {
        let info = PDFRuntimeReadyInfo(
            endpoint: "http://127.0.0.1:49160",
            processIdentifier: 42,
            version: "1.0.0",
            executablePath: "/runtime/gloss-babeldoc"
        )
        XCTAssertTrue(PDFRuntimeDashboardState.ready(info).hasInstalledRuntime)
        XCTAssertTrue(PDFRuntimeDashboardState.ready(info).canRequestUninstall)
        XCTAssertFalse(
            PDFRuntimeDashboardState.translating(
                info,
                fileName: "paper.pdf",
                progress: 20
            ).canRequestUninstall
        )
        XCTAssertEqual(
            PDFRuntimeDashboardState.uninstalling.presentation.actionTitle,
            "正在卸载…"
        )
        XCTAssertFalse(PDFRuntimeDashboardState.notInstalled.hasInstalledRuntime)
    }

    func testControllerMapsMissingRuntimeToAutomaticInstall() {
        let state = PDFRuntimeController.dashboardState(
            runtime: nil,
            service: BabelDOCExecutorServiceSnapshot(
                installed: false,
                lifecycleState: .stopped
            ),
            activeDocumentName: nil,
            fallbackRuntimeAvailable: false
        )

        XCTAssertEqual(state, .notInstalled)
        XCTAssertEqual(state.action, .install)
    }

    func testControllerMapsAuthenticatedServiceAndTaskProgress() {
        let runtime = BabelDOCRuntimeSnapshot(
            channel: .stable,
            pinnedVersion: nil,
            currentVersion: "0.6.4+gloss.3",
            previousVersion: "0.6.4+gloss.2",
            availableVersion: "0.6.4+gloss.3",
            currentExecutableURL: URL(fileURLWithPath: "/runtime/gloss-babeldoc"),
            updateAvailable: false,
            operation: .ready,
            lastError: nil
        )
        let service = BabelDOCExecutorServiceSnapshot(
            installed: true,
            runtimeVersion: "0.6.4+gloss.3",
            endpoint: URL(string: "http://127.0.0.1:49160"),
            processIdentifier: 42,
            processStartTime: 123,
            instanceID: "instance",
            lifecycleState: .ready,
            activeTaskID: "task-1",
            activeExecutionID: "execution-1",
            activeStatus: "running",
            activeProgress: 37,
            lastError: nil
        )

        let state = PDFRuntimeController.dashboardState(
            runtime: runtime,
            service: service,
            activeDocumentName: "paper.pdf",
            fallbackRuntimeAvailable: false
        )

        guard case .translating(let info, let fileName, let progress) = state else {
            return XCTFail("Expected translating state, got \(state)")
        }
        XCTAssertEqual(info.processIdentifier, 42)
        XCTAssertEqual(fileName, "paper.pdf")
        XCTAssertEqual(progress, 37)
    }

    func testControllerSurfacesAvailableRuntimeUpdate() {
        let runtime = BabelDOCRuntimeSnapshot(
            channel: .stable,
            pinnedVersion: nil,
            currentVersion: "0.6.4+gloss.2",
            previousVersion: nil,
            availableVersion: "0.6.4+gloss.3",
            currentExecutableURL: URL(fileURLWithPath: "/runtime/gloss-babeldoc"),
            updateAvailable: true,
            operation: .ready,
            lastError: nil
        )
        let service = BabelDOCExecutorServiceSnapshot(
            installed: true,
            runtimeVersion: "0.6.4+gloss.2",
            endpoint: URL(string: "http://127.0.0.1:49160"),
            processIdentifier: 42,
            lifecycleState: .ready
        )

        let state = PDFRuntimeController.dashboardState(
            runtime: runtime,
            service: service,
            activeDocumentName: nil,
            fallbackRuntimeAvailable: false
        )

        XCTAssertEqual(state.action, .update)
        XCTAssertTrue(state.presentation.detail.contains("0.6.4+gloss.3"))
    }

    func testServiceFailureReconnectsBeforeOfferingRuntimeRollback() {
        let runtime = BabelDOCRuntimeSnapshot(
            channel: .stable,
            pinnedVersion: nil,
            currentVersion: "0.6.4+gloss.3",
            previousVersion: "0.6.4+gloss.2",
            availableVersion: "0.6.4+gloss.3",
            currentExecutableURL: URL(fileURLWithPath: "/runtime/gloss-babeldoc"),
            updateAvailable: false,
            operation: .ready,
            lastError: nil
        )
        let service = BabelDOCExecutorServiceSnapshot(
            installed: true,
            runtimeVersion: "0.6.4+gloss.3",
            lifecycleState: .failed,
            lastError: "端口健康检查失败"
        )

        let state = PDFRuntimeController.dashboardState(
            runtime: runtime,
            service: service,
            activeDocumentName: nil,
            fallbackRuntimeAvailable: false
        )

        XCTAssertEqual(state.action, .reconnect)
        XCTAssertEqual(state.presentation.actionTitle, "重新连接")
    }
}
