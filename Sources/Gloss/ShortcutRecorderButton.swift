import AppKit
import GlossCore

@MainActor
final class ShortcutRecorderButton: NSButton {
    var onChange: ((GlobalShortcut) -> Void)?

    private var shortcut: GlobalShortcut
    private var isRecording = false

    init(shortcut: GlobalShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func show(_ shortcut: GlobalShortcut) {
        self.shortcut = shortcut
        if !isRecording {
            updateTitle()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat else { return }
        if event.keyCode == 53 {
            finishRecording()
            return
        }

        let modifiers = event.modifierFlags.intersection([
            .control, .option, .shift, .command,
        ])
        guard let keyLabel = Self.keyLabel(for: event),
            let shortcut = GlobalShortcut(
                keyCode: Int64(event.keyCode),
                modifiers: UInt64(modifiers.rawValue),
                keyLabel: keyLabel
            )
        else {
            NSSound.beep()
            title = "至少两个修饰键"
            return
        }

        self.shortcut = shortcut
        finishRecording()
        onChange?(shortcut)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isRecording {
            isRecording = false
            updateTitle()
        }
        return resigned
    }

    @objc private func beginRecording() {
        isRecording = true
        title = "请按快捷键…"
        if window?.makeFirstResponder(self) != true {
            isRecording = false
            updateTitle()
        }
    }

    private func finishRecording() {
        isRecording = false
        updateTitle()
        window?.makeFirstResponder(nil)
    }

    private func updateTitle() {
        title = shortcut.displayName
        toolTip = "点击后录制新的全局快捷键；按 Esc 取消"
        setAccessibilityLabel("全局快捷键 \(shortcut.displayName)")
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        let specialKeys: [UInt16: String] = [
            36: "↩",
            48: "⇥",
            49: "Space",
            51: "⌫",
            96: "F5",
            97: "F6",
            98: "F7",
            99: "F3",
            100: "F8",
            101: "F9",
            103: "F11",
            109: "F10",
            111: "F12",
            118: "F4",
            120: "F2",
            122: "F1",
            123: "←",
            124: "→",
            125: "↓",
            126: "↑",
        ]
        if let label = specialKeys[event.keyCode] {
            return label
        }
        guard let characters = event.charactersIgnoringModifiers?.uppercased(),
            !characters.isEmpty,
            characters.count <= 2,
            characters.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else { return nil }
        return characters
    }
}
