import Foundation

public enum TranslationProvider: String, CaseIterable, Codable, Sendable {
    case codex
    case llama

    public var displayName: String {
        switch self {
        case .codex:
            "GPT 订阅"
        case .llama:
            "本地模型"
        }
    }
}

public enum CodexReasoningEffort: String, CaseIterable, Codable, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    public var displayName: String {
        switch self {
        case .minimal:
            "最少（最低延迟）"
        case .low:
            "低（最快）"
        case .medium:
            "中"
        case .high:
            "高"
        case .xhigh:
            "超高"
        }
    }
}

public struct TranslationProviderConfiguration: Equatable, Sendable {
    public static let defaultCodexModel = "gpt-5.3-codex-spark"
    public static let defaultLlamaModel = "tencent/Hy-MT2-1.8B-GGUF:Q4_K_M"

    public let provider: TranslationProvider
    public let codexModel: String
    public let codexReasoningEffort: CodexReasoningEffort

    public init(
        provider: TranslationProvider = .codex,
        codexModel: String = Self.defaultCodexModel,
        codexReasoningEffort: CodexReasoningEffort = .low
    ) {
        self.provider = provider
        self.codexModel = codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.codexReasoningEffort = codexReasoningEffort
    }
}

public struct TranslationProviderStatus: Equatable, Sendable {
    public let provider: TranslationProvider
    public let model: String
    public let reasoningEffort: CodexReasoningEffort?
    public let configurationRevision: String
    public let isWarm: Bool

    public init(
        provider: TranslationProvider,
        model: String,
        reasoningEffort: CodexReasoningEffort? = nil,
        configurationRevision: String,
        isWarm: Bool
    ) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.configurationRevision = configurationRevision
        self.isWarm = isWarm
    }

    public var backendName: String {
        switch provider {
        case .codex: "codex-app-server"
        case .llama: "llama-server"
        }
    }
}

public actor TranslationBackendRouter: TranslationBackend {
    private var backend: any TranslationBackend

    public init(backend: any TranslationBackend) {
        self.backend = backend
    }

    public func use(_ backend: any TranslationBackend) {
        self.backend = backend
    }

    public func translate(_ request: TranslationBatchRequest) async throws -> [TranslationOutput] {
        let backend = self.backend
        return try await backend.translate(request)
    }

    public func translate(
        _ request: TranslationBatchRequest,
        onOutput: @escaping @Sendable (TranslationOutput) -> Void
    ) async throws -> [TranslationOutput] {
        let backend = self.backend
        return try await backend.translate(request, onOutput: onOutput)
    }
}
