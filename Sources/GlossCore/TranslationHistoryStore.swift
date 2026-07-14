import Foundation

public struct TranslationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let sourceText: String
    public let translatedText: String
    public let sourceName: String
    public let targetLanguage: String
    public let profile: TranslationProfile
    public let contentKind: TranslationContentKind

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceText: String,
        translatedText: String,
        sourceName: String,
        targetLanguage: String,
        profile: TranslationProfile,
        contentKind: TranslationContentKind
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceName = sourceName
        self.targetLanguage = targetLanguage
        self.profile = profile
        self.contentKind = contentKind
    }
}

public actor TranslationHistoryStore {
    private static let maximumFileSize = 20 * 1_024 * 1_024
    private static let maximumTextLength = 50_000

    private let fileURL: URL
    private let limit: Int
    private var cachedEntries: [TranslationHistoryEntry]?

    public init(limit: Int = 200) {
        let root =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
        fileURL =
            root
            .appendingPathComponent("Gloss", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
        self.limit = max(1, limit)
    }

    package init(fileURL: URL, limit: Int = 200) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
    }

    public func entries() throws -> [TranslationHistoryEntry] {
        try loadIfNeeded()
    }

    public func record(_ entry: TranslationHistoryEntry) throws {
        var entries = try loadIfNeeded()
        let entry = sanitized(entry)
        if let current = entries.first,
            current.sourceText == entry.sourceText,
            current.translatedText == entry.translatedText,
            current.targetLanguage == entry.targetLanguage,
            current.profile == entry.profile
        {
            return
        }

        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        try persist(entries)
        cachedEntries = entries
    }

    public func delete(id: UUID) throws {
        var entries = try loadIfNeeded()
        entries.removeAll { $0.id == id }
        try persist(entries)
        cachedEntries = entries
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        cachedEntries = []
    }

    private func loadIfNeeded() throws -> [TranslationHistoryEntry] {
        if let cachedEntries { return cachedEntries }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedEntries = []
            return []
        }

        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= Self.maximumFileSize else {
            archiveUnreadableFile()
            cachedEntries = []
            return []
        }

        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let entries: [TranslationHistoryEntry]
        do {
            entries = try JSONDecoder().decode([TranslationHistoryEntry].self, from: data)
                .prefix(limit)
                .map(sanitized)
        } catch {
            archiveUnreadableFile()
            cachedEntries = []
            return []
        }
        cachedEntries = entries
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return entries
    }

    private func persist(_ entries: [TranslationHistoryEntry]) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func sanitized(_ entry: TranslationHistoryEntry) -> TranslationHistoryEntry {
        TranslationHistoryEntry(
            id: entry.id,
            createdAt: entry.createdAt,
            sourceText: String(entry.sourceText.prefix(Self.maximumTextLength)),
            translatedText: String(entry.translatedText.prefix(Self.maximumTextLength)),
            sourceName: String(entry.sourceName.prefix(200)),
            targetLanguage: String(entry.targetLanguage.prefix(100)),
            profile: entry.profile,
            contentKind: entry.contentKind
        )
    }

    private func archiveUnreadableFile() {
        let fileManager = FileManager.default
        let archivedURL = fileURL.deletingPathExtension()
            .appendingPathExtension(
                "unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
            )
        try? fileManager.moveItem(at: fileURL, to: archivedURL)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archivedURL.path)
    }
}
