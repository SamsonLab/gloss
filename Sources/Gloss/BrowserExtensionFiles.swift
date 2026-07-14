import Foundation

enum BrowserExtensionFiles {
    private static let directoryName = "BrowserExtension"
    private static let configurationName = "gloss-config.js"
    private static let markerName = ".gloss-managed"

    static func installBundledCopy(pairingToken: String) throws -> URL {
        let fileManager = FileManager.default
        guard let resources = Bundle.main.resourceURL else {
            throw BrowserExtensionError.bundleResourcesUnavailable
        }

        let source = resources.appendingPathComponent(directoryName, isDirectory: true)
        let sourceManifest = source.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: sourceManifest.path) else {
            throw BrowserExtensionError.notBundled
        }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let glossDirectory = applicationSupport.appendingPathComponent("Gloss", isDirectory: true)
        try fileManager.createDirectory(
            at: glossDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let destination = glossDirectory.appendingPathComponent(directoryName, isDirectory: true)
        if try installedVersion(at: destination) == manifestVersion(at: sourceManifest),
            try contentsMatch(
                source: source,
                destination: destination,
                pairingToken: pairingToken
            )
        {
            return destination
        }

        if fileManager.fileExists(atPath: destination.path) {
            let marker = destination.appendingPathComponent(markerName)
            guard fileManager.fileExists(atPath: marker.path) else {
                throw BrowserExtensionError.unmanagedDestination(destination.path)
            }
        }

        let staging = glossDirectory.appendingPathComponent(
            ".\(directoryName)-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.copyItem(at: source, to: staging)
        let configuration = staging.appendingPathComponent(configurationName)
        try pairingConfiguration(for: pairingToken).write(to: configuration, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configuration.path
        )
        try Data("Managed by Gloss.\n".utf8).write(
            to: staging.appendingPathComponent(markerName),
            options: .atomic
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }

    static func contentsMatch(
        source: URL,
        destination: URL,
        pairingToken: String? = nil
    ) throws -> Bool {
        let sourceFiles = try relativeFiles(in: source)
        let destinationFiles = try relativeFiles(in: destination).filter { $0 != markerName }
        guard sourceFiles == destinationFiles else { return false }

        return try sourceFiles.allSatisfy { relativePath in
            if relativePath == configurationName, let pairingToken {
                return try Data(
                    contentsOf: destination.appendingPathComponent(relativePath)
                ) == pairingConfiguration(for: pairingToken)
            }
            return FileManager.default.contentsEqual(
                atPath: source.appendingPathComponent(relativePath).path,
                andPath: destination.appendingPathComponent(relativePath).path
            )
        }
    }

    static func pairingConfiguration(for token: String) throws -> Data {
        let encodedToken = try JSONEncoder().encode(token)
        guard let tokenLiteral = String(data: encodedToken, encoding: .utf8) else {
            throw BrowserExtensionError.invalidPairingToken
        }
        return Data("globalThis.GLOSS_PAIRING_TOKEN = \(tokenLiteral);\n".utf8)
    }

    private static func installedVersion(at directory: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let marker = directory.appendingPathComponent(markerName)
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        return try manifestVersion(at: directory.appendingPathComponent("manifest.json"))
    }

    private static func manifestVersion(at url: URL) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let manifest = object as? [String: Any],
            let version = manifest["version"] as? String,
            !version.isEmpty
        else {
            throw BrowserExtensionError.invalidManifest
        }
        return version
    }

    private static func relativeFiles(in directory: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: { _, _ in false }
            )
        else { return [] }

        let root = directory.standardizedFileURL.path + "/"
        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { continue }
            files.append(String(path.dropFirst(root.count)))
        }
        return files.sorted()
    }
}

private enum BrowserExtensionError: LocalizedError {
    case bundleResourcesUnavailable
    case invalidManifest
    case invalidPairingToken
    case notBundled
    case unmanagedDestination(String)

    var errorDescription: String? {
        switch self {
        case .bundleResourcesUnavailable:
            "无法读取 Gloss 资源目录。"
        case .invalidManifest:
            "浏览器扩展清单无效。"
        case .invalidPairingToken:
            "无法生成浏览器扩展配对配置。"
        case .notBundled:
            "当前构建未包含浏览器扩展，请使用打包后的 Gloss.app。"
        case .unmanagedDestination(let path):
            "不会覆盖非 Gloss 管理的扩展目录：\(path)"
        }
    }
}
