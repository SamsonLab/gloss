import Foundation

public actor TranslationBroker {
    private struct CacheKey: Hashable, Sendable {
        let text: String
        let targetLanguage: String
        let profile: TranslationProfile
        let contentKind: TranslationContentKind
        let context: String?
    }

    private let backend: any TranslationBackend
    private let cacheLimit: Int
    private var cache: [CacheKey: String] = [:]
    private var cacheOrder: [CacheKey] = []
    private var inFlight: [CacheKey: Task<String, Error>] = [:]

    public init(backend: any TranslationBackend, cacheLimit: Int = 1_200) {
        self.backend = backend
        self.cacheLimit = max(0, cacheLimit)
    }

    public func translateText(
        _ text: String,
        targetLanguage: String,
        profile: TranslationProfile = .natural,
        contentKind: TranslationContentKind = .selection,
        context: String? = nil
    ) async throws -> String {
        let output = try await translate(
            TranslationBatchRequest(
                items: [TranslationItem(id: UUID().uuidString, text: text)],
                targetLanguage: targetLanguage,
                profile: profile,
                contentKind: contentKind,
                context: context
            )
        )
        guard let text = output.first?.text else {
            throw TranslationError.invalidResponse("后端没有返回结果。")
        }
        return text
    }

    public func translate(_ request: TranslationBatchRequest) async throws -> [TranslationOutput] {
        try validate(request)

        var cachedByID: [String: String] = [:]
        var keyByID: [String: CacheKey] = [:]
        var newKeys: Set<CacheKey> = []
        var newEntries: [(key: CacheKey, item: TranslationItem)] = []
        let cacheContext = request.contentKind == .webpage ? nil : request.context

        for item in request.items {
            let key = CacheKey(
                text: item.text,
                targetLanguage: request.targetLanguage,
                profile: request.profile,
                contentKind: request.contentKind,
                context: cacheContext
            )
            keyByID[item.id] = key

            if let value = cachedValue(for: key) {
                cachedByID[item.id] = value
            } else if inFlight[key] == nil, newKeys.insert(key).inserted {
                newEntries.append((key: key, item: item))
            }
        }

        if !newEntries.isEmpty {
            let entries = newEntries
            let backendRequest = TranslationBatchRequest(
                items: entries.map(\.item),
                targetLanguage: request.targetLanguage,
                profile: request.profile,
                contentKind: request.contentKind,
                context: request.context
            )
            let backend = self.backend
            let batchTask = Task<[String: String], Error> {
                let outputs = try await backend.translate(backendRequest)
                var outputMap: [String: String] = [:]
                for output in outputs {
                    guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TranslationError.invalidResponse("后端返回了空译文：\(output.id)")
                    }
                    guard outputMap.updateValue(output.text, forKey: output.id) == nil else {
                        throw TranslationError.invalidResponse("后端返回了重复 id：\(output.id)")
                    }
                }
                guard outputMap.count == entries.count else {
                    throw TranslationError.invalidResponse("返回数量与请求数量不一致。")
                }
                return outputMap
            }

            for entry in entries {
                let itemID = entry.item.id
                inFlight[entry.key] = Task<String, Error> {
                    let outputMap = try await batchTask.value
                    guard let value = outputMap[itemID] else {
                        throw TranslationError.invalidResponse("缺少项目 \(itemID)。")
                    }
                    return value
                }
            }
        }

        let pending = request.items.compactMap { item -> (TranslationItem, CacheKey, Task<String, Error>)? in
            guard cachedByID[item.id] == nil,
                let key = keyByID[item.id],
                let task = inFlight[key]
            else { return nil }
            return (item, key, task)
        }

        var translatedByID = cachedByID
        do {
            for (item, key, task) in pending {
                let value = try await task.value
                translatedByID[item.id] = value
                remember(value, for: key)
                inFlight.removeValue(forKey: key)
            }
        } catch {
            for (_, key, _) in pending {
                inFlight.removeValue(forKey: key)
            }
            throw error
        }

        return try request.items.map { item in
            guard let value = translatedByID[item.id] else {
                throw TranslationError.invalidResponse("缺少项目 \(item.id)。")
            }
            return TranslationOutput(id: item.id, text: value)
        }
    }

    public func clearCache() {
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    public func cacheCount() -> Int {
        cache.count
    }

    private func validate(_ request: TranslationBatchRequest) throws {
        let targetLanguage = request.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.items.isEmpty,
            !targetLanguage.isEmpty
        else {
            throw TranslationError.emptyInput
        }
        guard TranslationLanguages.isValidTargetName(targetLanguage) else {
            throw TranslationError.invalidResponse("目标语言名称无效。")
        }
        guard (request.context?.count ?? 0) <= 4_000 else {
            throw TranslationError.invalidResponse("上下文不能超过 4,000 个字符。")
        }

        var ids: Set<String> = []
        for item in request.items {
            guard !item.id.isEmpty,
                item.id.count <= 256,
                !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw TranslationError.emptyInput
            }
            guard item.text.count <= 20_000 else {
                throw TranslationError.invalidResponse("单段文本不能超过 20,000 个字符。")
            }
            guard ids.insert(item.id).inserted else {
                throw TranslationError.duplicateID(item.id)
            }
        }
    }

    private func cachedValue(for key: CacheKey) -> String? {
        guard let value = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return value
    }

    private func remember(_ value: String, for key: CacheKey) {
        guard cacheLimit > 0 else { return }
        cache[key] = value
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)

        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
