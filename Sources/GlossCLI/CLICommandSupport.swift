import Foundation
import GlossCore

enum ProviderHandle: Sendable {
    case codex(CodexAppServerClient, model: String, reasoning: CodexReasoningEffort)
    case llama(LlamaServerClient, model: String)

    init(
        provider: TranslationProvider,
        model: String?,
        reasoningEffort: CodexReasoningEffort
    ) {
        switch provider {
        case .codex:
            let selectedModel =
                model ?? TranslationProviderConfiguration.defaultCodexModel
            self = .codex(
                CodexAppServerClient(
                    model: model,
                    reasoningEffort: reasoningEffort
                ),
                model: selectedModel,
                reasoning: reasoningEffort
            )
        case .llama:
            let selectedModel =
                model ?? TranslationProviderConfiguration.defaultLlamaModel
            self = .llama(
                LlamaServerClient(model: selectedModel),
                model: selectedModel
            )
        }
    }

    var backend: any TranslationBackend {
        switch self {
        case .codex(let client, _, _):
            client
        case .llama(let client, _):
            client
        }
    }

    var status: TranslationProviderStatus {
        switch self {
        case .codex(_, let model, let reasoning):
            TranslationProviderStatus(
                provider: .codex,
                model: model,
                reasoningEffort: reasoning,
                configurationRevision: "cli",
                isWarm: false
            )
        case .llama(_, let model):
            TranslationProviderStatus(
                provider: .llama,
                model: model,
                configurationRevision: "cli",
                isWarm: false
            )
        }
    }

    func stop() async {
        switch self {
        case .codex(let client, _, _):
            await client.stop()
        case .llama(let client, _):
            await client.stop()
        }
    }
}

enum JSONOutput {
    static func encode<T: Encodable>(
        _ value: T
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(
            decoding: try encoder.encode(value),
            as: UTF8.self
        )
    }
}

final class StandardError: @unchecked Sendable {
    private static let lock = NSLock()

    static func write(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(value.utf8))
    }
}

enum Help {
    static func text(for command: GlossCLICommand?) -> String {
        switch command {
        case .capabilities:
            """
            Usage: gloss-cli capabilities --json

            Prints the capability registry, enabled business scenarios, and CLI
            command mappings as stable JSON.
            """
        case .text:
            """
            Usage: gloss-cli text [options] [text]

              -t, --target LANGUAGE   Target language (default: Chinese (Simplified))
              -p, --profile PROFILE  faithful | natural | technical | academic | subtitle
              -k, --kind KIND        selection | webpage | document | subtitle | ocr
                  --provider NAME    codex | llama (default: codex)
                  --model MODEL      Codex model, Hugging Face GGUF repo, or local GGUF path
                  --reasoning LEVEL  minimal | low | medium | high | xhigh (Codex only)

            Invokes the reusable text-translation capability. If text is omitted,
            gloss-cli reads from stdin.
            """
        case .browser:
            """
            Usage: gloss-cli browser [options] [text]

              -t, --target LANGUAGE   Target language (default: Chinese (Simplified))
              -p, --profile PROFILE  faithful | natural | technical | academic | subtitle
              -k, --kind webpage     Browser content kind is always webpage
                  --provider NAME    codex | llama (default: codex)
                  --model MODEL      Codex model, Hugging Face GGUF repo, or local GGUF path
                  --reasoning LEVEL  minimal | low | medium | high | xhigh (Codex only)

            If text is omitted, gloss-cli reads from stdin.
            """
        case .pdf:
            """
            Usage: gloss-cli pdf INPUT... --output DIR [options]

              -o, --output DIR       Output directory (required)
                  --source CODE      Source language code (default: en)
              -t, --target LANGUAGE  Target language (default: Chinese (Simplified))
                  --mode MODE        mono | bilingual (default: mono)
                  --provider NAME    codex | llama (default: codex)
                  --model MODEL      Codex model, Hugging Face GGUF repo, or local GGUF path
                  --reasoning LEVEL  minimal | low | medium | high | xhigh (Codex only)

            Processes one or more PDFs in order while reusing one private
            managed BabelDOC/layout session. Progress is written to stderr and
            the generated paths are returned as a JSON array on stdout.
            """
        case nil:
            """
            Usage:
              gloss-cli [options] [text]
              gloss-cli text [options] [text]
              gloss-cli browser [options] [text]
              gloss-cli pdf INPUT... --output DIR [options]
              gloss-cli capabilities --json

            Legacy text options:
              -t, --target LANGUAGE   Target language (default: Chinese (Simplified))
              -p, --profile PROFILE  faithful | natural | technical | academic | subtitle
              -k, --kind KIND        selection | webpage | document | subtitle | ocr
                  --provider NAME    codex | llama (default: codex)
                  --model MODEL      Codex model, Hugging Face GGUF repo, or local GGUF path
                  --reasoning LEVEL  minimal | low | medium | high | xhigh (Codex only)

            If text is omitted, gloss-cli reads from stdin.
            """
        }
    }
}
