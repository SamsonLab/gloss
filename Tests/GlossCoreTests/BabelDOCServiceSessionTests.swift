import Foundation
import XCTest

@testable import GlossCore

final class BabelDOCServiceSessionTests: XCTestCase {
    func testProcessIdentityRequiresMatchingStartTime() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let startTime = try XCTUnwrap(
            BabelDOCServiceSession.processStartTime(
                process.processIdentifier
            )
        )
        XCTAssertTrue(
            BabelDOCServiceSession.processMatches(
                process.processIdentifier,
                expectedStartTime: startTime
            )
        )
        XCTAssertFalse(
            BabelDOCServiceSession.processMatches(
                process.processIdentifier,
                expectedStartTime: startTime + 1
            )
        )
        XCTAssertFalse(
            BabelDOCServiceSession.processMatches(
                process.processIdentifier,
                expectedStartTime: nil
            )
        )
    }

    func testLiveExecutorAndLayoutSessionWhenRequested() async throws {
        guard
            ProcessInfo.processInfo.environment[
                "GLOSS_RUN_BABELDOC_EXECUTOR_SMOKE"
            ] == "1"
        else {
            throw XCTSkip(
                "Set GLOSS_RUN_BABELDOC_EXECUTOR_SMOKE=1 with a v1 gloss-babeldoc runtime."
            )
        }
        let runtime = try XCTUnwrap(BabelDOCExternalEngine.resolveRuntime())
        XCTAssertNotNil(runtime.executorExecutable)
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let session = BabelDOCServiceSession(
            persistedStateDirectoryURL: stateDirectory
        )
        do {
            let layoutURL = try await session.start(
                runtime: runtime,
                timeout: .seconds(120)
            )
            let snapshot = await session.snapshot()
            XCTAssertEqual(snapshot.lifecycleState, .ready)
            XCTAssertTrue(snapshot.runtimeVersion?.hasPrefix("0.6.4+gloss.") == true)
            XCTAssertNotNil(snapshot.endpoint)
            XCTAssertNotNil(snapshot.processIdentifier)
            XCTAssertNotNil(snapshot.instanceID)
            let connection = try await session.executorConnection(
                runtime: runtime,
                timeout: .seconds(5)
            )
            XCTAssertEqual(connection.layoutServiceBaseURL, layoutURL)
            let healthy = try await BabelDOCExecutorClient(
                connection: connection
            ).health()
            XCTAssertTrue(healthy)
            await session.shutdown()
            let stopped = await session.snapshot()
            XCTAssertEqual(stopped.lifecycleState, .stopped)
        } catch {
            await session.shutdown()
            throw error
        }
    }

    func testCleanupPersistedServiceIsIdempotentWithoutMarker() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let session = BabelDOCServiceSession(
            persistedStateDirectoryURL: stateDirectory
        )

        try await session.cleanupPersistedService()
        try await session.cleanupPersistedService()
    }

    func testCleanupPersistedServiceRemovesDeadPrivateWorkrootAndMarker() async throws {
        let temporary = FileManager.default.temporaryDirectory
        let stateDirectory =
            temporary
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workroot = temporary.appendingPathComponent(
            "\(BabelDOCServiceSession.workingDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
            try? FileManager.default.removeItem(at: workroot)
        }
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: workroot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let token = workroot.appendingPathComponent(
            BabelDOCServiceSession.executorTokenFileName
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: token.path,
                contents: Data(String(repeating: "a", count: 40).utf8),
                attributes: [.posixPermissions: 0o600]
            )
        )
        let marker = stateDirectory.appendingPathComponent(
            BabelDOCServiceSession.persistedSessionFileName
        )
        let payload: [String: Any] = [
            "endpoint": "http://127.0.0.1:49231",
            "tokenFile": token.absoluteString,
            "workroot": workroot.absoluteString,
            "layoutEndpoint": "http://127.0.0.1:49232",
            "layoutPID": NSNull(),
            "instanceID": "dead-instance",
            "pid": Int32.max,
            "processStartTime": 100.0,
            "parentPID": Int32.max,
            "runtimeVersion": "0.6.4+gloss.2",
        ]
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: marker.path,
                contents: try JSONSerialization.data(withJSONObject: payload),
                attributes: [.posixPermissions: 0o644]
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: marker.path
        )
        let session = BabelDOCServiceSession(
            persistedStateDirectoryURL: stateDirectory
        )

        try await session.cleanupPersistedService()

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workroot.path))
    }

    func testCleanupPersistedServiceRemovesMarkerAfterTemporaryWorkrootIsGone() async throws {
        let temporary = FileManager.default.temporaryDirectory
        let stateDirectory = temporary.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let missingWorkroot = temporary.appendingPathComponent(
            "\(BabelDOCServiceSession.workingDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let marker = try writePersistedSessionMarker(
            in: stateDirectory,
            workroot: missingWorkroot,
            executorPID: Int32.max,
            layoutPID: Int32.max - 1
        )
        let session = BabelDOCServiceSession(
            persistedStateDirectoryURL: stateDirectory
        )

        try await session.cleanupPersistedService()

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingWorkroot.path))
    }

    func testCleanupPersistedServicePreservesMissingWorkrootMarkerForLivePID() async throws {
        let temporary = FileManager.default.temporaryDirectory
        let stateDirectory = temporary.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let missingWorkroot = temporary.appendingPathComponent(
            "\(BabelDOCServiceSession.workingDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let marker = try writePersistedSessionMarker(
            in: stateDirectory,
            workroot: missingWorkroot,
            executorPID: Int32(ProcessInfo.processInfo.processIdentifier),
            layoutPID: Int32.max
        )
        let session = BabelDOCServiceSession(
            persistedStateDirectoryURL: stateDirectory
        )

        do {
            try await session.cleanupPersistedService()
            XCTFail("Expected cleanup to fail closed for a live recorded PID")
        } catch {
            XCTAssertTrue(error is BabelDOCExecutorError)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testIdleShutdownPreservesARecoverableForeignSessionMarker() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = stateDirectory.appendingPathComponent(
            BabelDOCServiceSession.persistedSessionFileName
        )
        try Data("foreign-session".utf8).write(to: marker)

        let session = BabelDOCServiceSession(
            persistedStateDirectoryURL: stateDirectory
        )
        let stopped = await session.shutdown()
        XCTAssertTrue(stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testPrivateAtomicWriterPublishesOnlyMode0600() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent("state.json")
        try Data("old".utf8).write(to: destination)

        try BabelDOCServiceSession.writePrivateAtomicFile(
            Data("new".utf8),
            to: destination
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testTerminationEscalatesForChildIgnoringTerm() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do sleep 1; done"]
        try process.run()
        try await Task.sleep(for: .milliseconds(100))

        let exited = await BabelDOCServiceSession.terminateChildProcess(
            process,
            allowGracefulExit: false
        )

        XCTAssertTrue(exited)
        XCTAssertFalse(process.isRunning)
    }

    func testManagedRuntimeLaunchesSelfContainedLayoutService() throws {
        let launch = try BabelDOCServiceSession.layoutLaunch(
            runtime: BabelDOCRuntimeLaunch(
                executable: "/managed/gloss-babeldoc",
                source: "managed",
                executorExecutable: "/managed/gloss-babeldoc"
            ),
            legacyInterpreter: nil,
            scriptURL: URL(fileURLWithPath: "/tmp/layout_service.py"),
            parentPID: 42
        )

        XCTAssertEqual(launch.executable, "/managed/gloss-babeldoc")
        XCTAssertEqual(
            launch.arguments,
            [
                "layout-serve",
                "--host", "127.0.0.1",
                "--port", "0",
                "--parent-pid", "42",
            ]
        )
    }

    func testLegacyRuntimeUsesPrivatePythonLayoutScript() throws {
        let launch = try BabelDOCServiceSession.layoutLaunch(
            runtime: BabelDOCRuntimeLaunch(
                executable: "/legacy/babeldoc",
                source: "legacy"
            ),
            legacyInterpreter: "/legacy/python",
            scriptURL: URL(fileURLWithPath: "/tmp/layout_service.py"),
            parentPID: 24
        )

        XCTAssertEqual(launch.executable, "/legacy/python")
        XCTAssertEqual(launch.arguments.first, "/tmp/layout_service.py")
        XCTAssertEqual(Array(launch.arguments.suffix(2)), ["--parent-pid", "24"])
    }

    func testCleansOnlySafeStaleDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        func makeDirectory(
            prefix: String = BabelDOCServiceSession.workingDirectoryPrefix,
            ownerPID: Int32? = nil,
            age: TimeInterval = 0,
            permissions: Int = 0o700
        ) throws -> URL {
            let url = root.appendingPathComponent(
                "\(prefix)\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: permissions]
            )
            if let ownerPID {
                let marker = url.appendingPathComponent(
                    BabelDOCServiceSession.ownerPIDFileName
                )
                try Data("\(ownerPID)\n".utf8).write(to: marker)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: marker.path
                )
            }
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-age)],
                ofItemAtPath: url.path
            )
            return url
        }

        let deadOwner = try makeDirectory(ownerPID: Int32.max)
        let liveOwner = try makeDirectory(
            ownerPID: Int32(ProcessInfo.processInfo.processIdentifier),
            age: 2 * 24 * 60 * 60
        )
        let oldLegacy = try makeDirectory(age: 2 * 24 * 60 * 60)
        let recentLegacy = try makeDirectory(age: 10 * 60)
        let unrelated = try makeDirectory(
            prefix: "Unrelated-",
            age: 2 * 24 * 60 * 60
        )
        let unsafePermissions = try makeDirectory(
            age: 2 * 24 * 60 * 60,
            permissions: 0o755
        )
        let symlinkTarget = try makeDirectory(prefix: "Target-")
        let symlink = root.appendingPathComponent(
            "\(BabelDOCServiceSession.workingDirectoryPrefix)\(UUID().uuidString)"
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: symlinkTarget
        )

        BabelDOCServiceSession.cleanupStaleWorkingDirectories(
            in: root,
            now: now
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: deadOwner.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLegacy.path))
        for preserved in [
            liveOwner,
            recentLegacy,
            unrelated,
            unsafePermissions,
            symlink,
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: preserved.path),
                preserved.lastPathComponent
            )
        }
    }

    private func writePersistedSessionMarker(
        in stateDirectory: URL,
        workroot: URL,
        executorPID: Int32,
        layoutPID: Int32?
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let token = workroot.appendingPathComponent(
            BabelDOCServiceSession.executorTokenFileName
        )
        let marker = stateDirectory.appendingPathComponent(
            BabelDOCServiceSession.persistedSessionFileName
        )
        let payload: [String: Any] = [
            "endpoint": "http://127.0.0.1:49231",
            "tokenFile": token.absoluteString,
            "workroot": workroot.absoluteString,
            "layoutEndpoint": "http://127.0.0.1:49232",
            "layoutPID": layoutPID.map { $0 as Any } ?? NSNull(),
            "layoutProcessStartTime": 100.0,
            "instanceID": "missing-workroot-instance",
            "pid": executorPID,
            "processStartTime": 100.0,
            "parentPID": Int32.max,
            "runtimeVersion": "0.6.4+gloss.3",
        ]
        try JSONSerialization.data(withJSONObject: payload).write(
            to: marker,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: marker.path
        )
        return marker
    }
}
