import GlossCore
import XCTest

@testable import Gloss

private actor PDFLifecycleTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PDFLifecycleEventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func contains(_ event: String) -> Bool {
        events.contains(event)
    }
}

@MainActor
final class PDFRuntimeLifecycleTests: XCTestCase {
    func testRuntimeControllerSupportsIndependentStateStreams() async {
        let service = BabelDOCServiceSession(
            persistedStateDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let controller = PDFRuntimeController(
            service: service,
            runtimeManager: nil
        )
        var firstIterator = controller.stateChanges().makeAsyncIterator()
        var secondIterator = controller.stateChanges().makeAsyncIterator()

        let firstState = await firstIterator.next()
        let secondState = await secondIterator.next()

        XCTAssertNotNil(firstState)
        XCTAssertNotNil(secondState)
    }

    func testMaintenanceWaitsForCapturedModuleClose() async throws {
        let controller = PDFRuntimeController(
            service: BabelDOCServiceSession(
                persistedStateDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            runtimeManager: nil
        )
        let closeGate = PDFLifecycleTestGate()
        let events = PDFLifecycleEventRecorder()
        let closeStarted = expectation(description: "module close started")
        let closeTask = Task {
            closeStarted.fulfill()
            await closeGate.wait()
        }
        await fulfillment(of: [closeStarted], timeout: 1)

        let maintenanceTask = Task {
            try await controller.waitForModuleClose(closeTask, id: nil)
            await events.append("maintenance")
        }
        await Task.yield()
        let maintenanceStartedEarly = await events.contains("maintenance")
        XCTAssertFalse(maintenanceStartedEarly)

        await closeGate.open()
        try await maintenanceTask.value
        let maintenanceStarted = await events.contains("maintenance")
        XCTAssertTrue(maintenanceStarted)
    }

    func testNewBatchWaitsForCancelledBatchAndOldCompletionKeepsNewIdentity() async {
        let coordinator = PDFBatchTaskCoordinator()
        let firstGate = PDFLifecycleTestGate()
        let secondGate = PDFLifecycleTestGate()
        let events = PDFLifecycleEventRecorder()
        let firstStarted = expectation(description: "first batch started")
        let secondStarted = expectation(description: "second batch started")

        XCTAssertTrue(
            coordinator.start {
                await events.append("first")
                firstStarted.fulfill()
                await firstGate.wait()
            }
        )
        await fulfillment(of: [firstStarted], timeout: 1)

        coordinator.cancelAndDetach()
        XCTAssertTrue(
            coordinator.start {
                await events.append("second")
                secondStarted.fulfill()
                await secondGate.wait()
            }
        )
        XCTAssertTrue(coordinator.isActive)

        await Task.yield()
        let secondDidStartEarly = await events.contains("second")
        XCTAssertFalse(secondDidStartEarly)

        await firstGate.open()
        await fulfillment(of: [secondStarted], timeout: 1)
        XCTAssertTrue(coordinator.isActive)

        await secondGate.open()
        await coordinator.waitForTerminal()
        XCTAssertFalse(coordinator.isActive)
    }

    func testRuntimeMustBeIdleAndReadyBeforeStartingNewBatch() {
        let readyInfo = PDFRuntimeReadyInfo(
            endpoint: "http://127.0.0.1:49160",
            processIdentifier: 42,
            version: "0.6.4+gloss.3",
            executablePath: nil
        )

        XCTAssertTrue(
            PDFTranslationWindowController.runtimeAllowsNewBatch(.ready(readyInfo))
        )
        XCTAssertFalse(
            PDFTranslationWindowController.canStartBatch(
                runtimeState: .ready(readyInfo),
                serviceIsReady: true,
                maintenancePending: true
            )
        )
        XCTAssertFalse(
            PDFTranslationWindowController.canStartBatch(
                runtimeState: .ready(readyInfo),
                serviceIsReady: false,
                maintenancePending: false
            )
        )
        XCTAssertTrue(
            PDFTranslationWindowController.runtimeAllowsNewBatch(
                .updateAvailable(readyInfo, availableVersion: "0.6.4+gloss.4")
            )
        )
        XCTAssertFalse(
            PDFTranslationWindowController.runtimeAllowsNewBatch(
                .translating(readyInfo, fileName: "active.pdf", progress: 20)
            )
        )
        XCTAssertFalse(
            PDFTranslationWindowController.runtimeAllowsNewBatch(
                .installing(version: "0.6.4+gloss.4", progress: 40)
            )
        )
        XCTAssertFalse(
            PDFTranslationWindowController.runtimeAllowsNewBatch(
                .stopping(previousProcessIdentifier: 42)
            )
        )
    }

    func testIncompatibleManagedRuntimeConsumesVerifiedUpdateBeforeStarting() {
        let checked = runtimeSnapshot(
            currentVersion: "0.6.4+gloss.4",
            availableVersion: "0.6.4+gloss.5",
            updateAvailable: true,
            operation: .ready
        )

        XCTAssertEqual(
            PDFRuntimeController.managedRuntimePreparation(for: checked),
            .installAvailableUpdate
        )
    }

    func testCompatibleManagedRuntimeStartsWhileUpdateCheckRemainsAdvisory() {
        let checked = runtimeSnapshot(
            currentVersion: "0.6.4+gloss.5",
            availableVersion: "0.6.4+gloss.6",
            updateAvailable: true,
            operation: .ready
        )

        XCTAssertEqual(
            PDFRuntimeController.managedRuntimePreparation(for: checked),
            .startCurrent
        )
        XCTAssertEqual(
            PDFRuntimeController.compatibleManagedRuntimeLaunch(
                for: checked
            )?.source,
            "Gloss runtime 0.6.4+gloss.5"
        )
    }

    func testCompatibleManagedRuntimeRemainsAvailableOffline() {
        let offline = runtimeSnapshot(
            currentVersion: "0.6.4+gloss.5",
            availableVersion: nil,
            updateAvailable: false,
            operation: .failed
        )

        XCTAssertEqual(
            PDFRuntimeController.managedRuntimePreparation(for: offline),
            .startCurrent
        )
        XCTAssertTrue(
            PDFRuntimeController.isCompatibleManagedRuntimeVersion(
                "0.6.4+gloss.10"
            )
        )
    }

    func testMissingAndUnversionedManagedRuntimesCannotLaunch() {
        let missing = runtimeSnapshot(
            currentVersion: nil,
            availableVersion: nil,
            updateAvailable: false,
            operation: .idle,
            executableURL: nil
        )
        let unversioned = runtimeSnapshot(
            currentVersion: nil,
            availableVersion: nil,
            updateAvailable: false,
            operation: .ready
        )

        XCTAssertEqual(
            PDFRuntimeController.managedRuntimePreparation(for: missing),
            .install
        )
        XCTAssertEqual(
            PDFRuntimeController.managedRuntimePreparation(for: unversioned),
            .updateRequired(currentVersion: "未知版本")
        )
        XCTAssertNil(
            PDFRuntimeController.compatibleManagedRuntimeLaunch(for: missing)
        )
        XCTAssertNil(
            PDFRuntimeController.compatibleManagedRuntimeLaunch(for: unversioned)
        )
    }

    func testControllerDoesNotFallBackToUnverifiedExternalRuntime() {
        let controller = PDFRuntimeController(
            service: BabelDOCServiceSession(
                persistedStateDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            runtimeManager: nil
        )

        XCTAssertNil(controller.currentRuntimeLaunch)
    }

    func testIncompatibleManagedRuntimeRequiresUpdateWhenOffline() {
        let offline = runtimeSnapshot(
            currentVersion: "0.6.4+gloss.4",
            availableVersion: nil,
            updateAvailable: false,
            operation: .failed
        )

        XCTAssertEqual(
            PDFRuntimeController.managedRuntimePreparation(for: offline),
            .updateRequired(currentVersion: "0.6.4+gloss.4")
        )
        XCTAssertFalse(
            PDFRuntimeController.isCompatibleManagedRuntimeVersion(
                "0.6.4+gloss.4"
            )
        )
    }

    private func runtimeSnapshot(
        currentVersion: String?,
        availableVersion: String?,
        updateAvailable: Bool,
        operation: BabelDOCRuntimeOperation,
        executableURL: URL? = URL(
            fileURLWithPath: "/runtime/gloss-babeldoc"
        )
    ) -> BabelDOCRuntimeSnapshot {
        BabelDOCRuntimeSnapshot(
            channel: .stable,
            pinnedVersion: nil,
            currentVersion: currentVersion,
            previousVersion: nil,
            availableVersion: availableVersion,
            currentExecutableURL: executableURL,
            updateAvailable: updateAvailable,
            operation: operation,
            lastError: operation == .failed ? "offline" : nil
        )
    }
}
