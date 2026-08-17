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

    func testReasoningEffortCanBeConfigured() async {
        let client = CodexAppServerClient(
            environment: [:],
            model: "gpt-test",
            reasoningEffort: .xhigh
        )

        let status = await client.status()

        XCTAssertEqual(status.model, "gpt-test")
        XCTAssertEqual(status.reasoningEffort, .xhigh)
    }

    func testBackgroundDocumentsUseLowestSupportedReasoningByDefault() {
        let document = TranslationBatchRequest(
            items: [TranslationItem(id: "pdf", text: "Paper")],
            targetLanguage: "Chinese (Simplified)",
            profile: .academic,
            contentKind: .document,
            priority: .background
        )
        let webpage = TranslationBatchRequest(
            items: [TranslationItem(id: "web", text: "Page")],
            targetLanguage: "Chinese (Simplified)",
            contentKind: .webpage,
            priority: .background
        )

        XCTAssertEqual(
            CodexAppServerClient.reasoningEffort(
                for: document,
                defaultEffort: .low,
                documentEffort: .low
            ),
            .low
        )
        XCTAssertEqual(
            CodexAppServerClient.reasoningEffort(
                for: webpage,
                defaultEffort: .low,
                documentEffort: .low
            ),
            .low
        )
    }

    func testDocumentReasoningEnvironmentCanInheritOrOverride() {
        XCTAssertNil(
            CodexAppServerClient.readDocumentReasoningEffort(
                ["GLOSS_CODEX_DOCUMENT_REASONING_EFFORT": "inherit"],
                configured: .low
            )
        )
        XCTAssertEqual(
            CodexAppServerClient.readDocumentReasoningEffort(
                ["GLOSS_CODEX_DOCUMENT_REASONING_EFFORT": "medium"],
                configured: .low
            ),
            .medium
        )
    }

    func testModelWaitHedgeDefaultsToEightSecondsAndCanBeTuned() {
        XCTAssertEqual(
            CodexAppServerClient.readModelWaitHedgeNanoseconds([:]),
            8_000_000_000
        )
        XCTAssertEqual(
            CodexAppServerClient.readModelWaitHedgeNanoseconds(
                [:],
                dispatchAware: true
            ),
            3_000_000_000
        )
        XCTAssertEqual(
            CodexAppServerClient.readModelWaitHedgeNanoseconds([
                "GLOSS_CODEX_MODEL_WAIT_HEDGE_SECONDS": "6"
            ]),
            6_000_000_000
        )
        XCTAssertNil(
            CodexAppServerClient.readModelWaitHedgeNanoseconds([
                "GLOSS_CODEX_MODEL_WAIT_HEDGE_SECONDS": "off"
            ])
        )
        XCTAssertEqual(
            CodexAppServerClient.readModelWaitHedgeNanoseconds([
                "GLOSS_CODEX_MODEL_WAIT_HEDGE_SECONDS": "invalid"
            ]),
            8_000_000_000
        )
    }

    func testModelItemIDsStayCompactWithinLargeBatches() {
        XCTAssertEqual(CodexAppServerClient.compactModelItemID(for: 0), "0")
        XCTAssertEqual(CodexAppServerClient.compactModelItemID(for: 10), "10")
        XCTAssertEqual(CodexAppServerClient.compactModelItemID(for: 35), "35")
        XCTAssertEqual(CodexAppServerClient.compactModelItemID(for: 36), "36")
    }

    func testSparkDocumentPolicyDoesNotApplyToLuna() {
        let document = TranslationBatchRequest(
            items: [TranslationItem(id: "pdf", text: "Paper")],
            targetLanguage: "Chinese (Simplified)",
            contentKind: .document,
            priority: .background
        )

        XCTAssertTrue(
            CodexAppServerClient.shouldUseSparkDocumentPolicy(
                model: "gpt-5.3-codex-spark",
                request: document
            )
        )
        XCTAssertFalse(
            CodexAppServerClient.shouldUseSparkDocumentPolicy(
                model: "gpt-5.6-luna",
                request: document
            )
        )
    }

    func testSparkPacingAndCapacityRetryOverridesAreBounded() {
        XCTAssertEqual(
            CodexAppServerClient.readSparkStartIntervalNanoseconds([:]),
            500_000_000
        )
        XCTAssertEqual(
            CodexAppServerClient.readSparkStartIntervalNanoseconds([
                "GLOSS_SPARK_START_INTERVAL_MS": "750"
            ]),
            750_000_000
        )
        XCTAssertEqual(CodexAppServerClient.readSparkCapacityRetryLimit([:]), 4)
        XCTAssertEqual(
            CodexAppServerClient.readSparkCapacityRetryLimit([
                "GLOSS_SPARK_CAPACITY_RETRIES": "2"
            ]),
            2
        )
        XCTAssertEqual(
            CodexAppServerClient.readSparkCapacityRetryLimit([
                "GLOSS_SPARK_CAPACITY_RETRIES": "20"
            ]),
            4
        )
    }

    func testSparkCapacityErrorsAreRecognizedWithoutMatchingUnrelatedFailures() {
        XCTAssertTrue(
            CodexAppServerClient.isCapacityError(
                TranslationError.backendUnavailable("Selected model is at capacity")
            )
        )
        XCTAssertTrue(
            CodexAppServerClient.isCapacityError(
                TranslationError.backendUnavailable("HTTP 429 Too Many Requests")
            )
        )
        XCTAssertFalse(
            CodexAppServerClient.isCapacityError(
                TranslationError.invalidResponse("Missing translation item")
            )
        )
    }

    func testThreadRotationDefaultsToTenSuccessfulTurnsAndCanBeDisabled() {
        XCTAssertEqual(CodexAppServerClient.readThreadRotationTurns([:]), 10)
        XCTAssertEqual(
            CodexAppServerClient.readThreadRotationTurns([
                "GLOSS_CODEX_THREAD_ROTATION_TURNS": "20"
            ]),
            20
        )
        XCTAssertNil(
            CodexAppServerClient.readThreadRotationTurns([
                "GLOSS_CODEX_THREAD_ROTATION_TURNS": "off"
            ])
        )
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

    func testHelperExecutableFindsSiblingBundledAppServer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let helpers = root.appendingPathComponent(
            "Gloss.app/Contents/Helpers",
            isDirectory: true
        )
        let cli = helpers.appendingPathComponent("gloss-cli")
        let runtime = helpers.appendingPathComponent(
            "gloss-codex-app-server"
        )
        try makeExecutable(at: cli)
        try makeExecutable(at: runtime)
        let homebrewBin = root.appendingPathComponent(
            "homebrew-bin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: homebrewBin,
            withIntermediateDirectories: true
        )
        let symlink = homebrewBin.appendingPathComponent("gloss-cli")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: cli
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let launch = try XCTUnwrap(
            CodexAppServerClient.resolveRuntime(
                environment: ["GLOSS_CODEX_BIN": "/unavailable/codex"],
                bundleURL: root.appendingPathComponent("NotAnApp"),
                executableURL: symlink
            )
        )

        XCTAssertEqual(launch.executable, runtime.path)
        XCTAssertEqual(launch.argumentPrefix, [])
        XCTAssertEqual(launch.source, "sibling-app-server")
    }

    func testFastLaunchArgumentsDisableUnusedCodexSubsystems() {
        let arguments = CodexAppServerClient.fastLaunchArguments(
            reasoningEffort: .low,
            modelCatalog: URL(fileURLWithPath: "/tmp/catalog with spaces.json")
        )

        XCTAssertFalse(arguments.contains("--session-source"))
        XCTAssertTrue(arguments.contains("model_catalog_json=\"/tmp/catalog with spaces.json\""))
        for feature in CodexAppServerClient.disabledCodexFeatures {
            XCTAssertTrue(arguments.contains("features.\(feature)=false"))
        }
        XCTAssertTrue(arguments.contains("orchestrator.mcp.enabled=false"))
        XCTAssertTrue(arguments.contains("skills.bundled.enabled=false"))
        XCTAssertTrue(arguments.contains("mcp_servers={}"))
    }

    func testFastThreadStartUsesReusableThreadsAndHasNoToolsOrMCP() {
        let params = CodexAppServerClient.fastThreadStartParameters(
            workingDirectory: URL(fileURLWithPath: "/tmp/gloss-codex"),
            model: "gpt-test"
        )

        XCTAssertEqual(params["ephemeral"], .bool(false))
        XCTAssertEqual(params["dynamicTools"], .array([]))
        XCTAssertEqual(params["model"], .string("gpt-test"))
        let config = params["config"]
        XCTAssertEqual(config?["mcp_servers"], .object([:]))
        for feature in CodexAppServerClient.disabledCodexFeatures {
            XCTAssertEqual(config?["features"]?[feature], .bool(false))
        }
        XCTAssertEqual(config?["orchestrator"]?["mcp"]?["enabled"], .bool(false))
        XCTAssertEqual(config?["skills"]?["bundled"]?["enabled"], .bool(false))
    }

    func testPreparesMinimalStaticCatalogForSelectedModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalogURL = try CodexAppServerClient.prepareModelCatalog(
            in: directory,
            model: "gpt-test",
            reasoningEffort: .minimal
        )
        let catalog = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: catalogURL)
        )

        guard case .array(let models) = catalog["models"] else {
            return XCTFail("Expected a model catalog array")
        }
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0]["slug"], .string("gpt-test"))
        XCTAssertEqual(models[0]["default_reasoning_level"], .string("minimal"))
        let attributes = try FileManager.default.attributesOfItem(atPath: catalogURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
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

    func testReservesOneThreadFromBackgroundWorkByDefault() {
        XCTAssertEqual(
            CodexAppServerClient.defaultBackgroundConcurrency(maximumConcurrentTurns: 3),
            2
        )
        XCTAssertEqual(
            CodexAppServerClient.defaultBackgroundConcurrency(maximumConcurrentTurns: 1),
            1
        )
    }

    func testBackgroundLimitDoesNotBlockInteractiveWork() {
        XCTAssertFalse(
            CodexAppServerClient.canAcquireAvailableThread(
                priority: .background,
                activeBackgroundTurns: 2,
                maximumBackgroundTurns: 2
            )
        )
        XCTAssertTrue(
            CodexAppServerClient.canAcquireAvailableThread(
                priority: .interactive,
                activeBackgroundTurns: 2,
                maximumBackgroundTurns: 2
            )
        )
        XCTAssertTrue(
            CodexAppServerClient.canAcquireAvailableThread(
                priority: .background,
                activeBackgroundTurns: 1,
                maximumBackgroundTurns: 2
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
