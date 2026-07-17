import Foundation

public actor TranslationDispatchState {
    public struct Snapshot: Equatable, Sendable {
        public let pendingInteractiveJobs: Int
        public let pendingVisibleJobs: Int
        public let pendingBackgroundJobs: Int
        public let activeInteractiveJobs: Int
        public let activeVisibleJobs: Int
        public let activeBackgroundJobs: Int
        public let upstreamBackgroundItems: Int

        public var allowsBackgroundHedge: Bool {
            pendingInteractiveJobs == 0
                && pendingVisibleJobs == 0
                && pendingBackgroundJobs == 0
                && upstreamBackgroundItems == 0
        }
    }

    private var centerRevision = 0
    private var upstreamRevision = 0
    private var centerSnapshot = TranslationDispatchCenter.Snapshot(
        pendingInteractiveJobs: 0,
        pendingVisibleJobs: 0,
        pendingBackgroundJobs: 0,
        activeInteractiveJobs: 0,
        activeVisibleJobs: 0,
        activeBackgroundJobs: 0
    )
    private var upstreamBackgroundItems = 0

    public init() {}

    public func snapshot() -> Snapshot {
        Snapshot(
            pendingInteractiveJobs: centerSnapshot.pendingInteractiveJobs,
            pendingVisibleJobs: centerSnapshot.pendingVisibleJobs,
            pendingBackgroundJobs: centerSnapshot.pendingBackgroundJobs,
            activeInteractiveJobs: centerSnapshot.activeInteractiveJobs,
            activeVisibleJobs: centerSnapshot.activeVisibleJobs,
            activeBackgroundJobs: centerSnapshot.activeBackgroundJobs,
            upstreamBackgroundItems: upstreamBackgroundItems
        )
    }

    func reportCenter(
        _ snapshot: TranslationDispatchCenter.Snapshot,
        revision: Int
    ) {
        guard revision >= centerRevision else { return }
        centerRevision = revision
        centerSnapshot = snapshot
    }

    func reportUpstreamBackgroundItems(
        _ count: Int,
        revision: Int
    ) {
        guard revision >= upstreamRevision else { return }
        upstreamRevision = revision
        upstreamBackgroundItems = max(0, count)
    }
}

public actor TranslationDispatchCenter: TranslationBackend {
    public struct Configuration: Equatable, Sendable {
        public let maximumConcurrentJobs: Int
        public let maximumBackgroundJobs: Int

        public init(
            maximumConcurrentJobs: Int = 3,
            maximumBackgroundJobs: Int = 2
        ) {
            let maximumConcurrentJobs = max(1, maximumConcurrentJobs)
            self.maximumConcurrentJobs = maximumConcurrentJobs
            self.maximumBackgroundJobs = min(
                maximumConcurrentJobs,
                max(0, maximumBackgroundJobs)
            )
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let pendingInteractiveJobs: Int
        public let pendingVisibleJobs: Int
        public let pendingBackgroundJobs: Int
        public let activeInteractiveJobs: Int
        public let activeVisibleJobs: Int
        public let activeBackgroundJobs: Int

        public var pendingJobs: Int {
            pendingInteractiveJobs + pendingVisibleJobs + pendingBackgroundJobs
        }

        public var activeJobs: Int {
            activeInteractiveJobs + activeVisibleJobs + activeBackgroundJobs
        }
    }

    private struct PendingJob: Sendable {
        let id: UUID
        let sequence: Int
        let request: TranslationBatchRequest
        let onOutput: (@Sendable (TranslationOutput) -> Void)?
        let continuation: CheckedContinuation<[TranslationOutput], Error>
        let enqueuedAt: UInt64
    }

    private struct ActiveJob: Sendable {
        let job: PendingJob
        let task: Task<Void, Never>
        let startedAt: UInt64
    }

    private let backend: any TranslationBackend
    private let configuration: Configuration
    private let runtimeLog: GlossRuntimeLog
    private let dispatchState: TranslationDispatchState?
    private var pendingJobs: [PendingJob] = []
    private var activeJobs: [UUID: ActiveJob] = [:]
    private var nextSequence = 1
    private var dispatchStateRevision = 0

    public init(
        backend: any TranslationBackend,
        configuration: Configuration = Configuration(),
        runtimeLog: GlossRuntimeLog = .shared,
        dispatchState: TranslationDispatchState? = nil
    ) {
        self.backend = backend
        self.configuration = configuration
        self.runtimeLog = runtimeLog
        self.dispatchState = dispatchState
    }

    public func translate(
        _ request: TranslationBatchRequest
    ) async throws -> [TranslationOutput] {
        try await submit(request, onOutput: nil)
    }

    public func translate(
        _ request: TranslationBatchRequest,
        onOutput: @escaping @Sendable (TranslationOutput) -> Void
    ) async throws -> [TranslationOutput] {
        try await submit(request, onOutput: onOutput)
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            pendingInteractiveJobs: pendingCount(for: .interactive),
            pendingVisibleJobs: pendingCount(for: .visible),
            pendingBackgroundJobs: pendingCount(for: .background),
            activeInteractiveJobs: activeCount(for: .interactive),
            activeVisibleJobs: activeCount(for: .visible),
            activeBackgroundJobs: activeCount(for: .background)
        )
    }

    private func submit(
        _ request: TranslationBatchRequest,
        onOutput: (@Sendable (TranslationOutput) -> Void)?
    ) async throws -> [TranslationOutput] {
        let jobID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    id: jobID,
                    request: request,
                    onOutput: onOutput,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(jobID: jobID) }
        }
    }

    private func enqueue(
        id: UUID,
        request: TranslationBatchRequest,
        onOutput: (@Sendable (TranslationOutput) -> Void)?,
        continuation: CheckedContinuation<[TranslationOutput], Error>
    ) {
        let job = PendingJob(
            id: id,
            sequence: nextSequence,
            request: request,
            onOutput: onOutput,
            continuation: continuation,
            enqueuedAt: DispatchTime.now().uptimeNanoseconds
        )
        nextSequence += 1
        pendingJobs.append(job)
        runtimeLog.write(
            "dispatch",
            "enqueued priority=\(request.priority.rawValue) kind=\(request.contentKind.rawValue) pending=\(pendingJobs.count) active=\(activeJobs.count)"
        )
        dispatchAvailableJobs()
        reportState()
    }

    private func dispatchAvailableJobs() {
        while activeJobs.count < configuration.maximumConcurrentJobs,
            let pendingIndex = nextPendingJobIndex()
        {
            let job = pendingJobs.remove(at: pendingIndex)
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let backend = self.backend
            let task = Task {
                let result: Result<[TranslationOutput], Error>
                do {
                    if let onOutput = job.onOutput {
                        result = .success(
                            try await backend.translate(job.request, onOutput: onOutput)
                        )
                    } else {
                        result = .success(try await backend.translate(job.request))
                    }
                } catch {
                    result = .failure(error)
                }
                self.finish(jobID: job.id, result: result)
            }
            activeJobs[job.id] = ActiveJob(
                job: job,
                task: task,
                startedAt: startedAt
            )
            runtimeLog.write(
                "dispatch",
                "started priority=\(job.request.priority.rawValue) kind=\(job.request.contentKind.rawValue) queue_wait_ms=\(Self.elapsedMilliseconds(from: job.enqueuedAt, to: startedAt)) pending=\(pendingJobs.count) active=\(activeJobs.count) background_active=\(activeCount(for: .background))"
            )
        }
    }

    private func nextPendingJobIndex() -> Int? {
        let backgroundCapacityAvailable =
            activeCount(for: .background) < configuration.maximumBackgroundJobs
        var bestIndex: Int?
        for index in pendingJobs.indices {
            let job = pendingJobs[index]
            if job.request.priority == .background, !backgroundCapacityAvailable {
                continue
            }
            guard let currentBestIndex = bestIndex else {
                bestIndex = index
                continue
            }
            let currentBest = pendingJobs[currentBestIndex]
            if job.request.priority.rank > currentBest.request.priority.rank
                || (job.request.priority == currentBest.request.priority
                    && job.sequence < currentBest.sequence)
            {
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func finish(
        jobID: UUID,
        result: Result<[TranslationOutput], Error>
    ) {
        guard let activeJob = activeJobs.removeValue(forKey: jobID) else { return }
        let duration = Self.elapsedMilliseconds(since: activeJob.startedAt)
        switch result {
        case .success(let outputs):
            activeJob.job.continuation.resume(returning: outputs)
            runtimeLog.write(
                "dispatch",
                "completed priority=\(activeJob.job.request.priority.rawValue) kind=\(activeJob.job.request.contentKind.rawValue) duration_ms=\(duration) pending=\(pendingJobs.count) active=\(activeJobs.count)"
            )
        case .failure(let error):
            activeJob.job.continuation.resume(throwing: error)
            runtimeLog.write(
                "dispatch",
                "failed priority=\(activeJob.job.request.priority.rawValue) kind=\(activeJob.job.request.contentKind.rawValue) duration_ms=\(duration) error_type=\(String(reflecting: type(of: error))) pending=\(pendingJobs.count) active=\(activeJobs.count)"
            )
        }
        dispatchAvailableJobs()
        reportState()
    }

    private func cancel(jobID: UUID) {
        if let index = pendingJobs.firstIndex(where: { $0.id == jobID }) {
            let job = pendingJobs.remove(at: index)
            job.continuation.resume(throwing: CancellationError())
            runtimeLog.write(
                "dispatch",
                "cancelled stage=queued priority=\(job.request.priority.rawValue) pending=\(pendingJobs.count) active=\(activeJobs.count)"
            )
            reportState()
            return
        }
        guard let activeJob = activeJobs[jobID] else { return }
        activeJob.task.cancel()
        runtimeLog.write(
            "dispatch",
            "cancel_requested stage=active priority=\(activeJob.job.request.priority.rawValue) pending=\(pendingJobs.count) active=\(activeJobs.count)"
        )
    }

    private func reportState() {
        guard let dispatchState else { return }
        dispatchStateRevision += 1
        let revision = dispatchStateRevision
        let snapshot = snapshot()
        Task {
            await dispatchState.reportCenter(snapshot, revision: revision)
        }
    }

    private func pendingCount(for priority: TranslationPriority) -> Int {
        pendingJobs.lazy.filter { $0.request.priority == priority }.count
    }

    private func activeCount(for priority: TranslationPriority) -> Int {
        activeJobs.values.lazy.filter { $0.job.request.priority == priority }.count
    }

    private nonisolated static func elapsedMilliseconds(
        from start: UInt64,
        to end: UInt64
    ) -> Int {
        Int((end - min(start, end)) / 1_000_000)
    }

    private nonisolated static func elapsedMilliseconds(since start: UInt64) -> Int {
        elapsedMilliseconds(from: start, to: DispatchTime.now().uptimeNanoseconds)
    }
}
