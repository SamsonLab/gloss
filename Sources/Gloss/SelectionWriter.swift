import AppKit
@preconcurrency import ApplicationServices

enum SelectionReplacementResult {
    case replaced
    case replacedWithoutClipboardRestore
    case failed
}

@MainActor
enum SelectionWriter {
    @discardableResult
    static func copy(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    @discardableResult
    static func copySensitive(_ text: String) -> Int? {
        PasteboardPrivacy.writeProtectedText(text, to: .general)
    }

    static func replace(
        _ selection: SelectionSnapshot,
        with text: String
    ) async -> SelectionReplacementResult {
        if let element = selection.element,
            AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            ) == .success
        {
            return .replaced
        }

        guard let processIdentifier = selection.processIdentifier,
            let application = NSRunningApplication(processIdentifier: processIdentifier),
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return .failed }

        guard application.activate() else { return .failed }
        do {
            try await Task.sleep(nanoseconds: 90_000_000)
        } catch {
            return .failed
        }

        let pasteboard = NSPasteboard.general
        guard let snapshot = PasteboardSnapshot(pasteboard) else { return .failed }
        guard let glossChangeCount = PasteboardPrivacy.writeProtectedText(text, to: pasteboard)
        else {
            snapshot.restore(to: pasteboard)
            return .failed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 800_000_000)
        if pasteboard.changeCount == glossChangeCount {
            return snapshot.restore(to: pasteboard)
                ? .replaced
                : .replacedWithoutClipboardRestore
        }
        return .replaced
    }
}
