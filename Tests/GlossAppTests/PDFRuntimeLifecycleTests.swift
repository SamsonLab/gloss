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
}
