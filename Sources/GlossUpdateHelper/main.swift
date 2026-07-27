import Foundation
import GlossCore

@main
struct GlossUpdateHelperMain {
    static func main() async {
        do {
            let requestURL = try GlossUpdateHelperArguments.requestFileURL(
                from: Array(CommandLine.arguments.dropFirst())
            )
            let request = try GlossHomebrewUpgradeRequestStore.load(
                from: requestURL
            )
            let signedRequestVerifier =
                try GlossSignedAppUpdateRequestVerifier()
            let result = try await GlossHomebrewUpgradeWorkflow.live()
                .runAndPersist(request) {
                    try signedRequestVerifier.verify(request)
                    try GlossUpdateHelperReadinessStore.write(
                        GlossUpdateHelperReadiness(
                            requestIdentifier: request.requestIdentifier,
                            helperProcessIdentifier:
                                Int32(ProcessInfo.processInfo.processIdentifier)
                        ),
                        to: request.readinessURL
                    )
                }
            exit(result.succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
        } catch {
            FileHandle.standardError.write(
                Data("gloss-update-helper: \(error.localizedDescription)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}
