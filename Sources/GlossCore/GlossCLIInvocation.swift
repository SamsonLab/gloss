import Foundation

public struct GlossCLITextOptions: Sendable {
    public let targetLanguage: String
    public let profile: TranslationProfile
    public let contentKind: TranslationContentKind
    public let provider: TranslationProvider
    public let model: String?
    public let reasoningEffort: CodexReasoningEffort
    public let textParts: [String]

    public init(
        targetLanguage: String,
        profile: TranslationProfile,
        contentKind: TranslationContentKind,
        provider: TranslationProvider,
        model: String?,
        reasoningEffort: CodexReasoningEffort,
        textParts: [String]
    ) {
        self.targetLanguage = targetLanguage
        self.profile = profile
        self.contentKind = contentKind
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.textParts = textParts
    }
}

public struct GlossCLIPDFOptions: Sendable {
    public let inputPaths: [String]
    public let outputDirectoryPath: String
    public let sourceLanguageCode: String
    public let targetLanguage: String
    public let outputMode: BabelDOCOutputMode
    public let provider: TranslationProvider
    public let model: String?
    public let reasoningEffort: CodexReasoningEffort

    public init(
        inputPaths: [String],
        outputDirectoryPath: String,
        sourceLanguageCode: String,
        targetLanguage: String,
        outputMode: BabelDOCOutputMode,
        provider: TranslationProvider,
        model: String?,
        reasoningEffort: CodexReasoningEffort
    ) {
        self.inputPaths = inputPaths
        self.outputDirectoryPath = outputDirectoryPath
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguage = targetLanguage
        self.outputMode = outputMode
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public enum GlossCLIInvocation: Sendable {
    case legacyText(GlossCLITextOptions)
    case text(GlossCLITextOptions)
    case browser(GlossCLITextOptions)
    case pdf(GlossCLIPDFOptions)
    case capabilitiesJSON
    case help(GlossCLICommand?)
}

public struct GlossCLIUsageError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum GlossCLIInvocationParser {
    public static func parse(
        _ arguments: [String],
        registry: GlossCapabilityRegistry = .current
    ) throws -> GlossCLIInvocation {
        guard let first = arguments.first,
            let command = GlossCLICommand(rawValue: first)
        else {
            if arguments.contains("--help") || arguments.contains("-h") {
                return .help(nil)
            }
            guard registry.isEnabled(.text) else {
                throw GlossCLIUsageError(
                    "旧式文本翻译入口所需的能力当前未启用。"
                )
            }
            return .legacyText(
                try parseTextOptions(arguments, scenario: nil)
            )
        }

        let remaining = Array(arguments.dropFirst())
        guard registry.isEnabled(command) else {
            throw GlossCLIUsageError(
                "\(command.rawValue) 命令所需的场景或能力当前未启用。"
            )
        }
        switch command {
        case .capabilities:
            if remaining == ["--json"] {
                return .capabilitiesJSON
            }
            if remaining == ["--help"] || remaining == ["-h"] {
                return .help(.capabilities)
            }
            throw GlossCLIUsageError(
                "capabilities 当前仅支持 --json。"
            )
        case .text:
            if remaining.contains("--help") || remaining.contains("-h") {
                return .help(.text)
            }
            return .text(
                try parseTextOptions(remaining, scenario: nil)
            )
        case .browser:
            if remaining.contains("--help") || remaining.contains("-h") {
                return .help(.browser)
            }
            return .browser(
                try parseTextOptions(
                    remaining,
                    scenario: .browserTranslation
                )
            )
        case .pdf:
            return try parsePDFOptions(remaining)
        }
    }

    private static func parseTextOptions(
        _ arguments: [String],
        scenario: GlossBusinessScenario?
    ) throws -> GlossCLITextOptions {
        var targetLanguage = "Chinese (Simplified)"
        var profile: TranslationProfile = .natural
        var contentKind: TranslationContentKind =
            scenario == .browserTranslation ? .webpage : .selection
        var provider: TranslationProvider = .codex
        var model: String?
        var reasoningEffort: CodexReasoningEffort = .low
        var textParts: [String] = []
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--target", "-t":
                targetLanguage = try requiredValue(
                    iterator.next(),
                    option: "--target",
                    description: "语言名称"
                )
            case "--profile", "-p":
                let value = try requiredValue(
                    iterator.next(),
                    option: "--profile",
                    description: "翻译风格"
                )
                guard let parsed = TranslationProfile(rawValue: value) else {
                    throw GlossCLIUsageError(
                        "--profile 可选 faithful、natural、technical、academic 或 subtitle。"
                    )
                }
                profile = parsed
            case "--kind", "-k":
                let value = try requiredValue(
                    iterator.next(),
                    option: "--kind",
                    description: "内容类型"
                )
                guard let parsed = TranslationContentKind(rawValue: value) else {
                    throw GlossCLIUsageError(
                        "--kind 可选 selection、webpage、document、subtitle 或 ocr。"
                    )
                }
                if scenario == .browserTranslation, parsed != .webpage {
                    throw GlossCLIUsageError(
                        "browser 场景的 --kind 必须是 webpage。"
                    )
                }
                contentKind = parsed
            case "--provider":
                provider = try parseProvider(iterator.next())
            case "--model":
                model = try requiredValue(
                    iterator.next(),
                    option: "--model",
                    description: "模型名称或 GGUF 路径"
                )
            case "--reasoning":
                reasoningEffort = try parseReasoning(iterator.next())
            case "--":
                while let text = iterator.next() {
                    textParts.append(text)
                }
            default:
                textParts.append(argument)
            }
        }

        return GlossCLITextOptions(
            targetLanguage: targetLanguage,
            profile: profile,
            contentKind: contentKind,
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
            textParts: textParts
        )
    }

    private static func parsePDFOptions(
        _ arguments: [String]
    ) throws -> GlossCLIInvocation {
        var inputPaths: [String] = []
        var outputDirectoryPath: String?
        var sourceLanguageCode = "en"
        var targetLanguage = "Chinese (Simplified)"
        var outputMode: BabelDOCOutputMode = .monolingual
        var provider: TranslationProvider = .codex
        var model: String?
        var reasoningEffort: CodexReasoningEffort = .low
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--output", "-o":
                outputDirectoryPath = try requiredValue(
                    iterator.next(),
                    option: "--output",
                    description: "输出目录"
                )
            case "--source":
                sourceLanguageCode = try requiredValue(
                    iterator.next(),
                    option: "--source",
                    description: "源语言代码"
                )
            case "--target", "-t":
                targetLanguage = try requiredValue(
                    iterator.next(),
                    option: "--target",
                    description: "语言名称"
                )
            case "--mode":
                let value = try requiredValue(
                    iterator.next(),
                    option: "--mode",
                    description: "输出模式"
                )
                switch value {
                case "mono", "monolingual":
                    outputMode = .monolingual
                case "dual", "bilingual":
                    outputMode = .bilingual
                default:
                    throw GlossCLIUsageError(
                        "--mode 可选 mono 或 bilingual。"
                    )
                }
            case "--provider":
                provider = try parseProvider(iterator.next())
            case "--model":
                model = try requiredValue(
                    iterator.next(),
                    option: "--model",
                    description: "模型名称或 GGUF 路径"
                )
            case "--reasoning":
                reasoningEffort = try parseReasoning(iterator.next())
            case "--help", "-h":
                return .help(.pdf)
            default:
                guard !argument.hasPrefix("-") else {
                    throw GlossCLIUsageError("未知的 pdf 选项：\(argument)")
                }
                inputPaths.append(argument)
            }
        }

        guard !inputPaths.isEmpty else {
            throw GlossCLIUsageError("pdf 需要至少一个 INPUT PDF 路径。")
        }
        guard let outputDirectoryPath else {
            throw GlossCLIUsageError("pdf 需要 --output DIR。")
        }
        guard isLanguageCode(sourceLanguageCode) else {
            throw GlossCLIUsageError("--source 需要有效的语言代码，例如 en。")
        }
        guard
            TranslationLanguages.babelDOCCode(
                forTargetName: targetLanguage
            ) != nil
        else {
            throw GlossCLIUsageError(
                "BabelDOC 暂不支持目标语言：\(targetLanguage)"
            )
        }

        return .pdf(
            GlossCLIPDFOptions(
                inputPaths: inputPaths,
                outputDirectoryPath: outputDirectoryPath,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguage: targetLanguage,
                outputMode: outputMode,
                provider: provider,
                model: model,
                reasoningEffort: reasoningEffort
            )
        )
    }

    private static func parseProvider(
        _ value: String?
    ) throws -> TranslationProvider {
        guard let value, let parsed = TranslationProvider(rawValue: value) else {
            throw GlossCLIUsageError("--provider 可选 codex 或 llama。")
        }
        return parsed
    }

    private static func parseReasoning(
        _ value: String?
    ) throws -> CodexReasoningEffort {
        guard let value, let parsed = CodexReasoningEffort(rawValue: value) else {
            throw GlossCLIUsageError(
                "--reasoning 可选 minimal、low、medium、high 或 xhigh。"
            )
        }
        return parsed
    }

    private static func requiredValue(
        _ value: String?,
        option: String,
        description: String
    ) throws -> String {
        guard let value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw GlossCLIUsageError("\(option) 需要\(description)。")
        }
        return value
    }

    private static func isLanguageCode(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z]{2,3}(?:-[A-Za-z]{2,4})?$"#,
            options: .regularExpression
        ) != nil
    }
}

public struct GlossCapabilitiesReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let availableCoreCapabilities: [GlossCapability]
    public let enabledCoreCapabilities: [GlossCapability]
    public let enabledCapabilities: [GlossCapability]
    public let availableScenarios: [GlossBusinessScenario]
    public let enabledScenarios: [GlossBusinessScenario]
    public let commandMappings: [GlossCLICommandMapping]

    public init(
        registry: GlossCapabilityRegistry = .current
    ) {
        schemaVersion = 1
        availableCoreCapabilities = registry.availableCoreCapabilities.sorted {
            $0.rawValue < $1.rawValue
        }
        enabledCoreCapabilities = registry.enabledCoreCapabilities.sorted {
            $0.rawValue < $1.rawValue
        }
        enabledCapabilities = registry.enabledCapabilities.sorted {
            $0.rawValue < $1.rawValue
        }
        availableScenarios = GlossBusinessScenario.allCases
            .filter(registry.isAvailable)
            .sorted {
                $0.rawValue < $1.rawValue
            }
        enabledScenarios = registry.enabledScenarios.sorted {
            $0.rawValue < $1.rawValue
        }
        commandMappings = registry.commandMappings.sorted {
            $0.command.rawValue < $1.command.rawValue
        }
    }
}
