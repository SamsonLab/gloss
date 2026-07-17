import Foundation

actor BabelDOCBatchCoordinator {
    struct Configuration: Sendable {
        let maximumBatchItems: Int
        let maximumBatchCharacters: Int
        let maximumConcurrentBatches: Int
        let fillDelayNanoseconds: UInt64
        let refillDelayNanoseconds: UInt64

        init(
            maximumBatchItems: Int = 12,
            maximumBatchCharacters: Int = 1_800,
            maximumConcurrentBatches: Int = 2,
            fillDelayNanoseconds: UInt64 = 25_000_000,
            refillDelayNanoseconds: UInt64 = 0
        ) {
            self.maximumBatchItems = max(1, maximumBatchItems)
            self.maximumBatchCharacters = max(1, maximumBatchCharacters)
            self.maximumConcurrentBatches = max(1, maximumConcurrentBatches)
            self.fillDelayNanoseconds = fillDelayNanoseconds
            self.refillDelayNanoseconds = refillDelayNanoseconds
        }

        init(
            environment: [String: String],
            defaults: Configuration = Configuration()
        ) {
            func integer(
                _ key: String,
                default defaultValue: Int,
                range: ClosedRange<Int>
            ) -> Int {
                guard let rawValue = environment[key],
                    let value = Int(rawValue),
                    range.contains(value)
                else { return defaultValue }
                return value
            }

            self.init(
                maximumBatchItems: integer(
                    "GLOSS_BABELDOC_BATCH_ITEMS",
                    default: defaults.maximumBatchItems,
                    range: 1...24
                ),
                maximumBatchCharacters: integer(
                    "GLOSS_BABELDOC_BATCH_CHARACTERS",
                    default: defaults.maximumBatchCharacters,
                    range: 200...4_000
                ),
                maximumConcurrentBatches: integer(
                    "GLOSS_BABELDOC_MODEL_CONCURRENCY",
                    default: defaults.maximumConcurrentBatches,
                    range: 1...4
                ),
                fillDelayNanoseconds: UInt64(
                    integer(
                        "GLOSS_BABELDOC_FILL_DELAY_MS",
                        default: Int(defaults.fillDelayNanoseconds / 1_000_000),
                        range: 0...2_000
                    )
                ) * 1_000_000,
                refillDelayNanoseconds: UInt64(
                    integer(
                        "GLOSS_BABELDOC_REFILL_DELAY_MS",
                        default: Int(defaults.refillDelayNanoseconds / 1_000_000),
                        range: 0...2_000
                    )
                ) * 1_000_000
            )
        }
    }

    private struct BatchKey: Hashable, Sendable {
        let targetLanguage: String
        let context: String
    }

    private struct PendingItem: Sendable {
        let requestID: UUID
        let key: BatchKey
        let originalID: String
        let brokerItem: TranslationItem
    }

    private struct RequestState {
        let itemIDs: [String]
        var remainingIDs: Set<String>
        var outputsByID: [String: String] = [:]
        let continuation: CheckedContinuation<[TranslationOutput], Error>
    }

    private let broker: TranslationBroker
    private let configuration: Configuration
    private let runtimeLog: GlossRuntimeLog
    private var pendingItems: [PendingItem] = []
    private var requests: [UUID: RequestState] = [:]
    private var cancelledBeforeEnqueue: Set<UUID> = []
    private var activeBatchCount = 0
    private var fillTask: Task<Void, Never>?

    init(
        broker: TranslationBroker,
        configuration: Configuration = Configuration(),
        runtimeLog: GlossRuntimeLog = .shared
    ) {
        self.broker = broker
        self.configuration = configuration
        self.runtimeLog = runtimeLog
    }

    func translate(
        items: [TranslationItem],
        targetLanguage: String,
        context: String
    ) async throws -> [TranslationOutput] {
        guard !items.isEmpty else { return [] }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    requestID: requestID,
                    items: items,
                    targetLanguage: targetLanguage,
                    context: context,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(requestID: requestID) }
        }
    }

    private func enqueue(
        requestID: UUID,
        items: [TranslationItem],
        targetLanguage: String,
        context: String,
        continuation: CheckedContinuation<[TranslationOutput], Error>
    ) {
        if cancelledBeforeEnqueue.remove(requestID) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }

        let itemIDs = items.map(\.id)
        requests[requestID] = RequestState(
            itemIDs: itemIDs,
            remainingIDs: Set(itemIDs),
            continuation: continuation
        )
        let key = BatchKey(targetLanguage: targetLanguage, context: context)
        pendingItems.append(
            contentsOf: items.enumerated().map { index, item in
                PendingItem(
                    requestID: requestID,
                    key: key,
                    originalID: item.id,
                    brokerItem: TranslationItem(
                        id: "\(requestID.uuidString)-\(index)",
                        text: item.text
                    )
                )
            }
        )
        runtimeLog.write(
            "bridge",
            "babeldoc_batch_enqueued request_items=\(items.count) pending_items=\(pendingItems.count) active_batches=\(activeBatchCount)"
        )
        schedule(
            force: firstPendingBatchIsFull(),
            delayNanoseconds: configuration.fillDelayNanoseconds,
            phase: "initial"
        )
    }

    private func cancel(requestID: UUID) {
        guard let state = requests.removeValue(forKey: requestID) else {
            cancelledBeforeEnqueue.insert(requestID)
            return
        }
        pendingItems.removeAll { $0.requestID == requestID }
        state.continuation.resume(throwing: CancellationError())
        runtimeLog.write(
            "bridge",
            "babeldoc_batch_cancelled remaining_items=\(state.remainingIDs.count) pending_items=\(pendingItems.count)"
        )
    }

    private func schedule(
        force: Bool,
        delayNanoseconds: UInt64,
        phase: String
    ) {
        guard activeBatchCount < configuration.maximumConcurrentBatches,
            !pendingItems.isEmpty
        else { return }

        if force {
            fillTask?.cancel()
            fillTask = nil
            dispatchAvailableBatches()
            return
        }

        guard fillTask == nil else { return }
        let delay = delayNanoseconds
        if delay > 0 {
            runtimeLog.write(
                "bridge",
                "babeldoc_batch_fill_wait phase=\(phase) delay_ms=\(delay / 1_000_000) pending_items=\(pendingItems.count) active_batches=\(activeBatchCount)"
            )
        }
        fillTask = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            self.flushFillWindow()
        }
    }

    private func flushFillWindow() {
        fillTask = nil
        dispatchAvailableBatches()
    }

    private func dispatchAvailableBatches() {
        while activeBatchCount < configuration.maximumConcurrentBatches,
            !pendingItems.isEmpty
        {
            let batch = takeNextBatch()
            guard !batch.isEmpty else { break }
            activeBatchCount += 1
            let characterCount = batch.reduce(0) { $0 + $1.brokerItem.text.count }
            let characterUtilization = min(
                100,
                characterCount * 100 / configuration.maximumBatchCharacters
            )
            runtimeLog.write(
                "bridge",
                "babeldoc_batch_dispatched items=\(batch.count) chars=\(characterCount) utilization_pct=\(characterUtilization) requests=\(Set(batch.map(\.requestID)).count) active_batches=\(activeBatchCount) pending_items=\(pendingItems.count)"
            )
            let broker = self.broker
            let key = batch[0].key
            Task {
                let result: Result<[TranslationOutput], Error>
                do {
                    result = .success(
                        try await broker.translate(
                            TranslationBatchRequest(
                                items: batch.map(\.brokerItem),
                                targetLanguage: key.targetLanguage,
                                profile: .academic,
                                contentKind: .document,
                                context: key.context,
                                priority: .background
                            )
                        )
                    )
                } catch {
                    result = .failure(error)
                }
                self.finish(batch: batch, result: result)
            }
        }
    }

    private func takeNextBatch() -> [PendingItem] {
        guard let first = pendingItems.first else { return [] }
        var selectedIndices = [0]
        var characterCount = first.brokerItem.text.count

        let candidates = pendingItems.indices.dropFirst()
            .filter { pendingItems[$0].key == first.key }
            .sorted { left, right in
                let leftCount = pendingItems[left].brokerItem.text.count
                let rightCount = pendingItems[right].brokerItem.text.count
                if leftCount == rightCount { return left < right }
                return leftCount > rightCount
            }

        for index in candidates {
            guard selectedIndices.count < configuration.maximumBatchItems else { break }
            let itemCharacters = pendingItems[index].brokerItem.text.count
            guard characterCount + itemCharacters <= configuration.maximumBatchCharacters else {
                continue
            }
            selectedIndices.append(index)
            characterCount += itemCharacters
        }

        selectedIndices.sort()
        let selected = selectedIndices.map { pendingItems[$0] }
        for index in selectedIndices.reversed() {
            pendingItems.remove(at: index)
        }
        return selected
    }

    private func firstPendingBatchIsFull() -> Bool {
        guard let first = pendingItems.first else { return false }
        var itemCount = 0
        var characterCount = 0
        for pending in pendingItems where pending.key == first.key {
            if itemCount >= configuration.maximumBatchItems
                || characterCount + pending.brokerItem.text.count
                    > configuration.maximumBatchCharacters
            {
                return true
            }
            itemCount += 1
            characterCount += pending.brokerItem.text.count
        }
        return itemCount >= configuration.maximumBatchItems
            || characterCount >= configuration.maximumBatchCharacters
    }

    private func finish(
        batch: [PendingItem],
        result: Result<[TranslationOutput], Error>
    ) {
        activeBatchCount -= 1
        switch result {
        case .success(let outputs):
            let outputsByID = Dictionary(
                outputs.map { ($0.id, $0.text) },
                uniquingKeysWith: { first, _ in first }
            )
            let requestIDs = Set(batch.map(\.requestID))
            for requestID in requestIDs {
                guard var state = requests[requestID] else { continue }
                let requestItems = batch.filter { $0.requestID == requestID }
                var missingOutput = false
                for pending in requestItems {
                    guard let text = outputsByID[pending.brokerItem.id] else {
                        missingOutput = true
                        break
                    }
                    state.outputsByID[pending.originalID] = text
                    state.remainingIDs.remove(pending.originalID)
                }
                if missingOutput {
                    fail(
                        requestID: requestID,
                        error: TranslationError.invalidResponse(
                            "BabelDOC batch returned an incomplete translation."
                        )
                    )
                } else if state.remainingIDs.isEmpty {
                    requests.removeValue(forKey: requestID)
                    let ordered = state.itemIDs.compactMap { itemID in
                        state.outputsByID[itemID].map {
                            TranslationOutput(id: itemID, text: $0)
                        }
                    }
                    if ordered.count == state.itemIDs.count {
                        state.continuation.resume(returning: ordered)
                    } else {
                        state.continuation.resume(
                            throwing: TranslationError.invalidResponse(
                                "BabelDOC batch lost a translated item."
                            )
                        )
                    }
                } else {
                    requests[requestID] = state
                }
            }
        case .failure(let error):
            for requestID in Set(batch.map(\.requestID)) {
                fail(requestID: requestID, error: error)
            }
        }

        if pendingItems.isEmpty {
            fillTask?.cancel()
            fillTask = nil
        } else {
            schedule(
                force: firstPendingBatchIsFull(),
                delayNanoseconds: configuration.refillDelayNanoseconds,
                phase: "refill"
            )
        }
    }

    private func fail(requestID: UUID, error: Error) {
        guard let state = requests.removeValue(forKey: requestID) else { return }
        pendingItems.removeAll { $0.requestID == requestID }
        state.continuation.resume(throwing: error)
    }
}
