import Foundation
import Security

enum PairingTokenStore {
    private static let directoryName = "Gloss"
    private static let fileName = "browser-pairing-token"
    private static let safariAppGroup = "group.com.samsoncj.gloss"
    private static let safariSharingQueue = DispatchQueue(
        label: "com.samsoncj.gloss.safari-pairing",
        qos: .utility
    )

    static func loadOrCreate() throws -> String {
        let fileManager = FileManager.default
        let directory = try applicationSupportDirectory()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let tokenURL = directory.appendingPathComponent(fileName, isDirectory: false)
        if fileManager.fileExists(atPath: tokenURL.path) {
            let token = try load(from: tokenURL)
            shareWithSafari(token)
            return token
        }

        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw TokenError("无法生成安全的浏览器配对令牌。")
        }
        let token = Data(random)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        try Data(token.utf8).write(to: tokenURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        shareWithSafari(token)
        return token
    }

    private static func shareWithSafari(_ token: String) {
        safariSharingQueue.async {
            UserDefaults(suiteName: safariAppGroup)?.set(token, forKey: fileName)
        }
    }

    private static func applicationSupportDirectory() throws -> URL {
        guard
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw TokenError("无法定位 Application Support。")
        }
        return root.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func load(from url: URL) throws -> String {
        let token = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let validBytes = token.utf8.allSatisfy {
            (48...57).contains($0)
                || (65...90).contains($0)
                || (97...122).contains($0)
                || $0 == 45
                || $0 == 95
        }
        guard token.count == 43, validBytes else {
            throw TokenError("浏览器配对令牌文件无效。")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    private struct TokenError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
