import CoreGraphics
import CryptoKit
import Foundation

public enum DocumentBlockSource: String, Codable, Sendable {
    case embeddedText
    case ocr
}

public struct DocumentBlock: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let pageIndex: Int
    public let blockIndex: Int
    public let sourceText: String
    public let sourceDigest: String
    public let source: DocumentBlockSource
    public let boundingRects: [CGRect]

    public init(
        id: String,
        pageIndex: Int,
        blockIndex: Int,
        sourceText: String,
        sourceDigest: String,
        source: DocumentBlockSource,
        boundingRects: [CGRect] = []
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.blockIndex = blockIndex
        self.sourceText = sourceText
        self.sourceDigest = sourceDigest
        self.source = source
        self.boundingRects = boundingRects
    }
}

public struct DocumentLine: Equatable, Sendable {
    public let text: String
    public let bounds: CGRect

    public init(text: String, bounds: CGRect) {
        self.text = text
        self.bounds = bounds
    }
}

public enum DocumentBlockSegmenter {
    public static func blocks(
        from text: String,
        pageIndex: Int,
        source: DocumentBlockSource = .embeddedText,
        maximumCharacters: Int = 1_600
    ) -> [DocumentBlock] {
        let maximumCharacters = max(200, maximumCharacters)
        let paragraphs = paragraphs(from: text)
            .flatMap { split($0, maximumCharacters: maximumCharacters) }
            .filter { !$0.isEmpty }

        return paragraphs.enumerated().map { blockIndex, paragraph in
            let digest = DocumentDigest.text(paragraph)
            return DocumentBlock(
                id: "p\(pageIndex + 1)-b\(blockIndex + 1)-\(digest.prefix(12))",
                pageIndex: pageIndex,
                blockIndex: blockIndex,
                sourceText: paragraph,
                sourceDigest: digest,
                source: source,
                boundingRects: []
            )
        }
    }

    public static func blocks(
        from lines: [DocumentLine],
        pageIndex: Int,
        source: DocumentBlockSource = .embeddedText,
        maximumCharacters: Int = 1_600
    ) -> [DocumentBlock] {
        let lines = lines.compactMap { line -> DocumentLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return DocumentLine(text: text, bounds: line.bounds)
        }
        guard !lines.isEmpty else { return [] }

        let heights = lines.map(\.bounds.height).filter { $0 > 0 }.sorted()
        let medianHeight = heights.isEmpty ? 12 : heights[heights.count / 2]
        var groups: [[DocumentLine]] = []

        for line in lines {
            guard let previous = groups.last?.last else {
                groups.append([line])
                continue
            }
            if startsNewParagraph(
                line,
                after: previous,
                medianLineHeight: medianHeight
            ) {
                groups.append([line])
            } else {
                groups[groups.count - 1].append(line)
            }
        }

        var result: [DocumentBlock] = []
        for group in groups {
            guard let paragraph = joinLines(group.map(\.text)) else { continue }
            let chunks = split(paragraph, maximumCharacters: max(200, maximumCharacters))
            for chunk in chunks {
                let digest = DocumentDigest.text(chunk)
                let blockIndex = result.count
                result.append(
                    DocumentBlock(
                        id: "p\(pageIndex + 1)-b\(blockIndex + 1)-\(digest.prefix(12))",
                        pageIndex: pageIndex,
                        blockIndex: blockIndex,
                        sourceText: chunk,
                        sourceDigest: digest,
                        source: source,
                        boundingRects: group.map(\.bounds)
                    )
                )
            }
        }
        return result
    }

    private static func paragraphs(from text: String) -> [String] {
        let normalized =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var groups: [[String]] = []
        var current: [String] = []
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }

        return groups.compactMap(joinLines)
    }

    private static func joinLines(_ lines: [String]) -> String? {
        var result = ""
        for line in lines {
            guard !line.isEmpty else { continue }
            if result.isEmpty {
                result = line
                continue
            }

            if result.last == "-",
                let first = line.first,
                first.isLowercase
            {
                result.removeLast()
                result += line
            } else {
                result += " " + line
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func startsNewParagraph(
        _ line: DocumentLine,
        after previous: DocumentLine,
        medianLineHeight: CGFloat
    ) -> Bool {
        if line.bounds.midY > previous.bounds.midY + medianLineHeight * 1.5 {
            return true
        }

        let horizontalGap = line.bounds.minX - previous.bounds.maxX
        if abs(line.bounds.midY - previous.bounds.midY) < medianLineHeight * 0.7,
            horizontalGap > medianLineHeight * 1.2
        {
            return true
        }

        let verticalGap = previous.bounds.minY - line.bounds.maxY
        if verticalGap > max(4, medianLineHeight * 0.55) {
            return true
        }

        let current = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isListStart(current) {
            return true
        }
        if isListStart(previous.text),
            line.bounds.minX - previous.bounds.minX > medianLineHeight * 0.75
        {
            return true
        }

        let indentationChange = abs(line.bounds.minX - previous.bounds.minX)
        if indentationChange > medianLineHeight * 2,
            endsSentence(previous.text)
        {
            return true
        }
        return false
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".!?。！？；;:".contains(last)
    }

    private static func isListStart(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^(?:\d{1,3}[.)]|[•●▪◦*-])\s+"#,
            options: .regularExpression
        ) != nil
    }

    private static func split(_ paragraph: String, maximumCharacters: Int) -> [String] {
        var remaining = paragraph[...]
        var chunks: [String] = []
        let preferredMinimum = maximumCharacters / 2
        let punctuation = CharacterSet(charactersIn: ".!?。！？；;:")

        while remaining.count > maximumCharacters {
            let hardEnd = remaining.index(
                remaining.startIndex,
                offsetBy: maximumCharacters
            )
            let prefix = remaining[..<hardEnd]
            var splitIndex: String.Index?

            for index in prefix.indices.reversed() {
                let character = prefix[index]
                let distance = prefix.distance(from: prefix.startIndex, to: index)
                guard distance >= preferredMinimum else { break }
                if character.isWhitespace
                    || character.unicodeScalars.allSatisfy(punctuation.contains)
                {
                    splitIndex = prefix.index(after: index)
                    break
                }
            }

            let end = splitIndex ?? hardEnd
            let chunk = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            remaining = remaining[end...]
            while remaining.first?.isWhitespace == true {
                remaining.removeFirst()
            }
        }

        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            chunks.append(tail)
        }
        return chunks
    }
}

public enum DocumentDigest {
    public static func text(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    public static func file(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct DocumentTranslationCacheKey: Codable, Equatable, Hashable, Sendable {
    public let documentDigest: String
    public let pageIndex: Int
    public let blockIndex: Int
    public let sourceDigest: String
    public let targetLanguage: String
    public let profile: TranslationProfile
    public let providerRevision: String

    public init(
        documentDigest: String,
        pageIndex: Int,
        blockIndex: Int,
        sourceDigest: String,
        targetLanguage: String,
        profile: TranslationProfile,
        providerRevision: String
    ) {
        self.documentDigest = documentDigest
        self.pageIndex = pageIndex
        self.blockIndex = blockIndex
        self.sourceDigest = sourceDigest
        self.targetLanguage = targetLanguage
        self.profile = profile
        self.providerRevision = providerRevision
    }
}

public actor DocumentTranslationStore {
    private struct Record: Codable, Sendable {
        let key: DocumentTranslationCacheKey
        let translation: String
        let updatedAt: Date
    }

    private static let maximumFileSize = 50 * 1_024 * 1_024
    private static let maximumTranslationLength = 20_000

    private let fileURL: URL
    private let limit: Int
    private var cachedRecords: [DocumentTranslationCacheKey: Record]?
    private var recordOrder: [DocumentTranslationCacheKey] = []

    public init(limit: Int = 12_000) {
        let root =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
        fileURL =
            root
            .appendingPathComponent("Gloss", isDirectory: true)
            .appendingPathComponent("document-translations.json", isDirectory: false)
        self.limit = max(1, limit)
    }

    package init(fileURL: URL, limit: Int = 12_000) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
    }

    public func values(
        for keys: [DocumentTranslationCacheKey]
    ) throws -> [DocumentTranslationCacheKey: String] {
        let records = try loadIfNeeded()
        return Dictionary(
            uniqueKeysWithValues: keys.compactMap { key in
                records[key].map { (key, $0.translation) }
            }
        )
    }

    public func record(
        _ translations: [DocumentTranslationCacheKey: String]
    ) throws {
        guard !translations.isEmpty else { return }
        var records = try loadIfNeeded()
        let now = Date()

        for (key, value) in translations {
            let value = String(
                value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(Self.maximumTranslationLength)
            )
            guard !value.isEmpty else { continue }
            records[key] = Record(key: key, translation: value, updatedAt: now)
            recordOrder.removeAll { $0 == key }
            recordOrder.insert(key, at: 0)
        }

        if recordOrder.count > limit {
            for key in recordOrder.dropFirst(limit) {
                records.removeValue(forKey: key)
            }
            recordOrder.removeLast(recordOrder.count - limit)
        }

        try persist(records)
        cachedRecords = records
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        cachedRecords = [:]
        recordOrder = []
    }

    private func loadIfNeeded() throws -> [DocumentTranslationCacheKey: Record] {
        if let cachedRecords { return cachedRecords }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedRecords = [:]
            recordOrder = []
            return [:]
        }

        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= Self.maximumFileSize else {
            archiveUnreadableFile()
            cachedRecords = [:]
            recordOrder = []
            return [:]
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let decoded = try JSONDecoder().decode([Record].self, from: data)
            var records: [DocumentTranslationCacheKey: Record] = [:]
            var order: [DocumentTranslationCacheKey] = []
            for record in decoded.prefix(limit) where records[record.key] == nil {
                let translation = String(record.translation.prefix(Self.maximumTranslationLength))
                guard !translation.isEmpty else { continue }
                records[record.key] = Record(
                    key: record.key,
                    translation: translation,
                    updatedAt: record.updatedAt
                )
                order.append(record.key)
            }
            cachedRecords = records
            recordOrder = order
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return records
        } catch {
            archiveUnreadableFile()
            cachedRecords = [:]
            recordOrder = []
            return [:]
        }
    }

    private func persist(_ records: [DocumentTranslationCacheKey: Record]) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let orderedRecords = recordOrder.compactMap { records[$0] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(orderedRecords)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
