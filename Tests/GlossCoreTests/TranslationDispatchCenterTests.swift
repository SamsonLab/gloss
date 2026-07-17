import Foundation
import XCTest

@testable import GlossCore

final class TranslationDispatchCenterTests: XCTestCase {
    func testBackgroundJobsReserveCapacityForInteractiveWork() async throws {
        let backend = DispatchControlledBackend()
        let dispatchState = TranslationDispatchState()
        let center = TranslationDispatchCenter(
            backend: backend,
            configuration: .init(
                maximumConcurrentJobs: 3,
                maximumBackgroundJobs: 2
            ),
            dispatchState: dispatchState
        )

        let background1Request = Self.request(id: "background-1", priority: .background)
        let background1 = Task {
            try await center.translate(background1Request)
        }
        try await waitUntil { await backend.startedIDs() == ["background-1"] }
        let background2Request = Self.request(id: "background-2", priority: .background)
        let background2 = Task {
            try await center.translate(background2Request)
        }
        try await waitUntil {
            await backend.startedIDs() == ["background-1", "background-2"]
        }
        let background3Request = Self.request(id: "background-3", priority: .background)
        let background3 = Task {
            try await center.translate(background3Request)
        }
        try await waitUntil {
            let snapshot = await center.snapshot()
            return snapshot.pendingBackgroundJobs == 1
        }
        try await waitUntil {
            let snapshot = await dispatchState.snapshot()
            return snapshot.pendingBackgroundJobs == 1
                && !snapshot.allowsBackgroundHedge
        }

        let interactiveRequest = Self.request(id: "interactive", priority: .interactive)
        let interactive = Task {
            try await center.translate(interactiveRequest)
        }
        try await waitUntil {
            await backend.startedIDs()
                == ["background-1", "background-2", "interactive"]
        }
        let busySnapshot = await center.snapshot()
        XCTAssertEqual(busySnapshot.activeBackgroundJobs, 2)
        XCTAssertEqual(busySnapshot.activeInteractiveJobs, 1)
        XCTAssertEqual(busySnapshot.pendingBackgroundJobs, 1)

        await backend.complete(id: "interactive")
        _ = try await interactive.value
        let startsAfterInteractive = await backend.startedIDs()
        XCTAssertFalse(startsAfterInteractive.contains("background-3"))

        await backend.complete(id: "background-1")
        _ = try await background1.value
        try await waitUntil { await backend.startedIDs().contains("background-3") }

        await backend.complete(id: "background-2")
        await backend.complete(id: "background-3")
        _ = try await background2.value
        _ = try await background3.value
    }

    func testDispatchStateIncludesBabelDOCUpstreamBacklog() async throws {
        let backend = DispatchControlledBackend()
        let dispatchState = TranslationDispatchState()
        let center = TranslationDispatchCenter(
            backend: backend,
            configuration: .init(
                maximumConcurrentJobs: 1,
                maximumBackgroundJobs: 1
            ),
            dispatchState: dispatchState
        )
        let coordinator = BabelDOCBatchCoordinator(
            broker: TranslationBroker(backend: center),
            configuration: .init(
                maximumBatchItems: 1,
                maximumBatchCharacters: 100,
                maximumConcurrentBatches: 2,
                fillDelayNanoseconds: 0
            ),
            dispatchState: dispatchState
        )
        let items = [
            TranslationItem(id: "one", text: "one"),
            TranslationItem(id: "two", text: "two"),
            TranslationItem(id: "three", text: "three"),
        ]
        let translation = Task {
            try await coordinator.translate(
                items: items,
                targetLanguage: "Chinese (Simplified)",
                context: "PDF"
            )
        }

        try await waitUntil {
            let snapshot = await dispatchState.snapshot()
            return snapshot.pendingBackgroundJobs == 1
                && snapshot.upstreamBackgroundItems == 1
                && !snapshot.allowsBackgroundHedge
        }
        try await completeNextBackendRequest(backend)
        try await completeNextBackendRequest(backend)
        try await completeNextBackendRequest(backend)

        let outputs = try await translation.value
        XCTAssertEqual(outputs.map(\.id), items.map(\.id))
        try await waitUntil {
            let snapshot = await dispatchState.snapshot()
            return snapshot.pendingBackgroundJobs == 0
                && snapshot.upstreamBackgroundItems == 0
                && snapshot.allowsBackgroundHedge
        }
    }

    func testQueuedJobsRunByPriorityThenFIFO() async throws {
        let backend = DispatchControlledBackend()
        let center = TranslationDispatchCenter(
            backend: backend,
            configuration: .init(
                maximumConcurrentJobs: 1,
                maximumBackgroundJobs: 1
            )
        )

        let blockerRequest = Self.request(id: "blocker", priority: .background)
        let blocker = Task {
            try await center.translate(blockerRequest)
        }
        try await waitUntil { await backend.startedIDs() == ["blocker"] }

        let backgroundRequest = Self.request(id: "background", priority: .background)
        let background = Task {
            try await center.translate(backgroundRequest)
        }
        try await waitUntil { await center.snapshot().pendingJobs == 1 }
        let visibleRequest = Self.request(id: "visible", priority: .visible)
        let visible = Task {
            try await center.translate(visibleRequest)
        }
        try await waitUntil { await center.snapshot().pendingJobs == 2 }
        let interactiveRequest = Self.request(id: "interactive", priority: .interactive)
        let interactive = Task {
            try await center.translate(interactiveRequest)
        }
        try await waitUntil { await center.snapshot().pendingJobs == 3 }

        await backend.complete(id: "blocker")
        _ = try await blocker.value
        try await waitUntil {
            await backend.startedIDs() == ["blocker", "interactive"]
        }
        await backend.complete(id: "interactive")
        _ = try await interactive.value
        try await waitUntil {
            await backend.startedIDs() == ["blocker", "interactive", "visible"]
        }
        await backend.complete(id: "visible")
        _ = try await visible.value
        try await waitUntil {
            await backend.startedIDs()
                == ["blocker", "interactive", "visible", "background"]
        }
        await backend.complete(id: "background")
        _ = try await background.value
    }

    func testCancellingAQueuedJobRemovesItFromTheCenter() async throws {
        let backend = DispatchControlledBackend()
        let center = TranslationDispatchCenter(
            backend: backend,
            configuration: .init(
                maximumConcurrentJobs: 1,
                maximumBackgroundJobs: 1
            )
        )
        let blockerRequest = Self.request(id: "blocker", priority: .interactive)
        let blocker = Task {
            try await center.translate(blockerRequest)
        }
        try await waitUntil { await backend.startedIDs() == ["blocker"] }
        let queuedRequest = Self.request(id: "queued", priority: .background)
        let queued = Task {
            try await center.translate(queuedRequest)
        }
        try await waitUntil { await center.snapshot().pendingJobs == 1 }

        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("Expected queued dispatch work to be cancelled.")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let cancelledSnapshot = await center.snapshot()
        let startsAfterCancellation = await backend.startedIDs()
        XCTAssertEqual(cancelledSnapshot.pendingJobs, 0)
        XCTAssertFalse(startsAfterCancellation.contains("queued"))

        await backend.complete(id: "blocker")
        _ = try await blocker.value
    }

    private nonisolated static func request(
        id: String,
        priority: TranslationPriority
    ) -> TranslationBatchRequest {
        TranslationBatchRequest(
            items: [TranslationItem(id: id, text: id)],
            targetLanguage: "Chinese (Simplified)",
            priority: priority
        )
    }

    private func waitUntil(
        _ predicate: @escaping () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DispatchCenterTestError.timedOut
    }

    private func completeNextBackendRequest(
        _ backend: DispatchControlledBackend
    ) async throws {
        let completedCount = await backend.completedCount()
        try await waitUntil {
            await backend.startedIDs().count > completedCount
        }
        let started = await backend.startedIDs()
        await backend.complete(id: started[completedCount])
    }
}

private actor DispatchControlledBackend: TranslationBackend {
    private struct Pending {
        let request: TranslationBatchRequest
        let continuation: CheckedContinuation<[TranslationOutput], Error>
    }

    private var starts: [String] = []
    private var pendingByID: [String: Pending] = [:]
    private var completions = 0

    func translate(
        _ request: TranslationBatchRequest
    ) async throws -> [TranslationOutput] {
        let id = request.items[0].id
        starts.append(id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingByID[id] = Pending(
                    request: request,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func startedIDs() -> [String] {
        starts
    }

    func complete(id: String) {
        guard let pending = pendingByID.removeValue(forKey: id) else { return }
        completions += 1
        pending.continuation.resume(
            returning: pending.request.items.map {
                TranslationOutput(id: $0.id, text: "translated:\($0.text)")
            }
        )
    }

    private func cancel(id: String) {
        guard let pending = pendingByID.removeValue(forKey: id) else { return }
        pending.continuation.resume(throwing: CancellationError())
    }

    func completedCount() -> Int {
        completions
    }
}

private enum DispatchCenterTestError: Error {
    case timedOut
}
