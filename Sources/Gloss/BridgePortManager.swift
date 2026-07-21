import AppKit
import Darwin
import Foundation

struct BridgePortOccupant: Equatable, Sendable {
    let processIdentifier: pid_t
    let command: String
    let executablePath: String?
    let bundleIdentifier: String?
    let applicationName: String?
    let launchDate: Date?
    let endpoint: String
    let serviceVersion: String?
    let identityMatchesGloss: Bool
    let healthVerified: Bool
    let isOlderThanCurrentProcess: Bool

    var displayName: String {
        applicationName ?? command
    }

    var isVerifiedGloss: Bool {
        identityMatchesGloss && healthVerified
    }

    var canAutomaticallyTerminate: Bool {
        isVerifiedGloss && isOlderThanCurrentProcess
            && processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    func identifiesSameProcess(as other: BridgePortOccupant) -> Bool {
        guard processIdentifier == other.processIdentifier else { return false }
        if let launchDate, let otherLaunchDate = other.launchDate {
            return abs(launchDate.timeIntervalSince(otherLaunchDate)) < 0.01
        }
        if let executablePath, let otherExecutablePath = other.executablePath {
            return executablePath == otherExecutablePath
        }
        return command == other.command && bundleIdentifier == other.bundleIdentifier
    }
}

enum BridgePortManagerError: LocalizedError, Equatable {
    case inspectionFailed(String)
    case currentProcess
    case occupantChanged
    case unverifiedOccupant
    case terminationFailed(String)
    case portStillOccupied

    var errorDescription: String? {
        switch self {
        case .inspectionFailed(let reason):
            "无法检查本地桥接端口：\(reason)"
        case .currentProcess:
            "不能终止当前 Gloss 实例。"
        case .occupantChanged:
            "端口占用者已经变化，请重新检查后再试。"
        case .unverifiedOccupant:
            "端口由未确认的进程占用，需要手动确认后才能终止。"
        case .terminationFailed(let reason):
            "无法终止端口占用进程：\(reason)"
        case .portStillOccupied:
            "占用进程已收到终止请求，但端口仍未释放。"
        }
    }
}

@MainActor
final class BridgePortManager {
    struct ListenerSnapshot: Equatable, Sendable {
        let processIdentifier: pid_t
        let command: String
        let endpoint: String
    }

    struct Health: Equatable, Sendable {
        let version: String?
    }

    private struct HealthPayload: Decodable {
        let name: String
        let ok: Bool
        let version: String?
    }

    let port: UInt16
    private let currentProcessIdentifier: pid_t
    private let currentLaunchDate: Date
    private let allowedBundleIdentifiers: Set<String>

    init(
        port: UInt16 = 8_787,
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        currentLaunchDate: Date = NSRunningApplication.current.launchDate ?? Date(),
        currentBundleIdentifier: String = Bundle.main.bundleIdentifier
            ?? "com.samsoncj.gloss"
    ) {
        self.port = port
        self.currentProcessIdentifier = currentProcessIdentifier
        self.currentLaunchDate = currentLaunchDate
        self.allowedBundleIdentifiers = [
            currentBundleIdentifier,
            "com.samsoncj.gloss",
            "com.samsoncj.gloss.pdfqa",
        ]
    }

    func inspect(token: String?) async throws -> BridgePortOccupant? {
        guard let listener = try await listenerSnapshot() else { return nil }
        let application = NSRunningApplication(
            processIdentifier: listener.processIdentifier
        )
        let executablePath =
            application?.executableURL?.path
            ?? Self.executablePath(for: listener.processIdentifier)
        let appBundleURL =
            application?.bundleURL
            ?? executablePath.flatMap(Self.enclosingApplicationBundleURL)
        let bundle = appBundleURL.flatMap(Bundle.init(url:))
        let bundleIdentifier =
            application?.bundleIdentifier
            ?? bundle?.bundleIdentifier
        let identityMatchesGloss =
            bundleIdentifier.map {
                allowedBundleIdentifiers.contains($0)
            } ?? false
        let health: Health? =
            if identityMatchesGloss, let token {
                await probeHealth(token: token, timeout: 0.8)
            } else {
                nil
            }
        let launchDate = application?.launchDate
        let isOlder = launchDate.map { $0 < currentLaunchDate } ?? false

        return BridgePortOccupant(
            processIdentifier: listener.processIdentifier,
            command: listener.command,
            executablePath: executablePath,
            bundleIdentifier: bundleIdentifier,
            applicationName: application?.localizedName
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            launchDate: launchDate,
            endpoint: listener.endpoint,
            serviceVersion: health?.version
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            identityMatchesGloss: identityMatchesGloss,
            healthVerified: health != nil,
            isOlderThanCurrentProcess: isOlder
        )
    }

    func waitForHealthyBridge(
        token: String,
        timeout: Duration = .seconds(2)
    ) async -> Health? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard !Task.isCancelled else { return nil }
            if let health = await probeHealth(token: token, timeout: 0.5) {
                return health
            }
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return nil
            }
        }
        return nil
    }

    func terminate(
        _ expected: BridgePortOccupant,
        token: String?,
        allowingUnverified: Bool
    ) async throws {
        guard expected.processIdentifier != currentProcessIdentifier else {
            throw BridgePortManagerError.currentProcess
        }
        guard let current = try await inspect(token: token),
            current.identifiesSameProcess(as: expected)
        else {
            throw BridgePortManagerError.occupantChanged
        }
        try Task.checkCancellation()
        guard current.canAutomaticallyTerminate || allowingUnverified else {
            throw BridgePortManagerError.unverifiedOccupant
        }

        let application = NSRunningApplication(
            processIdentifier: current.processIdentifier
        )
        let requestedGracefulTermination = application?.terminate() ?? false
        if !requestedGracefulTermination {
            try Self.send(signal: SIGTERM, to: current.processIdentifier)
        }
        if try await waitForRelease(of: current, timeout: .seconds(1.5)) {
            return
        }

        try Task.checkCancellation()
        try await revalidate(current, token: token)
        try Self.send(signal: SIGTERM, to: current.processIdentifier)
        if try await waitForRelease(of: current, timeout: .milliseconds(750)) {
            return
        }

        try Task.checkCancellation()
        try await revalidate(current, token: token)
        try Self.send(signal: SIGKILL, to: current.processIdentifier)
        guard try await waitForRelease(of: current, timeout: .seconds(1)) else {
            throw BridgePortManagerError.portStillOccupied
        }
    }

    nonisolated static func parseLSOFOutput(_ output: String) -> ListenerSnapshot? {
        var processIdentifier: pid_t?
        var command: String?
        var endpoint: String?

        func makeSnapshot() -> ListenerSnapshot? {
            guard let processIdentifier, let command, let endpoint else { return nil }
            return ListenerSnapshot(
                processIdentifier: processIdentifier,
                command: command,
                endpoint: endpoint
            )
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let prefix = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch prefix {
            case "p":
                if let snapshot = makeSnapshot() { return snapshot }
                processIdentifier = pid_t(value)
                command = nil
                endpoint = nil
            case "c":
                command = value
            case "n":
                endpoint = value
            default:
                continue
            }
        }
        return makeSnapshot()
    }

    nonisolated static func enclosingApplicationBundleURL(
        for executablePath: String
    ) -> URL? {
        var cursor = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.pathExtension.lowercased() == "app" {
                return cursor
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private func revalidate(
        _ expected: BridgePortOccupant,
        token: String?
    ) async throws {
        guard let current = try await inspect(token: token),
            current.identifiesSameProcess(as: expected)
        else {
            throw BridgePortManagerError.occupantChanged
        }
    }

    private func waitForRelease(
        of expected: BridgePortOccupant,
        timeout: Duration
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            let listener = try? await listenerSnapshot()
            if listener?.processIdentifier != expected.processIdentifier {
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let listener = try? await listenerSnapshot()
        return listener?.processIdentifier != expected.processIdentifier
    }

    private func listenerSnapshot() async throws -> ListenerSnapshot? {
        let port = port
        return try await Task.detached(priority: .utility) {
            try Self.readListenerSnapshot(port: port)
        }.value
    }

    nonisolated private static func readListenerSnapshot(
        port: UInt16
    ) throws -> ListenerSnapshot? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [
            "-nP",
            "-a",
            "-iTCP:\(port)",
            "-sTCP:LISTEN",
            "-Fpcn",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw BridgePortManagerError.inspectionFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        if process.terminationStatus == 1, text.isEmpty {
            return nil
        }
        guard process.terminationStatus == 0 else {
            throw BridgePortManagerError.inspectionFailed(
                "lsof 状态 \(process.terminationStatus)"
            )
        }
        return parseLSOFOutput(text)
    }

    private func probeHealth(token: String, timeout: TimeInterval) async -> Health? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(token, forHTTPHeaderField: "X-Gloss-Token")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let payload = try JSONDecoder().decode(HealthPayload.self, from: data)
            guard payload.ok, payload.name == "Gloss" else { return nil }
            return Health(version: payload.version)
        } catch {
            return nil
        }
    }

    private static func executablePath(for processIdentifier: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(
            processIdentifier,
            &buffer,
            UInt32(buffer.count)
        )
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func send(signal: Int32, to processIdentifier: pid_t) throws {
        guard Darwin.kill(processIdentifier, signal) == 0 else {
            let reason = String(cString: strerror(errno))
            throw BridgePortManagerError.terminationFailed(reason)
        }
    }
}
