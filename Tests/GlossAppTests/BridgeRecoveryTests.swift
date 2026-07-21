import Darwin
import Foundation
import XCTest

@testable import Gloss

final class BridgeRecoveryTests: XCTestCase {
    func testParsesListeningProcessFromLSOFMachineOutput() {
        let output = """
            p10030
            cGloss.real
            f4
            n127.0.0.1:8787
            """

        XCTAssertEqual(
            BridgePortManager.parseLSOFOutput(output),
            BridgePortManager.ListenerSnapshot(
                processIdentifier: 10_030,
                command: "Gloss.real",
                endpoint: "127.0.0.1:8787"
            )
        )
    }

    func testFindsEnclosingApplicationBundleForPackagedExecutable() {
        XCTAssertEqual(
            BridgePortManager.enclosingApplicationBundleURL(
                for: "/tmp/Gloss PDF QA.app/Contents/MacOS/Gloss.real"
            )?.path,
            "/tmp/Gloss PDF QA.app"
        )
        XCTAssertNil(
            BridgePortManager.enclosingApplicationBundleURL(
                for: "/usr/local/bin/unrelated"
            )
        )
    }

    func testOnlyVerifiedOlderGlossCanBeTerminatedAutomatically() {
        let verifiedOlder = occupant(
            identityMatchesGloss: true,
            healthVerified: true,
            isOlder: true
        )
        let unhealthyGloss = occupant(
            identityMatchesGloss: true,
            healthVerified: false,
            isOlder: true
        )
        let newerGloss = occupant(
            identityMatchesGloss: true,
            healthVerified: true,
            isOlder: false
        )
        let unknown = occupant(
            identityMatchesGloss: false,
            healthVerified: false,
            isOlder: true
        )

        XCTAssertTrue(verifiedOlder.canAutomaticallyTerminate)
        XCTAssertFalse(unhealthyGloss.canAutomaticallyTerminate)
        XCTAssertFalse(newerGloss.canAutomaticallyTerminate)
        XCTAssertFalse(unknown.canAutomaticallyTerminate)
    }

    func testDashboardPresentsVerifiedAndUnknownOccupantsDifferently() {
        let verified = BridgeDashboardState.occupied(
            occupant(
                identityMatchesGloss: true,
                healthVerified: true,
                isOlder: true
            )
        ).presentation
        let unknown = BridgeDashboardState.occupied(
            occupant(
                identityMatchesGloss: false,
                healthVerified: false,
                isOlder: true
            )
        ).presentation
        let newerGloss = BridgeDashboardState.occupied(
            occupant(
                identityMatchesGloss: true,
                healthVerified: true,
                isOlder: false
            )
        ).presentation

        XCTAssertEqual(verified.headline, "旧 Gloss 占用了端口")
        XCTAssertEqual(verified.actionTitle, "释放并重连")
        XCTAssertEqual(verified.tone, .warning)
        XCTAssertEqual(unknown.headline, "端口被其他进程占用")
        XCTAssertEqual(unknown.actionTitle, "强制释放…")
        XCTAssertEqual(unknown.tone, .warning)
        XCTAssertEqual(newerGloss.headline, "另一个 Gloss 正在运行")
        XCTAssertEqual(newerGloss.actionTitle, "强制释放…")
    }

    func testPDFReadinessRequiresHealthyBridgeState() {
        let ready = BridgeDashboardState.ready(
            BridgeReadyInfo(
                endpoint: "127.0.0.1:8787",
                processIdentifier: 42,
                version: "0.6.0",
                executablePath: "/Applications/Gloss.app/Contents/MacOS/Gloss"
            )
        )

        XCTAssertTrue(ready.isReady)
        XCTAssertFalse(BridgeDashboardState.starting.isReady)
        XCTAssertFalse(BridgeDashboardState.failed("端口冲突").isReady)
        XCTAssertEqual(ready.presentation.actionTitle, "重新连接")
        XCTAssertTrue(ready.presentation.detail.contains("PID 42"))
    }

    func testProcessFingerprintRejectsReusedPIDWithDifferentLaunchDate() {
        let first = occupant(launchDate: Date(timeIntervalSince1970: 100))
        let reused = occupant(launchDate: Date(timeIntervalSince1970: 200))

        XCTAssertFalse(first.identifiesSameProcess(as: reused))
    }

    @MainActor
    func testForcedTerminationReleasesAnUnknownListener() async throws {
        let fixture = try await makeListenerFixture()
        defer { fixture.stop() }
        let manager = BridgePortManager(port: fixture.port)
        let occupant = try await waitForOccupant(
            processIdentifier: fixture.process.processIdentifier,
            manager: manager
        )

        XCTAssertFalse(occupant.isVerifiedGloss)
        try await manager.terminate(
            occupant,
            token: nil,
            allowingUnverified: true
        )
        fixture.process.waitUntilExit()

        XCTAssertFalse(fixture.process.isRunning)
        let releasedOccupant = try await manager.inspect(token: nil)
        XCTAssertNil(releasedOccupant)
    }

    @MainActor
    func testTerminationRejectsAChangedProcessFingerprint() async throws {
        let fixture = try await makeListenerFixture()
        defer { fixture.stop() }
        let manager = BridgePortManager(port: fixture.port)
        let occupant = try await waitForOccupant(
            processIdentifier: fixture.process.processIdentifier,
            manager: manager
        )
        let staleOccupant = BridgePortOccupant(
            processIdentifier: occupant.processIdentifier,
            command: occupant.command,
            executablePath: occupant.executablePath.map { $0 + ".reused" },
            bundleIdentifier: occupant.bundleIdentifier,
            applicationName: occupant.applicationName,
            launchDate: occupant.launchDate.map { $0.addingTimeInterval(-10) },
            endpoint: occupant.endpoint,
            serviceVersion: occupant.serviceVersion,
            identityMatchesGloss: occupant.identityMatchesGloss,
            healthVerified: occupant.healthVerified,
            isOlderThanCurrentProcess: occupant.isOlderThanCurrentProcess
        )

        do {
            try await manager.terminate(
                staleOccupant,
                token: nil,
                allowingUnverified: true
            )
            XCTFail("Expected the process fingerprint to be rejected")
        } catch let error as BridgePortManagerError {
            XCTAssertEqual(error, .occupantChanged)
        }

        XCTAssertTrue(fixture.process.isRunning)
    }

    @MainActor
    func testTerminationEscalatesWhenTheListenerIgnoresTerm() async throws {
        let fixture = try await makeListenerFixture(ignoringTermination: true)
        defer { fixture.stop() }
        let manager = BridgePortManager(port: fixture.port)
        let occupant = try await waitForOccupant(
            processIdentifier: fixture.process.processIdentifier,
            manager: manager
        )

        try await manager.terminate(
            occupant,
            token: nil,
            allowingUnverified: true
        )
        fixture.process.waitUntilExit()

        XCTAssertEqual(fixture.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(fixture.process.terminationStatus, SIGKILL)
        let releasedOccupant = try await manager.inspect(token: nil)
        XCTAssertNil(releasedOccupant)
    }

    @MainActor
    func testCancelledTerminationLeavesTheListenerRunning() async throws {
        let fixture = try await makeListenerFixture()
        defer { fixture.stop() }
        let manager = BridgePortManager(port: fixture.port)
        let occupant = try await waitForOccupant(
            processIdentifier: fixture.process.processIdentifier,
            manager: manager
        )
        let termination = Task { @MainActor in
            try await manager.terminate(
                occupant,
                token: nil,
                allowingUnverified: true
            )
        }

        termination.cancel()
        do {
            try await termination.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected before any signal is sent.
        }

        XCTAssertTrue(fixture.process.isRunning)
        let activeOccupant = try await manager.inspect(token: nil)
        XCTAssertEqual(
            activeOccupant?.processIdentifier,
            fixture.process.processIdentifier
        )
    }

    private func occupant(
        launchDate: Date = Date(timeIntervalSince1970: 100),
        identityMatchesGloss: Bool = true,
        healthVerified: Bool = true,
        isOlder: Bool = true
    ) -> BridgePortOccupant {
        BridgePortOccupant(
            processIdentifier: ProcessInfo.processInfo.processIdentifier + 10_000,
            command: "Gloss.real",
            executablePath: "/tmp/Gloss PDF QA.app/Contents/MacOS/Gloss.real",
            bundleIdentifier: identityMatchesGloss
                ? "com.samsoncj.gloss.pdfqa"
                : "com.example.unrelated",
            applicationName: identityMatchesGloss ? "Gloss PDF QA" : "Other App",
            launchDate: launchDate,
            endpoint: "127.0.0.1:8787",
            serviceVersion: identityMatchesGloss ? "0.5.4" : nil,
            identityMatchesGloss: identityMatchesGloss,
            healthVerified: healthVerified,
            isOlderThanCurrentProcess: isOlder
        )
    }

    @MainActor
    private func makeListenerFixture(
        ignoringTermination: Bool = false
    ) async throws -> ListenerFixture {
        for _ in 0..<12 {
            let port = UInt16.random(in: 20_000...50_000)
            let process = Process()
            if ignoringTermination {
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [
                    "-c",
                    "trap '' TERM; exec /usr/bin/nc -l 127.0.0.1 \(port)",
                ]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
                process.arguments = ["-l", "127.0.0.1", "\(port)"]
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            let fixture = ListenerFixture(process: process, port: port)
            let manager = BridgePortManager(port: port)
            for _ in 0..<30 {
                if let occupant = try? await manager.inspect(token: nil),
                    occupant.processIdentifier == process.processIdentifier
                {
                    return fixture
                }
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(40))
            }
            fixture.stop()
        }
        throw ListenerFixtureError.couldNotBind
    }

    @MainActor
    private func waitForOccupant(
        processIdentifier: pid_t,
        manager: BridgePortManager
    ) async throws -> BridgePortOccupant {
        for _ in 0..<30 {
            if let occupant = try await manager.inspect(token: nil),
                occupant.processIdentifier == processIdentifier
            {
                return occupant
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw ListenerFixtureError.listenerNotFound
    }
}

private final class ListenerFixture {
    let process: Process
    let port: UInt16

    init(process: Process, port: UInt16) {
        self.process = process
        self.port = port
    }

    func stop() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}

private enum ListenerFixtureError: Error {
    case couldNotBind
    case listenerNotFound
}
