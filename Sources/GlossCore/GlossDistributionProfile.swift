import Foundation

/// Capabilities that depend on how the current Gloss build was distributed.
///
/// Homebrew releases use an ad-hoc signature, which cannot pair a Safari App
/// Extension with its containing App. Apple-signed builds set the bundle flag
/// to keep Safari available.
public struct GlossDistributionProfile: Equatable, Sendable {
    public let safariExtensionAvailable: Bool

    public init(safariExtensionAvailable: Bool) {
        self.safariExtensionAvailable = safariExtensionAvailable
    }

    public static let current = resolve()

    public static func resolve(
        bundleValue: Bool? = Bundle.main.object(
            forInfoDictionaryKey: "GlossSafariExtensionAvailable"
        ) as? Bool,
        executableURL: URL? = Bundle.main.executableURL,
        workingDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> GlossDistributionProfile {
        if let bundleValue {
            return GlossDistributionProfile(
                safariExtensionAvailable: bundleValue
            )
        }

        if var candidate = executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent()
        {
            for _ in 0..<10 {
                if candidate.pathExtension.lowercased() == "app",
                    let value = safariExtensionValue(
                        in: candidate.appendingPathComponent(
                            "Contents/Info.plist"
                        )
                    )
                {
                    return GlossDistributionProfile(
                        safariExtensionAvailable: value
                    )
                }
                if let value = safariExtensionValue(
                    in: candidate.appendingPathComponent(
                        "Resources/Info.plist"
                    )
                ) {
                    return GlossDistributionProfile(
                        safariExtensionAvailable: value
                    )
                }
                let parent = candidate.deletingLastPathComponent()
                guard parent.path != candidate.path else { break }
                candidate = parent
            }
        }

        let checkoutValue = safariExtensionValue(
            in: workingDirectoryURL.appendingPathComponent(
                "Resources/Info.plist"
            )
        )
        return GlossDistributionProfile(
            safariExtensionAvailable: checkoutValue ?? false
        )
    }

    private static func safariExtensionValue(in plistURL: URL) -> Bool? {
        guard let data = try? Data(contentsOf: plistURL),
            let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let dictionary = value as? [String: Any]
        else {
            return nil
        }
        return dictionary["GlossSafariExtensionAvailable"] as? Bool
    }
}
