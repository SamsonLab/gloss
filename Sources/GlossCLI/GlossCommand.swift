import Foundation
import GlossCore

@main
struct GlossCommand {
    static func main() async {
        do {
            let invocation = try GlossCLIInvocationParser.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            switch invocation {
            case .capabilitiesJSON:
                print(
                    try JSONOutput.encode(
                        GlossCapabilitiesReport()
                    )
                )
            case .help(let command):
                print(Help.text(for: command))
            case .legacyText(let options):
                try await translateText(options)
            case .text(let options):
                try await translateText(options)
            case .browser(let options):
                try await translateText(options)
            case .pdf(let options):
                print(try await PDFScenarioCommand.run(options))
            }
        } catch {
            StandardError.write("gloss: \(error.localizedDescription)\n")
            exit(1)
        }
    }

    private static func translateText(
        _ options: GlossCLITextOptions
    ) async throws {
        let source = try sourceText(from: options.textParts)
        let provider = ProviderHandle(
            provider: options.provider,
            model: options.model,
            reasoningEffort: options.reasoningEffort
        )
        let broker = TranslationBroker(backend: provider.backend)

        do {
            let result = try await broker.translateText(
                source,
                targetLanguage: options.targetLanguage,
                profile: options.profile,
                contentKind: options.contentKind
            )
            print(result)
            await provider.stop()
        } catch {
            await provider.stop()
            throw error
        }
    }

    private static func sourceText(
        from textParts: [String]
    ) throws -> String {
        let value: String
        if textParts.isEmpty {
            value =
                String(
                    data: FileHandle.standardInput.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
        } else {
            value = textParts.joined(separator: " ")
        }
        guard
            !value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw GlossCLIUsageError(
                "请通过参数或 stdin 提供文本。"
            )
        }
        return value
    }
}
