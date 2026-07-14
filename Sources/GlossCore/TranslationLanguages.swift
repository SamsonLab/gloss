import Foundation
import NaturalLanguage

public struct TranslationLanguage: Hashable, Sendable {
    public let title: String
    public let targetName: String
    public let languageCode: String
    public let shortTitle: String

    public init(
        title: String,
        targetName: String,
        languageCode: String,
        shortTitle: String
    ) {
        self.title = title
        self.targetName = targetName
        self.languageCode = languageCode
        self.shortTitle = shortTitle
    }
}

public enum TranslationLanguages {
    public static let common: [TranslationLanguage] = [
        TranslationLanguage(
            title: "简体中文",
            targetName: "Chinese (Simplified)",
            languageCode: "zh-Hans",
            shortTitle: "中文"
        ),
        TranslationLanguage(
            title: "繁體中文",
            targetName: "Chinese (Traditional)",
            languageCode: "zh-Hant",
            shortTitle: "繁中"
        ),
        TranslationLanguage(
            title: "English",
            targetName: "English",
            languageCode: "en",
            shortTitle: "英文"
        ),
        TranslationLanguage(
            title: "日本語",
            targetName: "Japanese",
            languageCode: "ja",
            shortTitle: "日文"
        ),
        TranslationLanguage(
            title: "한국어",
            targetName: "Korean",
            languageCode: "ko",
            shortTitle: "韩文"
        ),
        TranslationLanguage(
            title: "Deutsch",
            targetName: "German",
            languageCode: "de",
            shortTitle: "德文"
        ),
        TranslationLanguage(
            title: "Français",
            targetName: "French",
            languageCode: "fr",
            shortTitle: "法文"
        ),
        TranslationLanguage(
            title: "Español",
            targetName: "Spanish",
            languageCode: "es",
            shortTitle: "西文"
        ),
        TranslationLanguage(
            title: "Português",
            targetName: "Portuguese",
            languageCode: "pt",
            shortTitle: "葡文"
        ),
        TranslationLanguage(
            title: "Italiano",
            targetName: "Italian",
            languageCode: "it",
            shortTitle: "意文"
        ),
        TranslationLanguage(
            title: "Русский",
            targetName: "Russian",
            languageCode: "ru",
            shortTitle: "俄文"
        ),
        TranslationLanguage(
            title: "العربية",
            targetName: "Arabic",
            languageCode: "ar",
            shortTitle: "阿文"
        ),
        TranslationLanguage(
            title: "हिन्दी",
            targetName: "Hindi",
            languageCode: "hi",
            shortTitle: "印地语"
        ),
        TranslationLanguage(
            title: "Tiếng Việt",
            targetName: "Vietnamese",
            languageCode: "vi",
            shortTitle: "越南文"
        ),
        TranslationLanguage(
            title: "ไทย",
            targetName: "Thai",
            languageCode: "th",
            shortTitle: "泰文"
        ),
        TranslationLanguage(
            title: "Bahasa Indonesia",
            targetName: "Indonesian",
            languageCode: "id",
            shortTitle: "印尼文"
        ),
    ]

    public static func language(forTargetName targetName: String) -> TranslationLanguage? {
        common.first { $0.targetName == targetName }
    }

    public static func title(forTargetName targetName: String) -> String {
        language(forTargetName: targetName)?.title ?? targetName
    }

    public static func shortTitle(forTargetName targetName: String) -> String {
        language(forTargetName: targetName)?.shortTitle ?? targetName
    }

    public static func isValidTargetName(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { return false }

        let allowed = CharacterSet.letters
            .union(.nonBaseCharacters)
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: " -_(),.'’"))
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }
}

public enum TranslationTargetResolver {
    public static func resolve(
        primaryTarget: String,
        reverseTarget: String,
        sourceText: String,
        smartReverseEnabled: Bool
    ) -> String {
        guard smartReverseEnabled,
            primaryTarget != reverseTarget,
            let primary = TranslationLanguages.language(forTargetName: primaryTarget),
            let detected = detectedLanguage(in: sourceText),
            languageFamily(primary.languageCode) == languageFamily(detected.code),
            detected.confidence >= minimumConfidence(for: detected.code)
        else { return primaryTarget }
        return reverseTarget
    }

    package static func detectedLanguage(in sourceText: String) -> (code: String, confidence: Double)? {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let sample =
            trimmed.count <= 4_000
            ? trimmed
            : "\(trimmed.prefix(2_000))\n\(trimmed.suffix(2_000))"

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard
            let hypothesis = recognizer.languageHypotheses(withMaximum: 3)
                .max(by: { $0.value < $1.value })
        else { return nil }
        return (hypothesis.key.rawValue, hypothesis.value)
    }

    private static func languageFamily(_ languageCode: String) -> String {
        languageCode.hasPrefix("zh-") ? "zh" : languageCode
    }

    private static func minimumConfidence(for languageCode: String) -> Double {
        languageFamily(languageCode) == "zh" ? 0.35 : 0.5
    }
}
