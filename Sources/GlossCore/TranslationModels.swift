import Foundation

public enum TranslationProfile: String, Codable, CaseIterable, Sendable {
    case faithful
    case natural
    case technical
    case academic
    case subtitle

    public var displayName: String {
        switch self {
        case .faithful: "忠实"
        case .natural: "自然"
        case .technical: "技术"
        case .academic: "学术"
        case .subtitle: "字幕"
        }
    }

    var instruction: String {
        switch self {
        case .faithful:
            "Stay close to the source meaning and structure without sounding mechanical."
        case .natural:
            "Write idiomatic, publication-ready target-language prose. Preserve every material fact without mirroring awkward source syntax."
        case .technical:
            "Prefer established technical terminology. Preserve identifiers, commands, code, and API names exactly."
        case .academic:
            "Use precise formal language and preserve qualifications, citations, and logical relationships."
        case .subtitle:
            "Use concise, speakable phrasing suitable for subtitles while preserving timing-friendly line breaks."
        }
    }
}

public enum TranslationContentKind: String, Codable, Sendable {
    case selection
    case webpage
    case document
    case subtitle
    case ocr
}

public struct TranslationItem: Codable, Hashable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct TranslationBatchRequest: Codable, Sendable {
    public let items: [TranslationItem]
    public let targetLanguage: String
    public let profile: TranslationProfile
    public let contentKind: TranslationContentKind
    public let context: String?

    public init(
        items: [TranslationItem],
        targetLanguage: String,
        profile: TranslationProfile = .natural,
        contentKind: TranslationContentKind = .selection,
        context: String? = nil
    ) {
        self.items = items
        self.targetLanguage = targetLanguage
        self.profile = profile
        self.contentKind = contentKind
        self.context = context
    }
}

public struct TranslationOutput: Codable, Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public protocol TranslationBackend: Sendable {
    func translate(_ request: TranslationBatchRequest) async throws -> [TranslationOutput]
}

public enum TranslationError: LocalizedError, Equatable, Sendable {
    case emptyInput
    case duplicateID(String)
    case invalidResponse(String)
    case backendUnavailable(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "没有可翻译的文本。"
        case .duplicateID(let id):
            "翻译请求包含重复标识：\(id)"
        case .invalidResponse(let reason):
            "翻译结果无效：\(reason)"
        case .backendUnavailable(let reason):
            "Gloss 无法启动翻译服务：\(reason)"
        case .timedOut(let operation):
            "翻译服务等待超时：\(operation)"
        }
    }
}
