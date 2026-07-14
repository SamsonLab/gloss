import Foundation

public final class GlossRuntimeLog: @unchecked Sendable {
    public static let shared = GlossRuntimeLog()

    public static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Gloss", isDirectory: true)
    }

    public static var fileURL: URL {
        directoryURL.appendingPathComponent("gloss.log")
    }

    public static var codexStderrURL: URL {
        directoryURL.appendingPathComponent("codex-stderr.log")
    }

    private let directory: URL
    private let maximumBytes: Int
    private let lock = NSLock()
    private let timestampFormatter = ISO8601DateFormatter()

    init(
        directory: URL = GlossRuntimeLog.directoryURL,
        maximumBytes: Int = 5 * 1_024 * 1_024
    ) {
        self.directory = directory
        self.maximumBytes = max(1_024, maximumBytes)
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectory()
        try prepareFile(at: directory.appendingPathComponent("gloss.log"))
        try prepareFile(at: directory.appendingPathComponent("codex-stderr.log"))
    }

    public func write(_ category: String, _ message: String) {
        let cleanCategory = oneLine(category, limit: 80)
        let cleanMessage = oneLine(message, limit: 4_000)

        lock.lock()
        defer { lock.unlock() }
        do {
            let timestamp = timestampFormatter.string(from: Date())
            let data = Data("\(timestamp) [\(cleanCategory)] \(cleanMessage)\n".utf8)
            try append(data, to: directory.appendingPathComponent("gloss.log"))
        } catch {
            // Diagnostics must never interrupt translation.
        }
    }

    public func appendCodexStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try append(data, to: directory.appendingPathComponent("codex-stderr.log"))
        } catch {
            // Diagnostics must never interrupt translation.
        }
    }

    private func append(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        try prepareFile(at: url)
        try rotateIfNeeded(url, incomingBytes: data.count)
        try prepareFile(at: url)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data.suffix(maximumBytes))
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func prepareFile(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func rotateIfNeeded(_ url: URL, incomingBytes: Int) throws {
        let currentBytes =
            try FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? Int ?? 0
        guard currentBytes + incomingBytes > maximumBytes else { return }

        let backup = url.appendingPathExtension("1")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: backup)
        }
    }

    private func oneLine(_ value: String, limit: Int) -> String {
        let flattened =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return String(flattened.prefix(limit))
    }
}
