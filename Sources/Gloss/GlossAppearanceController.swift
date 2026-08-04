import AppKit

enum GlossAppearancePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var symbolName: String {
        switch self {
        case .system: "display"
        case .light: "sun.max"
        case .dark: "moon.fill"
        }
    }
}

@MainActor
final class GlossAppearanceController {
    static let shared = GlossAppearanceController()
    static let didChangeNotification = Notification.Name(
        "GlossAppearancePreferenceDidChange"
    )

    private let defaultsKey = "appearancePreference"

    private(set) var preference: GlossAppearancePreference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: defaultsKey)
            apply()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    private init() {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey)
        preference = GlossAppearancePreference(rawValue: rawValue ?? "") ?? .system
    }

    func activate() {
        apply()
    }

    func select(_ preference: GlossAppearancePreference) {
        guard self.preference != preference else { return }
        self.preference = preference
    }

    @discardableResult
    func cycle() -> GlossAppearancePreference {
        let next: GlossAppearancePreference =
            switch preference {
            case .system: .dark
            case .dark: .light
            case .light: .system
            }
        select(next)
        return next
    }

    private func apply() {
        NSApp.appearance =
            switch preference {
            case .system:
                nil
            case .light:
                NSAppearance(named: .aqua)
            case .dark:
                NSAppearance(named: .darkAqua)
            }
    }
}
