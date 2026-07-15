import XCTest

@testable import GlossCore

final class CodexAppServerClientTests: XCTestCase {
    func testUsesFastTranslationModelByDefault() async {
        let client = CodexAppServerClient(environment: [:])

        let status = await client.status()

        XCTAssertEqual(status.model, "gpt-5.3-codex-spark")
    }

    func testModelCanBeOverridden() async {
        let client = CodexAppServerClient(
            environment: ["GLOSS_CODEX_MODEL": "custom-model"]
        )

        let status = await client.status()

        XCTAssertEqual(status.model, "custom-model")
    }

    func testProcessEnvironmentMakesCodexInterpreterDiscoverableFromGUIApp() {
        let codexHome = URL(fileURLWithPath: "/tmp/gloss-codex-home")
        let environment = CodexAppServerClient.makeProcessEnvironment(
            [
                "PATH": "/usr/bin:/bin:/usr/bin",
                "GLOSS_TEST_VALUE": "preserved",
            ],
            executable: "/opt/homebrew/bin/codex",
            codexHome: codexHome
        )

        let pathDirectories = environment["PATH"]?.split(separator: ":").map(String.init)
        XCTAssertEqual(pathDirectories?.first, "/opt/homebrew/bin")
        XCTAssertEqual(pathDirectories?.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertTrue(pathDirectories?.contains("/usr/local/bin") == true)
        XCTAssertTrue(pathDirectories?.contains("/usr/sbin") == true)
        XCTAssertEqual(environment["GLOSS_TEST_VALUE"], "preserved")
        XCTAssertEqual(environment["CODEX_HOME"], codexHome.path)
    }

    func testBundledAppServerTakesPriorityAndNeedsNoCLISubcommand() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtime = bundle.appendingPathComponent(
            "Contents/Helpers/gloss-codex-app-server"
        )
        try makeExecutable(at: runtime)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let launch = try XCTUnwrap(
            CodexAppServerClient.resolveRuntime(
                environment: ["GLOSS_CODEX_BIN": "/unavailable/codex"],
                bundleURL: bundle
            )
        )

        XCTAssertEqual(launch.executable, runtime.path)
        XCTAssertEqual(launch.argumentPrefix, [])
        XCTAssertEqual(launch.source, "bundled-app-server")
    }

    func testExternalCLIFallbackIncludesAppServerSubcommand() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("codex")
        try makeExecutable(at: executable)
        defer { try? FileManager.default.removeItem(at: directory) }

        let launch = try XCTUnwrap(
            CodexAppServerClient.resolveRuntime(
                environment: ["GLOSS_CODEX_BIN": executable.path],
                bundleURL: directory.appendingPathComponent("Empty.app")
            )
        )

        XCTAssertEqual(launch.executable, executable.path)
        XCTAssertEqual(launch.argumentPrefix, ["app-server"])
        XCTAssertEqual(launch.source, "external-cli")
    }

    func testParsesSignedOutAndChatGPTAccountStates() throws {
        let signedOut = try CodexAppServerClient.parseAccountStatus(
            .object([
                "result": .object([
                    "account": .null,
                    "requiresOpenaiAuth": .bool(true),
                ])
            ])
        )
        XCTAssertEqual(
            signedOut,
            CodexAccountStatus(
                isAuthenticated: false,
                authMode: nil,
                email: nil,
                planType: nil
            )
        )

        let signedIn = try CodexAppServerClient.parseAccountStatus(
            .object([
                "result": .object([
                    "account": .object([
                        "type": .string("chatgpt"),
                        "email": .string("reader@example.com"),
                        "planType": .string("plus"),
                    ]),
                    "requiresOpenaiAuth": .bool(true),
                ])
            ])
        )
        XCTAssertEqual(
            signedIn,
            CodexAccountStatus(
                isAuthenticated: true,
                authMode: "chatgpt",
                email: "reader@example.com",
                planType: "plus"
            )
        )
    }

    func testPrioritizesInteractiveThreadWaitersAndKeepsFIFOWithinAPriority() {
        XCTAssertTrue(
            CodexAppServerClient.shouldSchedule(
                .interactive,
                sequence: 3,
                before: .background,
                otherSequence: 1
            )
        )
        XCTAssertTrue(
            CodexAppServerClient.shouldSchedule(
                .visible,
                sequence: 2,
                before: .visible,
                otherSequence: 4
            )
        )
        XCTAssertFalse(
            CodexAppServerClient.shouldSchedule(
                .background,
                sequence: 1,
                before: .visible,
                otherSequence: 9
            )
        )
    }

    func testTurnWaitStagesSplitTheWholeWaitWithoutOverlap() {
        let milliseconds: (UInt64) -> UInt64 = { $0 * 1_000_000 }
        let stages = CodexAppServerClient.turnWaitStages(
            acceptedAt: milliseconds(1),
            turnStartedAt: milliseconds(3),
            agentMessageStartedAt: milliseconds(6),
            firstDeltaAt: milliseconds(10),
            lastDeltaAt: milliseconds(15),
            agentMessageCompletedAt: milliseconds(21),
            completedAt: milliseconds(28)
        )

        XCTAssertEqual(stages.dispatchMilliseconds, 2)
        XCTAssertEqual(stages.modelWaitMilliseconds, 3)
        XCTAssertEqual(stages.firstDeltaWaitMilliseconds, 4)
        XCTAssertEqual(stages.outputStreamMilliseconds, 5)
        XCTAssertEqual(stages.messageFinalizeMilliseconds, 6)
        XCTAssertEqual(stages.turnFinalizeMilliseconds, 7)
        XCTAssertEqual(stages.totalMilliseconds, 27)
    }

    func testTurnWaitStagesRemainAdditiveWhenLifecycleEventsAreMissing() {
        let milliseconds: (UInt64) -> UInt64 = { $0 * 1_000_000 }
        let stages = CodexAppServerClient.turnWaitStages(
            acceptedAt: milliseconds(1),
            turnStartedAt: nil,
            agentMessageStartedAt: nil,
            firstDeltaAt: milliseconds(10),
            lastDeltaAt: milliseconds(14),
            agentMessageCompletedAt: nil,
            completedAt: milliseconds(21)
        )

        XCTAssertEqual(stages.dispatchMilliseconds, 0)
        XCTAssertEqual(stages.modelWaitMilliseconds, 9)
        XCTAssertEqual(stages.firstDeltaWaitMilliseconds, 0)
        XCTAssertEqual(stages.outputStreamMilliseconds, 4)
        XCTAssertEqual(stages.messageFinalizeMilliseconds, 0)
        XCTAssertEqual(stages.turnFinalizeMilliseconds, 7)
        XCTAssertEqual(stages.totalMilliseconds, 20)
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
