import Darwin
import Foundation
import GlossCore

@main
struct GlossCommand {
    static func main() async {
        do {
            let arguments = try Arguments(CommandLine.arguments.dropFirst())
            let source = try arguments.sourceText()
            let codex = CodexAppServerClient()
            let broker = TranslationBroker(backend: codex)

            let result = try await broker.translateText(
                source,
                targetLanguage: arguments.targetLanguage,
                profile: arguments.profile,
                contentKind: arguments.contentKind
            )
            print(result)
            await codex.stop()
        } catch {
            FileHandle.standardError.write(Data("gloss: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private struct Arguments {
    let targetLanguage: String
    let profile: TranslationProfile
    let contentKind: TranslationContentKind
    let textParts: [String]

    init(_ rawArguments: ArraySlice<String>) throws {
        var targetLanguage = "Chinese (Simplified)"
        var profile: TranslationProfile = .natural
        var contentKind: TranslationContentKind = .selection
        var textParts: [String] = []
        var iterator = rawArguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--target", "-t":
                guard let value = iterator.next() else {
                    throw UsageError("--target 需要语言名称。")
                }
                targetLanguage = value
            case "--profile", "-p":
                guard let value = iterator.next(), let parsed = TranslationProfile(rawValue: value) else {
                    throw UsageError("--profile 可选 faithful、natural、technical、academic 或 subtitle。")
                }
                profile = parsed
            case "--kind", "-k":
                guard let value = iterator.next(),
                    let parsed = TranslationContentKind(rawValue: value)
                else {
                    throw UsageError(
                        "--kind 可选 selection、webpage、document、subtitle 或 ocr。"
                    )
                }
                contentKind = parsed
            case "--help", "-h":
                print(Self.help)
                exit(0)
            default:
                textParts.append(argument)
            }
        }

        self.targetLanguage = targetLanguage
        self.profile = profile
        self.contentKind = contentKind
        self.textParts = textParts
    }

    func sourceText() throws -> String {
        let value: String
        if textParts.isEmpty {
            value = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } else {
            value = textParts.joined(separator: " ")
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageError("请通过参数或 stdin 提供文本。")
        }
        return value
    }

    static let help = """
        Usage: gloss-cli [options] [text]

          -t, --target LANGUAGE   Target language (default: Chinese (Simplified))
          -p, --profile PROFILE  faithful | natural | technical | academic | subtitle
          -k, --kind KIND        selection | webpage | document | subtitle | ocr

        If text is omitted, gloss-cli reads from stdin.
        """
}

private struct UsageError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
