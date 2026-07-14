import AppKit
@preconcurrency import ApplicationServices

@MainActor
struct PasteboardSnapshot {
    private static let maximumItemCount = 64
    private static let maximumTypeCountPerItem = 128
    private static let maximumDataSize = 32 * 1_024 * 1_024

    private let items: [[NSPasteboard.PasteboardType: Data]]

    init?(_ pasteboard: NSPasteboard) {
        let sourceItems = pasteboard.pasteboardItems ?? []
        guard sourceItems.count <= Self.maximumItemCount,
            !PasteboardPrivacy.containsProtectedContent(sourceItems)
        else { return nil }

        var totalDataSize = 0
        var captured: [[NSPasteboard.PasteboardType: Data]] = []
        captured.reserveCapacity(sourceItems.count)
        for item in sourceItems {
            guard item.types.count <= Self.maximumTypeCountPerItem else { return nil }
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                let (nextSize, overflow) = totalDataSize.addingReportingOverflow(data.count)
                guard !overflow, nextSize <= Self.maximumDataSize else { return nil }
                totalDataSize = nextSize
                values[type] = data
            }
            captured.append(values)
        }
        items = captured
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }
}

@MainActor
enum PasteboardPrivacy {
    private static let transientType = NSPasteboard.PasteboardType(
        "org.nspasteboard.TransientType"
    )
    private static let concealedType = NSPasteboard.PasteboardType(
        "org.nspasteboard.ConcealedType"
    )
    private static let protectedTypeNames: Set<String> = [
        transientType.rawValue,
        concealedType.rawValue,
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-name",
    ]

    static func containsProtectedContent(_ items: [NSPasteboardItem]) -> Bool {
        items.contains { item in
            item.types.contains { protectedTypeNames.contains($0.rawValue) }
        }
    }

    static func writeProtectedText(_ text: String, to pasteboard: NSPasteboard) -> Int? {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
            item.setData(Data(), forType: transientType),
            item.setData(Data(), forType: concealedType)
        else { return nil }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return nil }
        return pasteboard.changeCount
    }
}

@MainActor
enum SelectionClipboard {
    static func readSelectedText() async -> String? {
        let pasteboard = NSPasteboard.general
        guard let snapshot = PasteboardSnapshot(pasteboard) else { return nil }
        let originalChangeCount = pasteboard.changeCount

        guard postCommandKey(virtualKey: 8) else { return nil }

        for _ in 0..<40 where pasteboard.changeCount == originalChangeCount {
            await pause(milliseconds: 15)
        }
        guard pasteboard.changeCount != originalChangeCount else { return nil }

        let copiedChangeCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        if pasteboard.changeCount == copiedChangeCount {
            snapshot.restore(to: pasteboard)
        }
        return text
    }

    private static func pause(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }

    private static func postCommandKey(virtualKey: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
