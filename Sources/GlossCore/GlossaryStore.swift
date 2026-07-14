import Foundation

public struct GlossaryTerm: Equatable, Hashable, Sendable {
    public let source: String
    public let target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

public enum GlossaryError: LocalizedError, Equatable {
    case tooManyTerms
    case invalidTerm(Int)
    case duplicateSource(String)

    public var errorDescription: String? {
        switch self {
        case .tooManyTerms:
            "术语表不能超过 1,000 条。"
        case .invalidTerm(let line):
            "术语表第 \(line) 行无效。每行需要用 Tab 分隔原文和译文，且各不超过 200 个字符。"
        case .duplicateSource(let source):
            "术语表包含重复原文：\(source)"
        }
    }
}

public actor GlossaryStore {
    private static let maximumTerms = 1_000
    private static let maximumTermLength = 200
    private static let maximumFileSize = 1_024 * 1_024
    private static let maximumMatchingCorpusLength = 100_000

    public nonisolated let fileURL: URL
    private var cachedTerms: [GlossaryTerm]?

    public init() {
        let root =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
        fileURL =
            root
            .appendingPathComponent("Gloss", isDirectory: true)
            .appendingPathComponent("glossary.tsv", isDirectory: false)
    }

    package init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func terms() throws -> [GlossaryTerm] {
        try loadIfNeeded()
    }

    public func reload() throws -> [GlossaryTerm] {
        cachedTerms = nil
        return try loadIfNeeded()
    }

    public func replace(with terms: [GlossaryTerm]) throws {
        let terms = try Self.normalized(terms)
        try persist(terms)
        cachedTerms = terms
    }

    public func matchingTerms(
        in sourceTexts: [String],
        limit: Int = 40
    ) throws -> [GlossaryTerm] {
        guard limit > 0 else { return [] }
        let terms = try loadIfNeeded()
        guard !terms.isEmpty else { return [] }

        let corpus = String(
            sourceTexts.joined(separator: "\n")
                .prefix(Self.maximumMatchingCorpusLength)
        ).foldedForGlossaryMatching
        return terms.filter { corpus.contains($0.source.foldedForGlossaryMatching) }
            .sorted {
                if $0.source.count == $1.source.count {
                    return $0.source.localizedStandardCompare($1.source) == .orderedAscending
                }
                return $0.source.count > $1.source.count
            }
            .prefix(limit)
            .map { $0 }
    }

    private func loadIfNeeded() throws -> [GlossaryTerm] {
        if let cachedTerms { return cachedTerms }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedTerms = []
            return []
        }

        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= Self.maximumFileSize else {
            archiveUnreadableFile()
            cachedTerms = []
            return []
        }

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let terms: [GlossaryTerm]
        do {
            terms = try Self.parse(contents)
        } catch {
            archiveUnreadableFile()
            cachedTerms = []
            return []
        }
        cachedTerms = terms
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return terms
    }

    private func persist(_ terms: [GlossaryTerm]) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let contents = terms.map { "\($0.source)\t\($0.target)" }.joined(separator: "\n")
        let data = Data((contents + (terms.isEmpty ? "" : "\n")).utf8)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func parse(_ contents: String) throws -> [GlossaryTerm] {
        var terms: [GlossaryTerm] = []
        for (offset, rawLine) in contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline
        ).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw GlossaryError.invalidTerm(offset + 1) }
            terms.append(GlossaryTerm(source: String(fields[0]), target: String(fields[1])))
        }
        return try normalized(terms)
    }

    private static func normalized(_ terms: [GlossaryTerm]) throws -> [GlossaryTerm] {
        guard terms.count <= maximumTerms else { throw GlossaryError.tooManyTerms }
        var seen: Set<String> = []
        return try terms.enumerated().map { offset, term in
            let source = term.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = term.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty,
                !target.isEmpty,
                source.count <= maximumTermLength,
                target.count <= maximumTermLength,
                !source.contains("\t"),
                !target.contains("\t"),
                !source.contains(where: \Character.isNewline),
                !target.contains(where: \Character.isNewline)
            else { throw GlossaryError.invalidTerm(offset + 1) }

            let key = source.foldedForGlossaryMatching
            guard seen.insert(key).inserted else {
                throw GlossaryError.duplicateSource(source)
            }
            return GlossaryTerm(source: source, target: target)
        }
    }

    private func archiveUnreadableFile() {
        let fileManager = FileManager.default
        let archivedURL = fileURL.deletingPathExtension()
            .appendingPathExtension(
                "unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).tsv"
            )
        try? fileManager.moveItem(at: fileURL, to: archivedURL)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archivedURL.path)
    }
}

extension String {
    fileprivate var foldedForGlossaryMatching: String {
        folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
