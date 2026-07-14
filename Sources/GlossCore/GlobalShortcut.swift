import CoreGraphics
import Foundation

public struct GlobalShortcut: Equatable, Sendable {
    public static let defaultValue = GlobalShortcut(
        keyCode: 5,
        modifiers: CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue,
        keyLabel: "G"
    )!

    private static let defaultsKey = "globalShortcut"
    private static let modifierSymbols: [(UInt64, String)] = [
        (CGEventFlags.maskControl.rawValue, "⌃"),
        (CGEventFlags.maskAlternate.rawValue, "⌥"),
        (CGEventFlags.maskShift.rawValue, "⇧"),
        (CGEventFlags.maskCommand.rawValue, "⌘"),
    ]
    private static let allowedModifierMask = modifierSymbols.reduce(UInt64(0)) { result, item in
        result | item.0
    }
    private static let primaryModifierMask =
        CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskCommand.rawValue

    public let keyCode: Int64
    public let modifiers: UInt64
    public let keyLabel: String

    public init?(keyCode: Int64, modifiers: UInt64, keyLabel: String) {
        let normalizedModifiers = modifiers & Self.allowedModifierMask
        let normalizedLabel = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyCode >= 0,
            normalizedModifiers & Self.primaryModifierMask != 0,
            normalizedModifiers.nonzeroBitCount >= 2,
            !normalizedLabel.isEmpty,
            normalizedLabel.count <= 8,
            normalizedLabel.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else { return nil }

        self.keyCode = keyCode
        self.modifiers = normalizedModifiers
        self.keyLabel = normalizedLabel
    }

    public var displayName: String {
        let prefix = Self.modifierSymbols.compactMap { mask, symbol in
            modifiers & mask != 0 ? symbol : nil
        }.joined()
        return prefix + keyLabel
    }

    public func matches(keyCode: Int64, modifiers eventModifiers: UInt64) -> Bool {
        keyCode == self.keyCode
            && eventModifiers & Self.allowedModifierMask == modifiers
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(
            [
                "keyCode": keyCode,
                "modifiers": modifiers,
                "keyLabel": keyLabel,
            ],
            forKey: Self.defaultsKey
        )
    }

    public static func load(from defaults: UserDefaults = .standard) -> GlobalShortcut {
        guard let value = defaults.dictionary(forKey: defaultsKey),
            let keyCode = (value["keyCode"] as? NSNumber)?.int64Value,
            let modifiers = (value["modifiers"] as? NSNumber)?.uint64Value,
            let keyLabel = value["keyLabel"] as? String,
            let shortcut = GlobalShortcut(
                keyCode: keyCode,
                modifiers: modifiers,
                keyLabel: keyLabel
            )
        else { return defaultValue }
        return shortcut
    }
}
