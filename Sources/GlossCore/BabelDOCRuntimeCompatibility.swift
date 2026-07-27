import Foundation

public enum BabelDOCManagedRuntimePreparation: Equatable, Sendable {
    case install
    case installAvailableUpdate
    case useCurrent
    case updateRequired(currentVersion: String)
}

public enum BabelDOCRuntimeCompatibility {
    public static let minimumManagedVersion = "0.6.4+gloss.5"

    public static func isCompatible(_ version: String?) -> Bool {
        guard let version = parsedVersion(version) else { return false }
        let minimumCore = [0, 6, 4]
        if version.core != minimumCore {
            return version.core.lexicographicallyPrecedes(minimumCore) == false
        }
        return version.glossRevision.map { $0 >= 5 } ?? false
    }

    public static func preparation(
        for snapshot: BabelDOCRuntimeSnapshot?
    ) -> BabelDOCManagedRuntimePreparation {
        guard let snapshot, snapshot.currentExecutableURL != nil else {
            return .install
        }
        if isCompatible(snapshot.currentVersion) {
            return .useCurrent
        }
        return snapshot.updateAvailable
            ? .installAvailableUpdate
            : .updateRequired(
                currentVersion: snapshot.currentVersion ?? "unknown"
            )
    }

    private static func parsedVersion(
        _ value: String?
    ) -> (core: [Int], glossRevision: Int?)? {
        guard let value,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            !value.contains("-")
        else {
            return nil
        }

        let versionAndMetadata = value.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            let core = parseNumericComponents(
                String(versionAndMetadata[0]),
                count: 3
            )
        else {
            return nil
        }

        guard versionAndMetadata.count == 2 else {
            return (core, nil)
        }
        let metadata = versionAndMetadata[1].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard metadata.count == 2,
            metadata[0] == "gloss",
            let revision = parseNumericComponent(metadata[1])
        else {
            return nil
        }
        return (core, revision)
    }

    private static func parseNumericComponents(
        _ value: String,
        count: Int
    ) -> [Int]? {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == count else { return nil }
        let values = components.compactMap(parseNumericComponent)
        return values.count == count ? values : nil
    }

    private static func parseNumericComponent(
        _ value: Substring
    ) -> Int? {
        guard !value.isEmpty,
            value.allSatisfy(\.isNumber),
            value.count == 1 || value.first != "0"
        else {
            return nil
        }
        return Int(value)
    }
}

/// Resolves the Gloss product version for a standalone helper executable.
///
/// A helper inside `Gloss.app/Contents/Helpers` does not always receive the app
/// bundle as `Bundle.main`. Homebrew may also invoke it through a symlink. Walk
/// from the resolved executable first, then support a package checkout's
/// `Resources/Info.plist` for `swift run gloss-cli`.
public enum GlossProductVersionResolver {
    public static func resolve(
        bundleVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        executableURL: URL? = Bundle.main.executableURL,
        workingDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> String? {
        if let bundleVersion = normalized(bundleVersion) {
            return bundleVersion
        }

        if var candidate = executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent()
        {
            for _ in 0..<10 {
                if candidate.pathExtension.lowercased() == "app",
                    let version = version(
                        in: candidate.appendingPathComponent(
                            "Contents/Info.plist"
                        )
                    )
                {
                    return version
                }
                if let version = version(
                    in: candidate.appendingPathComponent(
                        "Resources/Info.plist"
                    )
                ) {
                    return version
                }
                let parent = candidate.deletingLastPathComponent()
                guard parent.path != candidate.path else { break }
                candidate = parent
            }
        }

        return version(
            in: workingDirectoryURL.appendingPathComponent(
                "Resources/Info.plist"
            )
        )
    }

    private static func version(in plistURL: URL) -> String? {
        guard let data = try? Data(contentsOf: plistURL),
            let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let dictionary = value as? [String: Any]
        else { return nil }
        return normalized(
            dictionary["CFBundleShortVersionString"] as? String
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard
            let value = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
